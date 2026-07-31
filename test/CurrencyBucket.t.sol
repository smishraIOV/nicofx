// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {Currency} from "../src/Currency.sol";
import {SettlementToken} from "../src/SettlementToken.sol";
import {Oracle} from "../src/Oracle.sol";
import {ProtocolHub} from "../src/ProtocolHub.sol";
import {CurrencyBucket} from "../src/CurrencyBucket.sol";

contract CurrencyBucketTest is Test {
    USD internal usd;
    ProtocolHub internal hub;
    Oracle internal oracle;
    SettlementToken internal clp;
    SettlementToken internal ars;
    CurrencyBucket internal clpBucket;
    CurrencyBucket internal arsBucket;

    address internal admin = address(0xA11CE);
    address internal oracleOp = address(0x1111);
    address internal user = address(0xB0B);
    address internal stranger = address(0xBAD);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant CLP_RATE = 950e18; // ~950 CLP per 1 USD
    uint256 internal constant ARS_RATE = 1000e18; // ~1000 ARS per 1 USD

    function setUp() public {
        usd = USD(address(new ERC1967Proxy(address(new USD()), abi.encodeCall(USD.initialize, (admin)))));
        hub = ProtocolHub(
            address(new ERC1967Proxy(address(new ProtocolHub()), abi.encodeCall(ProtocolHub.initialize, (admin))))
        );
        oracle = new Oracle(admin, oracleOp);

        clp = SettlementToken(
            address(
                new ERC1967Proxy(
                    address(new SettlementToken()),
                    abi.encodeCall(SettlementToken.initialize, (admin, "FX Net CLP", "CLP"))
                )
            )
        );
        ars = SettlementToken(
            address(
                new ERC1967Proxy(
                    address(new SettlementToken()),
                    abi.encodeCall(SettlementToken.initialize, (admin, "FX Net ARS", "ARS"))
                )
            )
        );

        clpBucket = CurrencyBucket(
            address(
                new ERC1967Proxy(
                    address(new CurrencyBucket()),
                    abi.encodeCall(
                        CurrencyBucket.initialize,
                        (admin, address(usd), address(clp), address(oracle), address(hub), Currency.CLP)
                    )
                )
            )
        );
        arsBucket = CurrencyBucket(
            address(
                new ERC1967Proxy(
                    address(new CurrencyBucket()),
                    abi.encodeCall(
                        CurrencyBucket.initialize,
                        (admin, address(usd), address(ars), address(oracle), address(hub), Currency.ARS)
                    )
                )
            )
        );

        vm.startPrank(admin);
        oracle.setHub(address(hub));
        clp.grantRole(clp.ENGINE_ROLE(), address(clpBucket));
        ars.grantRole(ars.ENGINE_ROLE(), address(arsBucket));
        hub.setAllowlist(user, true);
        clpBucket.setFeeBps(100); // 1%
        arsBucket.setFeeBps(100);
        vm.stopPrank();
    }

    function _fundAdminUsd(uint256 amount) internal {
        vm.prank(admin);
        usd.mint(admin, amount);
        vm.prank(admin);
        usd.approve(address(clpBucket), type(uint256).max);
        vm.prank(admin);
        usd.approve(address(arsBucket), type(uint256).max);
    }

    function _fundUserUsd(uint256 amount) internal {
        vm.prank(admin);
        usd.mint(user, amount);
        vm.prank(user);
        usd.approve(address(clpBucket), type(uint256).max);
        vm.prank(user);
        usd.approve(address(arsBucket), type(uint256).max);
    }

    function _openAndSetRates() internal {
        vm.prank(admin);
        hub.openWindow();
        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, CLP_RATE);
        vm.prank(oracleOp);
        oracle.setRate(Currency.ARS, ARS_RATE);
    }

    function _openAndSetClpRate() internal {
        vm.prank(admin);
        hub.openWindow();
        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, CLP_RATE);
    }

    function _depositClpReserve(uint256 amount) internal {
        _fundAdminUsd(amount);
        vm.prank(admin);
        clpBucket.depositReserve(amount);
    }

    function _depositArsReserve(uint256 amount) internal {
        _fundAdminUsd(amount);
        vm.prank(admin);
        arsBucket.depositReserve(amount);
    }

    // --- Allowlist / MRW / oracle gating ---

    function test_NonAllowlistedCannotMint() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);

        vm.prank(admin);
        hub.setAllowlist(user, false);

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.NotAllowlisted.selector);
        clpBucket.mint(100e18);
    }

    function test_ClosedWindowBlocksMintRedeemAndSetRate() public {
        _depositClpReserve(10e18);
        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(Currency.CLP, CLP_RATE);

        _openAndSetClpRate();
        vm.prank(admin);
        hub.closeWindow();

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(CurrencyBucket.WindowNotOpen.selector);
        clpBucket.mint(100e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(Currency.CLP, CLP_RATE);
    }

    function test_RateMustBeSetInCurrentWindow() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        vm.prank(admin);
        hub.closeWindow();
        vm.prank(admin);
        hub.openWindow(); // new windowNonce; old rate invalid

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(CurrencyBucket.RateInvalid.selector);
        clpBucket.mint(100e18);
    }

    // --- Pause (hub) ---

    function test_OnlyAdminCanPause() public {
        vm.prank(user);
        vm.expectRevert();
        hub.pause();

        vm.prank(admin);
        hub.pause();
        assertTrue(hub.paused());
    }

    function test_PauseBlocksMintRedeemSetRateWithdrawReserve() public {
        _depositClpReserve(20e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);

        vm.prank(user);
        clpBucket.mint(100e18);

        vm.prank(admin);
        hub.pause();

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.HubPaused.selector);
        clpBucket.mint(1e18);

        vm.prank(user);
        clp.approve(address(clpBucket), type(uint256).max);
        vm.prank(user);
        vm.expectRevert(CurrencyBucket.HubPaused.selector);
        clpBucket.redeem(1e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.HubPaused.selector);
        oracle.setRate(Currency.CLP, CLP_RATE);

        vm.prank(admin);
        hub.unpause();
        vm.prank(admin);
        hub.closeWindow();
        vm.prank(admin);
        hub.pause();
        // withdrawal window active but paused
        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.HubPaused.selector);
        clpBucket.withdrawReserve(1e18);

        // depositReserve and withdrawFees still ok
        _fundAdminUsd(1e18);
        vm.prank(admin);
        clpBucket.depositReserve(1e18);
    }

    // --- Collateral / headroom ---

    function test_MintRequiresTenPercentBuffer() public {
        _openAndSetClpRate();
        _fundUserUsd(100e18);

        _depositClpReserve(9e18);
        vm.prank(user);
        vm.expectRevert(CurrencyBucket.InsufficientHeadroom.selector);
        clpBucket.mint(100e18);

        _depositClpReserve(1e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        assertEq(clp.balanceOf(user), 100e18 * CLP_RATE / WAD);
        assertEq(clpBucket.liabilityUsd(), 100e18);
        assertEq(clpBucket.collateralUsd(), 110e18);
    }

    function test_DepositReserveIncreasesHeadroom() public {
        _openAndSetClpRate();
        assertEq(clpBucket.mintHeadroomUsd(), 0);
        _depositClpReserve(10e18);
        assertEq(clpBucket.mintHeadroomUsd(), 100e18);
    }

    // --- Redeem fee + accruedFees ---

    function test_RedeemAccruesFeeAndPaysNet() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);

        vm.prank(user);
        clpBucket.mint(100e18);

        uint256 clpBal = clp.balanceOf(user);
        vm.prank(user);
        clp.approve(address(clpBucket), clpBal);

        uint256 userUsdBefore = usd.balanceOf(user);
        vm.prank(user);
        clpBucket.redeem(clpBal);

        assertEq(usd.balanceOf(user) - userUsdBefore, 99e18);
        assertEq(clpBucket.accruedFees(), 1e18);
        assertEq(clp.totalSupply(), 0);
        assertEq(clpBucket.collateralUsd(), 10e18);
    }

    function test_WithdrawFeesAnytimeDoesNotChangeCollateral() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        uint256 clpBal = clp.balanceOf(user);
        vm.prank(user);
        clp.approve(address(clpBucket), clpBal);
        vm.prank(user);
        clpBucket.redeem(clpBal);

        uint256 collateralBefore = clpBucket.collateralUsd();
        uint256 adminBefore = usd.balanceOf(admin);

        vm.prank(admin);
        clpBucket.withdrawFees(1e18);

        assertEq(clpBucket.accruedFees(), 0);
        assertEq(clpBucket.collateralUsd(), collateralBefore);
        assertEq(usd.balanceOf(admin) - adminBefore, 1e18);
    }

    // --- Withdrawal window ---

    function test_WithdrawReserveOnlyInPostCloseWindow() public {
        _depositClpReserve(20e18);
        _openAndSetClpRate();

        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.WithdrawalWindowInactive.selector);
        clpBucket.withdrawReserve(1e18);

        vm.prank(admin);
        hub.closeWindow();

        vm.prank(admin);
        clpBucket.withdrawReserve(5e18);
        assertEq(clpBucket.collateralUsd(), 15e18);

        vm.roll(block.number + 101);
        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.WithdrawalWindowInactive.selector);
        clpBucket.withdrawReserve(1e18);
    }

    function test_WithdrawReserveCannotBreachFloor() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        vm.prank(admin);
        hub.closeWindow();

        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.InsufficientCollateral.selector);
        clpBucket.withdrawReserve(1);
    }

    function test_OpenWindowCancelsWithdrawalWindow() public {
        _depositClpReserve(20e18);
        _openAndSetClpRate();
        vm.prank(admin);
        hub.closeWindow();
        assertTrue(hub.withdrawalWindowActive());

        vm.prank(admin);
        hub.openWindow();
        assertFalse(hub.withdrawalWindowActive());

        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.WithdrawalWindowInactive.selector);
        clpBucket.withdrawReserve(1e18);
    }

    function test_WindowAutoExpiresAfter200Blocks() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        assertEq(hub.windowDurationBlocks(), 200);
        assertTrue(hub.windowOpen());

        uint256 end = hub.windowEndBlock();
        vm.roll(end);
        assertTrue(hub.windowOpen());

        vm.roll(end + 1);
        assertFalse(hub.windowOpen());

        _fundUserUsd(100e18);
        vm.prank(user);
        vm.expectRevert(CurrencyBucket.WindowNotOpen.selector);
        clpBucket.mint(100e18);

        vm.prank(oracleOp);
        vm.expectRevert(Oracle.WindowClosed.selector);
        oracle.setRate(Currency.CLP, CLP_RATE);

        assertTrue(hub.withdrawalWindowActive());
        vm.prank(admin);
        clpBucket.withdrawReserve(1e18);
    }

    function test_EarlyCloseBeforeDuration() public {
        _depositClpReserve(20e18);
        _openAndSetClpRate();
        uint256 end = hub.windowEndBlock();

        vm.prank(admin);
        hub.closeWindow();
        assertFalse(hub.windowOpen());
        assertTrue(hub.withdrawalWindowActive());
        assertLt(block.number, end);

        vm.prank(admin);
        clpBucket.withdrawReserve(1e18);
    }

    // --- Partial redeem race ---

    function test_PartialRedeemProportionalBurn() public {
        vm.prank(admin);
        clpBucket.setFeeBps(0);

        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, 475e18);

        uint256 clpBal = clp.balanceOf(user);
        uint256 grossUsd = clpBal * WAD / 475e18;
        assertEq(grossUsd, 200e18);
        assertEq(clpBucket.collateralUsd(), 110e18);

        vm.prank(user);
        clp.approve(address(clpBucket), clpBal);

        uint256 userUsdBefore = usd.balanceOf(user);
        vm.prank(user);
        clpBucket.redeem(clpBal);

        uint256 expectedBurn = clpBal * 110e18 / 200e18;
        assertEq(usd.balanceOf(user) - userUsdBefore, 110e18);
        assertEq(clp.balanceOf(user), clpBal - expectedBurn);
        assertEq(clpBucket.collateralUsd(), 0);
    }

    function test_RedeemRevertsWhenCollateralEmpty() public {
        vm.prank(admin);
        clpBucket.setFeeBps(0);
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, 475e18);

        uint256 clpBal = clp.balanceOf(user);
        vm.prank(user);
        clp.approve(address(clpBucket), clpBal);
        vm.prank(user);
        clpBucket.redeem(clpBal);

        uint256 leftover = clp.balanceOf(user);
        assertGt(leftover, 0);
        assertEq(clpBucket.collateralUsd(), 0);

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.InsufficientCollateral.selector);
        clpBucket.redeem(leftover);
    }

    function test_PartialRedeemDoesNotSpendAccruedFees() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);
        vm.prank(user);
        clpBucket.mint(100e18);

        uint256 half = clp.balanceOf(user) / 2;
        vm.prank(user);
        clp.approve(address(clpBucket), type(uint256).max);
        vm.prank(user);
        clpBucket.redeem(half);

        uint256 feesAfterFirst = clpBucket.accruedFees();
        assertGt(feesAfterFirst, 0);

        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, 1e18);

        uint256 rem = clp.balanceOf(user);
        vm.prank(user);
        clpBucket.redeem(rem);

        assertEq(clpBucket.collateralUsd(), 0);
        assertEq(usd.balanceOf(address(clpBucket)), clpBucket.accruedFees());
        assertGe(clpBucket.accruedFees(), feesAfterFirst);
    }

    // --- Multicurrency ---

    function test_SharedWindowUnlocksBothBuckets() public {
        _depositClpReserve(10e18);
        _depositArsReserve(10e18);
        _openAndSetRates();
        _fundUserUsd(200e18);

        vm.prank(user);
        clpBucket.mint(100e18);
        vm.prank(user);
        arsBucket.mint(100e18);

        assertEq(clp.balanceOf(user), 100e18 * CLP_RATE / WAD);
        assertEq(ars.balanceOf(user), 100e18 * ARS_RATE / WAD);
    }

    function test_CrossBucketIsolation() public {
        _depositClpReserve(10e18);
        _depositArsReserve(10e18);
        _openAndSetRates();
        _fundUserUsd(200e18);

        vm.prank(user);
        clpBucket.mint(100e18);
        vm.prank(user);
        arsBucket.mint(100e18);

        uint256 clpCollateralBefore = clpBucket.collateralUsd();
        assertEq(clpCollateralBefore, 110e18);
        assertEq(arsBucket.collateralUsd(), 110e18);

        // Shock ARS and drain ARS vault via partial redeem
        vm.prank(admin);
        arsBucket.setFeeBps(0);
        vm.prank(oracleOp);
        oracle.setRate(Currency.ARS, 500e18);

        uint256 arsBal = ars.balanceOf(user);
        vm.prank(user);
        ars.approve(address(arsBucket), arsBal);
        vm.prank(user);
        arsBucket.redeem(arsBal);

        assertEq(arsBucket.collateralUsd(), 0);
        assertEq(clpBucket.collateralUsd(), clpCollateralBefore);
        assertEq(clp.balanceOf(user), 100e18 * CLP_RATE / WAD);
    }

    function test_AllowlistSharedAcrossBuckets() public {
        _depositClpReserve(10e18);
        _depositArsReserve(10e18);
        _openAndSetRates();
        _fundUserUsd(200e18);

        vm.prank(admin);
        hub.setAllowlist(user, false);

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.NotAllowlisted.selector);
        clpBucket.mint(100e18);

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.NotAllowlisted.selector);
        arsBucket.mint(100e18);
    }

    function test_TokenTransferDoesNotRequireAllowlist() public {
        _depositClpReserve(10e18);
        _openAndSetClpRate();
        _fundUserUsd(100e18);

        vm.prank(user);
        clpBucket.mint(100e18);

        uint256 bal = clp.balanceOf(user);
        vm.prank(user);
        clp.transfer(stranger, bal);
        assertEq(clp.balanceOf(stranger), bal);
        assertFalse(hub.isAllowlisted(stranger));
    }

    function test_AllowlistEnumeration() public {
        address[] memory accounts = hub.allowlistedAccounts();
        assertEq(accounts.length, 2); // admin + user
        assertTrue(hub.isAllowlisted(admin));
        assertTrue(hub.isAllowlisted(user));

        vm.prank(admin);
        hub.setAllowlist(user, false);
        accounts = hub.allowlistedAccounts();
        assertEq(accounts.length, 1);
        assertEq(accounts[0], admin);
    }

    // --- Upgrade smoke ---

    function test_UsdUpgradeSmoke() public {
        USD newImpl = new USD();
        vm.prank(admin);
        usd.upgradeToAndCall(address(newImpl), "");
        assertEq(usd.name(), "NicoFX USD");
    }
}
