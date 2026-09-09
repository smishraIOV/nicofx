// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {Currency} from "../src/Currency.sol";
import {SettlementToken} from "../src/SettlementToken.sol";
import {Oracle} from "../src/Oracle.sol";
import {ProtocolHub} from "../src/ProtocolHub.sol";
import {CurrencyBucket} from "../src/CurrencyBucket.sol";

/// @notice Covers review finding R1-C2 (two-way pricing / no intra-window arbitrage),
///         H5 (rate freshness on every USD-moving path) and M1 (real constraints on reserve exit).
contract PricingAndReservesTest is Test {
    USD internal usd;
    ProtocolHub internal hub;
    Oracle internal oracle;
    SettlementToken internal clp;
    CurrencyBucket internal bucket;

    address internal admin = address(0xA11CE);
    address internal oracleOp = address(0x1111);
    address internal user = address(0xB0B);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant CLP_RATE = 950e18;

    function setUp() public {
        usd = USD(address(new ERC1967Proxy(address(new USD()), abi.encodeCall(USD.initialize, (admin)))));
        hub = ProtocolHub(
            address(new ERC1967Proxy(address(new ProtocolHub()), abi.encodeCall(ProtocolHub.initialize, (admin))))
        );
        oracle = new Oracle(admin, oracleOp, 500); // 5% max single-window move
        clp = SettlementToken(
            address(
                new ERC1967Proxy(
                    address(new SettlementToken()),
                    abi.encodeCall(SettlementToken.initialize, (admin, "FX Net CLP", "CLP"))
                )
            )
        );
        bucket = CurrencyBucket(
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

        vm.startPrank(admin);
        oracle.setHub(address(hub));
        clp.grantRole(clp.ENGINE_ROLE(), address(bucket));
        hub.setAllowlist(user, true);
        bucket.setMintFeeBps(25);
        bucket.setRedeemFeeBps(50);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who, uint256 amount) internal {
        vm.prank(admin);
        usd.mint(who, amount);
        vm.prank(who);
        usd.approve(address(bucket), type(uint256).max);
    }

    function _openWithRate(uint256 rate) internal {
        vm.prank(admin);
        hub.openWindow();
        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, rate);
    }

    function _closeWindow() internal {
        vm.roll(block.number + hub.minWindowBlocks());
        vm.prank(admin);
        hub.closeWindow();
    }

    function _reserve(uint256 amount) internal {
        _fund(admin, amount);
        vm.prank(admin);
        bucket.depositReserve(amount);
    }

    // ----------------------------------------------- R1-C2: no intra-window re-rate

    /// The exact mechanism behind the original C2 exploit is now impossible
    function test_R1_C2_SecondRatePostInSameWindowReverts() public {
        _openWithRate(CLP_RATE);
        vm.prank(oracleOp);
        vm.expectRevert(Oracle.RateAlreadySetForWindow.selector);
        oracle.setRate(Currency.CLP, 902.5e18);
        assertFalse(oracle.canSetRate(Currency.CLP));
    }

    /// Original repro: mint at 950, re-rate 5% inside the window, redeem for risk-free profit.
    /// The re-rate now reverts, so the round trip can only happen at the price it was minted at.
    function test_R1_C2_IntraWindowRoundTripIsNoLongerProfitable() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 100_000e18);

        uint256 before = usd.balanceOf(user);
        vm.prank(user);
        bucket.mint(10_000e18);

        // The rate cannot move inside the window any more
        vm.prank(oracleOp);
        vm.expectRevert(Oracle.RateAlreadySetForWindow.selector);
        oracle.setRate(Currency.CLP, 902.5e18);

        uint256 held = clp.balanceOf(user);
        vm.prank(user);
        clp.approve(address(bucket), type(uint256).max);
        vm.prank(user);
        bucket.redeem(held);

        int256 pnl = int256(usd.balanceOf(user)) - int256(before);
        console2.log("same-window round trip PnL (should be negative):", pnl);
        assertLt(pnl, 0, "a round trip must cost the two fees, not earn a spread");

        // Cost is mint fee + redeem fee, ~75 bps of the 10,000 USD notional
        assertApproxEqAbs(uint256(-pnl), 74.875e18, 0.01e18);
    }

    function test_R1_C2_MintFeeAccruesAndHeadroomAccountsForIt() public {
        _reserve(1_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 100_000e18);

        // Headroom is the gross USD in, grossed up for the fee
        uint256 headroom = bucket.mintHeadroomUsd();
        assertApproxEqAbs(headroom, 10_025.06e18, 0.01e18);

        vm.prank(user);
        bucket.mint(1_000e18);
        assertEq(bucket.accruedFees(), 2.5e18, "0.25% of USD in retained as fee");
        assertEq(bucket.collateralUsd(), 1_997.5e18);
        assertEq(clp.balanceOf(user), 997.5e18 * CLP_RATE / WAD, "token minted on the post-fee amount");
    }

    function test_R1_C2_MintCannotExceedHeadroom() public {
        _reserve(1_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 100_000e18);
        uint256 headroom = bucket.mintHeadroomUsd();

        vm.prank(user);
        vm.expectRevert(CurrencyBucket.InsufficientHeadroom.selector);
        bucket.mint(headroom + 1);

        vm.prank(user);
        bucket.mint(headroom);
        assertGe(bucket.coverageRatioBps(), bucket.REQUIRED_RATIO_BPS(), "110% floor holds at max mint");
    }

    /// Honest limit: fees stop the *risk-free* round trip but do not remove FX exposure held across
    /// windows. That residual is the documented devaluation risk, not something pricing can close.
    function test_R1_C2_CrossWindowFxExposureRemainsAndIsDocumented() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 100_000e18);

        uint256 before = usd.balanceOf(user);
        vm.prank(user);
        bucket.mint(10_000e18);
        uint256 held = clp.balanceOf(user);

        // New window, CLP appreciates 5% (the largest move the deviation bound allows)
        _closeWindow();
        _openWithRate(902.5e18);

        vm.prank(user);
        clp.approve(address(bucket), type(uint256).max);
        vm.prank(user);
        bucket.redeem(held);

        int256 pnl = int256(usd.balanceOf(user)) - int256(before);
        console2.log("cross-window PnL after a 5% move (residual exposure):", pnl);
        assertGt(pnl, 0, "documented residual: holders still gain on a favourable move");
        // Fees shave the old 4.74% to ~4.47%; caps and the coverage breaker are the real controls
        assertApproxEqAbs(uint256(pnl), 447.5e18, 1e18);
    }

    // -------------------------------------------------- Oracle deviation bound

    function test_Oracle_DeviationBoundRejectsLargeMove() public {
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.prank(admin);
        hub.openWindow();

        vm.prank(oracleOp);
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.DeviationTooLarge.selector, CLP_RATE, 1_900e18, uint256(500))
        );
        oracle.setRate(Currency.CLP, 1_900e18); // 100% move
    }

    function test_Oracle_DeviationBoundAllowsMoveAtTheLimit() public {
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.prank(admin);
        hub.openWindow();
        vm.prank(oracleOp);
        oracle.setRate(Currency.CLP, 997.5e18); // exactly 5%
        assertEq(oracle.ratePerUsd(Currency.CLP), 997.5e18);
    }

    function test_Oracle_ForceSetRateOverridesDeviation() public {
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.prank(admin);
        hub.openWindow();

        vm.prank(oracleOp);
        vm.expectRevert();
        oracle.setRate(Currency.CLP, 1_900e18);

        // Owner may push a genuine large move; it emits a distinct RateForced event
        vm.prank(admin);
        oracle.forceSetRate(Currency.CLP, 1_900e18);
        assertEq(oracle.ratePerUsd(Currency.CLP), 1_900e18);
    }

    function test_Oracle_ForceSetRateStillOnePerWindow() public {
        _openWithRate(CLP_RATE);
        vm.prank(admin);
        vm.expectRevert(Oracle.RateAlreadySetForWindow.selector);
        oracle.forceSetRate(Currency.CLP, 900e18);
    }

    function test_Oracle_OnlyTrustedOracleOrOwner() public {
        vm.prank(admin);
        hub.openWindow();
        vm.prank(user);
        vm.expectRevert(Oracle.NotTrustedOracle.selector);
        oracle.setRate(Currency.CLP, CLP_RATE);
    }

    function test_Oracle_UsdIsNotABucketCurrency() public {
        vm.prank(admin);
        hub.openWindow();
        vm.prank(oracleOp);
        vm.expectRevert(Oracle.InvalidCurrency.selector);
        oracle.setRate(Currency.USD, 1e18);
    }

    // ----------------------------------------------------- R1-H5: rate freshness

    /// The original H5 repro: withdraw against a rate that can no longer be refreshed
    function test_R1_H5_ReserveWithdrawalRejectsStaleRate() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();
        assertTrue(hub.withdrawalWindowActive());

        // Rate ages past the bucket's tolerance while no new rate can be posted
        vm.warp(block.timestamp + bucket.maxRateAge() + 1);
        assertFalse(bucket.rateIsFresh());

        vm.prank(admin);
        vm.expectRevert();
        bucket.requestReserveWithdrawal(100e18);
    }

    function test_R1_H5_ReserveWithdrawalRejectsRateFromEarlierWindow() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();

        // A new window bumps the nonce; the old rate is no longer valid for this one
        vm.prank(admin);
        hub.openWindow();
        _closeWindow();

        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.RateInvalid.selector);
        bucket.requestReserveWithdrawal(100e18);
    }

    function test_R1_H5_MintAndRedeemRejectStaleRate() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 10_000e18);
        vm.prank(user);
        bucket.mint(1_000e18);

        vm.warp(block.timestamp + bucket.maxRateAge() + 1);
        vm.prank(user);
        vm.expectRevert();
        bucket.mint(1e18);

        vm.prank(user);
        clp.approve(address(bucket), type(uint256).max);
        vm.prank(user);
        vm.expectRevert();
        bucket.redeem(1e18);
    }

    /// liabilityUsd used to report zero on a missing rate, which would have let a withdrawal
    /// drain the vault while tokens were outstanding
    function test_R1_H5_LiabilityRevertsWhenRateMissingAndSupplyOutstanding() public {
        Oracle fresh = new Oracle(admin, oracleOp, 0);
        vm.prank(admin);
        fresh.setHub(address(hub));

        CurrencyBucket orphan = CurrencyBucket(
            address(
                new ERC1967Proxy(
                    address(new CurrencyBucket()),
                    abi.encodeCall(
                        CurrencyBucket.initialize,
                        (admin, address(usd), address(clp), address(fresh), address(hub), Currency.CLP)
                    )
                )
            )
        );

        // No rate on the fresh oracle, but the token has supply
        vm.startPrank(admin);
        clp.grantRole(clp.ENGINE_ROLE(), admin);
        clp.mint(user, 1_000e18);
        vm.stopPrank();

        assertEq(orphan.collateralUsd(), 0);
        vm.expectRevert(CurrencyBucket.RateInvalid.selector);
        orphan.liabilityUsd();
    }

    function test_R1_H5_LiabilityIsZeroWithNoSupply() public view {
        assertEq(bucket.liabilityUsd(), 0);
        assertEq(bucket.coverageRatioBps(), type(uint256).max);
    }

    // ----------------------------------------- R1-M1: reserve exit is constrained

    /// The withdrawal window used to be no constraint at all: open then close on demand
    function test_R1_M1_CannotCloseWindowBeforeMinBlocks() public {
        vm.prank(admin);
        hub.openWindow();
        uint256 closableFrom = hub.windowClosableFromBlock();
        assertEq(closableFrom, block.number + hub.minWindowBlocks());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProtocolHub.MinWindowNotElapsed.selector, closableFrom));
        hub.closeWindow();

        vm.roll(closableFrom);
        vm.prank(admin);
        hub.closeWindow();
        assertTrue(hub.withdrawalWindowActive());
    }

    function test_R1_M1_ReserveWithdrawalIsTimelocked() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();

        vm.prank(admin);
        bucket.requestReserveWithdrawal(500e18);
        (uint256 amount, uint256 requestBlock) = bucket.pendingWithdrawal();
        assertEq(amount, 500e18);

        uint256 delay = bucket.RESERVE_WITHDRAWAL_DELAY_BLOCKS();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CurrencyBucket.WithdrawalNotExecutable.selector, requestBlock + delay)
        );
        bucket.executeReserveWithdrawal();

        vm.roll(requestBlock + delay);
        uint256 adminBefore = usd.balanceOf(admin);
        vm.prank(admin);
        bucket.executeReserveWithdrawal();
        assertEq(usd.balanceOf(admin) - adminBefore, 500e18);
        (amount,) = bucket.pendingWithdrawal();
        assertEq(amount, 0);
    }

    function test_R1_M1_OnlyOnePendingWithdrawalAtATime() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.startPrank(admin);
        bucket.requestReserveWithdrawal(100e18);
        vm.expectRevert(CurrencyBucket.WithdrawalAlreadyPending.selector);
        bucket.requestReserveWithdrawal(100e18);
        vm.stopPrank();
    }

    function test_R1_M1_PendingWithdrawalCanBeCancelled() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.startPrank(admin);
        bucket.requestReserveWithdrawal(100e18);
        bucket.cancelReserveWithdrawal();
        vm.expectRevert(CurrencyBucket.NoPendingWithdrawal.selector);
        bucket.executeReserveWithdrawal();
        vm.stopPrank();
    }

    /// Conditions are re-checked at execution, so a request cannot outlive its window
    function test_R1_M1_WithdrawalExpiresWithTheWindow() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _closeWindow();
        vm.prank(admin);
        bucket.requestReserveWithdrawal(100e18);

        vm.roll(block.number + hub.WITHDRAWAL_WINDOW_BLOCKS() + 1);
        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.WithdrawalWindowInactive.selector);
        bucket.executeReserveWithdrawal();
    }

    /// Withdrawals must leave more than the 110% mint floor
    function test_R1_M1_WithdrawFloorIsStricterThanMintFloor() public {
        _reserve(2_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 100_000e18);

        // Mint to exactly the 110% mint floor
        uint256 headroom = bucket.mintHeadroomUsd();
        vm.prank(user);
        bucket.mint(headroom);
        assertApproxEqAbs(bucket.coverageRatioBps(), 11_000, 2);

        _closeWindow();
        assertEq(bucket.withdrawableReserveUsd(), 0, "nothing withdrawable at the mint floor");
        vm.prank(admin);
        vm.expectRevert(CurrencyBucket.InsufficientCollateral.selector);
        bucket.requestReserveWithdrawal(1);

        // Top up clear of 115% and a withdrawal becomes possible again
        _reserve(2_000e18);
        assertGt(bucket.coverageRatioBps(), bucket.WITHDRAW_RATIO_BPS());
        assertGt(bucket.withdrawableReserveUsd(), 0);
    }

    function test_R1_M1_MinWindowBlocksIsConfigurableWithinDuration() public {
        uint256 tooLong = hub.windowDurationBlocks() + 1;
        vm.startPrank(admin);
        vm.expectRevert(ProtocolHub.InvalidWindowDuration.selector);
        hub.setMinWindowBlocks(0);
        vm.expectRevert(ProtocolHub.InvalidWindowDuration.selector);
        hub.setMinWindowBlocks(tooLong);
        hub.setMinWindowBlocks(10);
        assertEq(hub.minWindowBlocks(), 10);
        vm.stopPrank();
    }

    function test_R1_M1_WindowDurationCannotDropBelowMinimum() public {
        uint256 tooShort = hub.minWindowBlocks() - 1;
        vm.prank(admin);
        vm.expectRevert(ProtocolHub.InvalidWindowDuration.selector);
        hub.setWindowDurationBlocks(tooShort);
    }

    function test_CoverageRatioTracksCollateral() public {
        _reserve(1_000e18);
        _openWithRate(CLP_RATE);
        _fund(user, 10_000e18);
        vm.prank(user);
        bucket.mint(1_000e18);

        // collateral 1997.5 against liability 997.5
        assertApproxEqAbs(bucket.coverageRatioBps(), 20_025, 5);
    }
}
