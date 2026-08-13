// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {Currency} from "../src/Currency.sol";
import {SettlementToken} from "../src/SettlementToken.sol";
import {ProtocolHub} from "../src/ProtocolHub.sol";
import {NettingSession} from "../src/NettingSession.sol";
import {INettingSession} from "../src/interfaces/INettingSession.sol";

contract NettingSessionTest is Test {
    USD internal usd;
    SettlementToken internal clp;
    SettlementToken internal ars;
    ProtocolHub internal hub;
    NettingSession internal session;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0);
    address internal carol = address(0xC0);
    address internal stranger = address(0xBAD);

    function setUp() public {
        usd = USD(address(new ERC1967Proxy(address(new USD()), abi.encodeCall(USD.initialize, (admin)))));
        hub = ProtocolHub(
            address(new ERC1967Proxy(address(new ProtocolHub()), abi.encodeCall(ProtocolHub.initialize, (admin))))
        );
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
        session = NettingSession(
            address(
                new ERC1967Proxy(
                    address(new NettingSession()),
                    abi.encodeCall(
                        NettingSession.initialize, (admin, address(hub), address(usd), address(clp), address(ars))
                    )
                )
            )
        );

        // Grant ENGINE_ROLE to admin so tests can mint inventory directly
        vm.startPrank(admin);
        clp.grantRole(clp.ENGINE_ROLE(), admin);
        ars.grantRole(ars.ENGINE_ROLE(), admin);
        hub.setAllowlist(alice, true);
        hub.setAllowlist(bob, true);
        hub.setAllowlist(carol, true);
        vm.stopPrank();
    }

    function _mintInventory(address to, uint256 clpAmt, uint256 arsAmt, uint256 usdAmt) internal {
        vm.startPrank(admin);
        if (clpAmt > 0) clp.mint(to, clpAmt);
        if (arsAmt > 0) ars.mint(to, arsAmt);
        if (usdAmt > 0) usd.mint(to, usdAmt);
        vm.stopPrank();
    }

    function _approveSession(address party) internal {
        vm.startPrank(party);
        clp.approve(address(session), type(uint256).max);
        ars.approve(address(session), type(uint256).max);
        usd.approve(address(session), type(uint256).max);
        vm.stopPrank();
    }

    function test_TriangleFullyNetsToZero() public {
        vm.prank(admin);
        session.openSession();

        // A→B 100, B→C 100, C→A 100 CLP
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18);
        vm.prank(bob);
        session.postObligation(bob, carol, Currency.CLP, 100e18);
        vm.prank(carol);
        session.postObligation(carol, alice, Currency.CLP, 100e18);

        vm.prank(admin);
        session.lockSession();

        assertEq(session.netOf(alice, Currency.CLP), 0);
        assertEq(session.netOf(bob, Currency.CLP), 0);
        assertEq(session.netOf(carol, Currency.CLP), 0);
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Settled));
    }

    function test_CrossCurrencyFundAndClaim() public {
        _mintInventory(alice, 50e18, 0, 0);
        _mintInventory(bob, 0, 80e18, 0);
        _approveSession(alice);
        _approveSession(bob);

        vm.prank(admin);
        session.openSession();

        // Alice owes Bob 50 CLP; Bob owes Alice 80 ARS
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 50e18);
        vm.prank(bob);
        session.postObligation(bob, alice, Currency.ARS, 80e18);

        vm.prank(admin);
        session.lockSession();

        assertEq(session.netOf(alice, Currency.CLP), -50e18);
        assertEq(session.netOf(bob, Currency.CLP), 50e18);
        assertEq(session.netOf(bob, Currency.ARS), -80e18);
        assertEq(session.netOf(alice, Currency.ARS), 80e18);

        // Bob cannot claim CLP until Alice funds
        vm.prank(bob);
        vm.expectRevert(NettingSession.CurrencyNotFullyFunded.selector);
        session.claim(Currency.CLP);

        vm.prank(alice);
        session.fund(Currency.CLP);
        assertTrue(session.currencyFullyFunded(Currency.CLP));

        vm.prank(bob);
        session.claim(Currency.CLP);
        assertEq(clp.balanceOf(bob), 50e18);
        assertEq(clp.balanceOf(alice), 0);

        vm.prank(bob);
        session.fund(Currency.ARS);
        vm.prank(alice);
        session.claim(Currency.ARS);
        assertEq(ars.balanceOf(alice), 80e18);
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Settled));
    }

    function test_ThreePartyResidualNets() public {
        // A→B 100, B→C 40, C→A 10 → nets: A -90, B +60, C +30
        _mintInventory(alice, 90e18, 0, 0);
        _approveSession(alice);

        vm.prank(admin);
        session.openSession();

        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18);
        vm.prank(bob);
        session.postObligation(bob, carol, Currency.CLP, 40e18);
        vm.prank(carol);
        session.postObligation(carol, alice, Currency.CLP, 10e18);

        vm.prank(admin);
        session.lockSession();

        assertEq(session.netOf(alice, Currency.CLP), -90e18);
        assertEq(session.netOf(bob, Currency.CLP), 60e18);
        assertEq(session.netOf(carol, Currency.CLP), 30e18);

        vm.prank(alice);
        session.fund(Currency.CLP);

        vm.prank(bob);
        session.claim(Currency.CLP);
        vm.prank(carol);
        session.claim(Currency.CLP);

        assertEq(clp.balanceOf(bob), 60e18);
        assertEq(clp.balanceOf(carol), 30e18);
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Settled));
    }

    function test_ReceiptFeeHaircutsClaim() public {
        _mintInventory(alice, 90e18, 0, 0);
        _approveSession(alice);

        vm.prank(admin);
        session.setFeeBps(50); // 0.50%

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18);
        vm.prank(bob);
        session.postObligation(bob, carol, Currency.CLP, 40e18);
        vm.prank(carol);
        session.postObligation(carol, alice, Currency.CLP, 10e18);

        vm.prank(admin);
        session.lockSession();

        assertEq(session.grossPosted(Currency.CLP), 150e18);
        assertEq(session.eliminated(Currency.CLP), 60e18);

        vm.prank(alice);
        session.fund(Currency.CLP);

        vm.prank(bob);
        session.claim(Currency.CLP);
        vm.prank(carol);
        session.claim(Currency.CLP);

        // 50 bps of 60 and 30
        assertEq(clp.balanceOf(bob), 59.7e18);
        assertEq(clp.balanceOf(carol), 29.85e18);
        assertEq(session.accruedFees(Currency.CLP), 0.45e18);
        assertEq(clp.balanceOf(address(session)), 0.45e18);
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Settled));

        vm.prank(admin);
        session.withdrawFees(Currency.CLP, 0.45e18);
        assertEq(session.accruedFees(Currency.CLP), 0);
        assertEq(clp.balanceOf(admin), 0.45e18);
    }

    function test_EqualCycleFreeAndEliminated() public {
        vm.prank(admin);
        session.setFeeBps(50);

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18);
        vm.prank(bob);
        session.postObligation(bob, carol, Currency.CLP, 100e18);
        vm.prank(carol);
        session.postObligation(carol, alice, Currency.CLP, 100e18);

        vm.prank(admin);
        session.lockSession();

        assertEq(session.eliminated(Currency.CLP), 300e18);
        assertEq(session.accruedFees(Currency.CLP), 0);
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Settled));
    }

    function test_FeeTooHighReverts() public {
        vm.prank(admin);
        vm.expectRevert(NettingSession.FeeTooHigh.selector);
        session.setFeeBps(1001);
    }

    function test_NonAllowlistedCannotPost() public {
        vm.prank(admin);
        session.openSession();

        vm.prank(admin);
        vm.expectRevert(NettingSession.NotAllowlisted.selector);
        session.postObligation(stranger, alice, Currency.CLP, 1e18);
    }

    function test_CannotFundBeforeLock() public {
        _mintInventory(alice, 10e18, 0, 0);
        _approveSession(alice);

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 10e18);

        vm.prank(alice);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.fund(Currency.CLP);
    }

    function test_CannotPostAfterLock() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 10e18);
        vm.prank(admin);
        session.lockSession();

        vm.prank(bob);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.postObligation(bob, alice, Currency.CLP, 1e18);
    }

    function test_PauseBlocksPostFundClaim() public {
        _mintInventory(alice, 10e18, 0, 0);
        _approveSession(alice);

        vm.prank(admin);
        session.openSession();

        vm.prank(admin);
        hub.pause();

        vm.prank(alice);
        vm.expectRevert(NettingSession.HubPaused.selector);
        session.postObligation(alice, bob, Currency.CLP, 10e18);

        vm.prank(admin);
        hub.unpause();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 10e18);
        vm.prank(admin);
        session.lockSession();

        vm.prank(admin);
        hub.pause();
        vm.prank(alice);
        vm.expectRevert(NettingSession.HubPaused.selector);
        session.fund(Currency.CLP);
    }

    function test_AdminCanPostOnBehalfOfDebtor() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(admin);
        session.postObligation(alice, bob, Currency.USD, 5e18);
        assertEq(session.obligationCount(), 1);
    }

    function test_CancelFromOpen() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 1e18);
        vm.prank(admin);
        session.cancelSession();
        assertEq(uint8(session.phase()), uint8(INettingSession.Phase.Cancelled));
    }

    function test_OnlyDebtorOrAdminCanPost() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(bob);
        vm.expectRevert(NettingSession.NotPoster.selector);
        session.postObligation(alice, bob, Currency.CLP, 1e18);
    }
}
