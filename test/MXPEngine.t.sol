// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {MXP} from "../src/MXP.sol";
import {Oracle} from "../src/Oracle.sol";
import {MXPEngine} from "../src/MXPEngine.sol";

contract MXPEngineTest is Test {
    USD internal usd;
    MXP internal mxp;
    Oracle internal oracle;
    MXPEngine internal engine;

    address internal admin = address(0xA11CE);
    address internal oracleOp = address(0x1111);
    address internal user = address(0xB0B);
    address internal stranger = address(0xBAD);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RATE = 17e18; // 17 MXP per 1 USD

    function setUp() public {
        USD usdImpl = new USD();
        usd = USD(address(new ERC1967Proxy(address(usdImpl), abi.encodeCall(USD.initialize, (admin)))));

        MXP mxpImpl = new MXP();
        mxp = MXP(address(new ERC1967Proxy(address(mxpImpl), abi.encodeCall(MXP.initialize, (admin)))));

        oracle = new Oracle(admin, oracleOp);

        MXPEngine engineImpl = new MXPEngine();
        engine = MXPEngine(
            address(
                new ERC1967Proxy(
                    address(engineImpl),
                    abi.encodeCall(MXPEngine.initialize, (admin, address(usd), address(mxp), address(oracle)))
                )
            )
        );

        vm.startPrank(admin);
        mxp.grantRole(mxp.ENGINE_ROLE(), address(engine));
        oracle.setEngine(address(engine));
        engine.setAllowlist(user, true);
        engine.setFeeBps(100); // 1%
        vm.stopPrank();
    }

    function _fundAdminUsd(uint256 amount) internal {
        vm.prank(admin);
        usd.mint(admin, amount);
        vm.prank(admin);
        usd.approve(address(engine), type(uint256).max);
    }

    function _fundUserUsd(uint256 amount) internal {
        vm.prank(admin);
        usd.mint(user, amount);
        vm.prank(user);
        usd.approve(address(engine), type(uint256).max);
    }

    function _openAndSetRate() internal {
        vm.prank(admin);
        engine.openWindow();
        vm.prank(oracleOp);
        oracle.setRate(RATE);
    }

    function _depositReserve(uint256 amount) internal {
        _fundAdminUsd(amount);
        vm.prank(admin);
        engine.depositReserve(amount);
    }

    // --- Allowlist / MRW / oracle gating ---

    function test_NonAllowlistedCannotMint() public {
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);

        vm.prank(admin);
        engine.setAllowlist(user, false);

        vm.prank(user);
        vm.expectRevert(MXPEngine.NotAllowlisted.selector);
        engine.mint(100e18);
    }

    function test_ClosedWindowBlocksMintRedeemAndSetRate() public {
        _depositReserve(10e18);
        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(RATE);

        _openAndSetRate();
        vm.prank(admin);
        engine.closeWindow();

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(MXPEngine.WindowNotOpen.selector);
        engine.mint(100e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(RATE);
    }

    function test_RateMustBeSetInCurrentWindow() public {
        _depositReserve(10e18);
        _openAndSetRate();
        vm.prank(admin);
        engine.closeWindow();
        vm.prank(admin);
        engine.openWindow(); // new windowNonce; old rate invalid

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(MXPEngine.RateInvalid.selector);
        engine.mint(100e18);
    }

    // --- Pause ---

    function test_OnlyAdminCanPause() public {
        vm.prank(user);
        vm.expectRevert();
        engine.pause();

        vm.prank(admin);
        engine.pause();
        assertTrue(engine.paused());
    }

    function test_PauseBlocksMintRedeemSetRateWithdrawReserve() public {
        _depositReserve(20e18);
        _openAndSetRate();
        _fundUserUsd(100e18);

        vm.prank(user);
        engine.mint(100e18);

        vm.prank(admin);
        engine.pause();

        vm.prank(user);
        vm.expectRevert();
        engine.mint(1e18);

        vm.prank(user);
        mxp.approve(address(engine), type(uint256).max);
        vm.prank(user);
        vm.expectRevert();
        engine.redeem(1e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.EnginePaused.selector);
        oracle.setRate(RATE);

        vm.prank(admin);
        engine.closeWindow();
        // withdrawal window active but paused
        vm.prank(admin);
        vm.expectRevert();
        engine.withdrawReserve(1e18);

        // depositReserve and withdrawFees still ok
        _fundAdminUsd(1e18);
        vm.prank(admin);
        engine.depositReserve(1e18);
    }

    // --- Collateral / headroom ---

    function test_MintRequiresTenPercentBuffer() public {
        _openAndSetRate();
        _fundUserUsd(100e18);

        // only $9 buffer → cannot mint $100
        _depositReserve(9e18);
        vm.prank(user);
        vm.expectRevert(MXPEngine.InsufficientHeadroom.selector);
        engine.mint(100e18);

        _depositReserve(1e18); // now $10
        vm.prank(user);
        engine.mint(100e18);

        assertEq(mxp.balanceOf(user), 100e18 * RATE / WAD);
        assertEq(engine.liabilityUsd(), 100e18);
        assertEq(engine.collateralUsd(), 110e18);
    }

    function test_DepositReserveIncreasesHeadroom() public {
        _openAndSetRate();
        assertEq(engine.mintHeadroomUsd(), 0);
        _depositReserve(10e18);
        assertEq(engine.mintHeadroomUsd(), 100e18);
    }

    // --- Redeem fee + accruedFees ---

    function test_RedeemAccruesFeeAndPaysNet() public {
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);

        vm.prank(user);
        engine.mint(100e18);

        uint256 mxpBal = mxp.balanceOf(user);
        vm.prank(user);
        mxp.approve(address(engine), mxpBal);

        uint256 userUsdBefore = usd.balanceOf(user);
        vm.prank(user);
        engine.redeem(mxpBal);

        // 1% fee on $100 gross
        assertEq(usd.balanceOf(user) - userUsdBefore, 99e18);
        assertEq(engine.accruedFees(), 1e18);
        assertEq(mxp.totalSupply(), 0);
        // collateral = vault - fees = 11 - 1 = 10 (buffer remains after full redeem of liability)
        assertEq(engine.collateralUsd(), 10e18);
    }

    function test_WithdrawFeesAnytimeDoesNotChangeCollateral() public {
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        engine.mint(100e18);

        uint256 mxpBal = mxp.balanceOf(user);
        vm.prank(user);
        mxp.approve(address(engine), mxpBal);
        vm.prank(user);
        engine.redeem(mxpBal);

        uint256 collateralBefore = engine.collateralUsd();
        uint256 adminBefore = usd.balanceOf(admin);

        vm.prank(admin);
        engine.withdrawFees(1e18);

        assertEq(engine.accruedFees(), 0);
        assertEq(engine.collateralUsd(), collateralBefore);
        assertEq(usd.balanceOf(admin) - adminBefore, 1e18);
    }

    // --- Withdrawal window ---

    function test_WithdrawReserveOnlyInPostCloseWindow() public {
        _depositReserve(20e18);
        _openAndSetRate();

        vm.prank(admin);
        vm.expectRevert(MXPEngine.WithdrawalWindowInactive.selector);
        engine.withdrawReserve(1e18);

        vm.prank(admin);
        engine.closeWindow();

        vm.prank(admin);
        engine.withdrawReserve(5e18);
        assertEq(engine.collateralUsd(), 15e18);

        // after 100 blocks from close, window ends (active while block <= start+100)
        vm.roll(block.number + 101);
        vm.prank(admin);
        vm.expectRevert(MXPEngine.WithdrawalWindowInactive.selector);
        engine.withdrawReserve(1e18);
    }

    function test_WithdrawReserveCannotBreachFloor() public {
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        engine.mint(100e18);

        vm.prank(admin);
        engine.closeWindow();

        // need collateral >= 110; have 110; cannot withdraw any
        vm.prank(admin);
        vm.expectRevert(MXPEngine.InsufficientCollateral.selector);
        engine.withdrawReserve(1);
    }

    function test_OpenWindowCancelsWithdrawalWindow() public {
        _depositReserve(20e18);
        _openAndSetRate();
        vm.prank(admin);
        engine.closeWindow();
        assertTrue(engine.withdrawalWindowActive());

        vm.prank(admin);
        engine.openWindow();
        assertFalse(engine.withdrawalWindowActive());

        vm.prank(admin);
        vm.expectRevert(MXPEngine.WithdrawalWindowInactive.selector);
        engine.withdrawReserve(1e18);
    }

    function test_WindowAutoExpiresAfter200Blocks() public {
        _depositReserve(10e18);
        _openAndSetRate();
        assertEq(engine.windowDurationBlocks(), 200);
        assertTrue(engine.windowOpen());

        uint256 end = engine.windowEndBlock();
        vm.roll(end); // still inclusive
        assertTrue(engine.windowOpen());

        vm.roll(end + 1);
        assertFalse(engine.windowOpen());

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(MXPEngine.WindowNotOpen.selector);
        engine.mint(100e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(RATE);

        assertTrue(engine.withdrawalWindowActive());
        vm.prank(admin);
        engine.withdrawReserve(1e18);
    }

    function test_EarlyCloseBeforeDuration() public {
        _depositReserve(20e18);
        _openAndSetRate();
        uint256 end = engine.windowEndBlock();

        vm.prank(admin);
        engine.closeWindow();
        assertFalse(engine.windowOpen());
        assertTrue(engine.withdrawalWindowActive());
        assertLt(block.number, end);

        vm.prank(admin);
        engine.withdrawReserve(1e18);
    }

    // --- Partial redeem race ---

    function test_PartialRedeemProportionalBurn() public {
        // Set fee to 0 for clearer math
        vm.prank(admin);
        engine.setFeeBps(0);

        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        engine.mint(100e18);

        // Simulate FX shock: peso stronger → fewer MXP per USD → higher liability
        // rate 17 → 8.5 means liability doubles to $200, collateral still $110
        vm.prank(oracleOp);
        oracle.setRate(8.5e18);

        uint256 mxpBal = mxp.balanceOf(user);
        uint256 grossUsd = mxpBal * WAD / 8.5e18; // 200e18
        assertEq(grossUsd, 200e18);
        assertEq(engine.collateralUsd(), 110e18);

        vm.prank(user);
        mxp.approve(address(engine), mxpBal);

        uint256 userUsdBefore = usd.balanceOf(user);
        vm.prank(user);
        engine.redeem(mxpBal);

        // Pays all collateral $110, burns proportional MXP: mxpBal * 110/200
        uint256 expectedBurn = mxpBal * 110e18 / 200e18;
        assertEq(usd.balanceOf(user) - userUsdBefore, 110e18);
        assertEq(mxp.balanceOf(user), mxpBal - expectedBurn);
        assertEq(engine.collateralUsd(), 0);
    }

    function test_RedeemRevertsWhenCollateralEmpty() public {
        vm.prank(admin);
        engine.setFeeBps(0);
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        engine.mint(100e18);

        vm.prank(oracleOp);
        oracle.setRate(8.5e18);

        uint256 mxpBal = mxp.balanceOf(user);
        vm.prank(user);
        mxp.approve(address(engine), mxpBal);
        vm.prank(user);
        engine.redeem(mxpBal); // drains collateral

        uint256 leftover = mxp.balanceOf(user);
        assertGt(leftover, 0);
        assertEq(engine.collateralUsd(), 0);

        vm.prank(user);
        vm.expectRevert(MXPEngine.InsufficientCollateral.selector);
        engine.redeem(leftover);
    }

    function test_PartialRedeemDoesNotSpendAccruedFees() public {
        _depositReserve(10e18);
        _openAndSetRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        engine.mint(100e18);

        // First redeem a slice at healthy rate to accrue fees, then shock
        uint256 half = mxp.balanceOf(user) / 2;
        vm.prank(user);
        mxp.approve(address(engine), type(uint256).max);
        vm.prank(user);
        engine.redeem(half);

        uint256 feesAfterFirst = engine.accruedFees();
        assertGt(feesAfterFirst, 0);

        // Shock remaining supply
        vm.prank(oracleOp);
        oracle.setRate(1e18);

        uint256 rem = mxp.balanceOf(user);
        vm.prank(user);
        engine.redeem(rem);

        // Race settles collateral only; accrued fee USD remains in the vault
        assertEq(engine.collateralUsd(), 0);
        assertEq(usd.balanceOf(address(engine)), engine.accruedFees());
        assertGe(engine.accruedFees(), feesAfterFirst);
    }

    // --- Upgrade smoke ---

    function test_UsdUpgradeSmoke() public {
        USD newImpl = new USD();
        vm.prank(admin);
        usd.upgradeToAndCall(address(newImpl), "");
        assertEq(usd.name(), "NicoFX USD");
    }
}
