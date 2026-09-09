// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
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

    bytes32 internal constant ACK_TYPEHASH =
        keccak256("Acknowledgement(uint256 sessionId,uint256 index,bytes32 ref,address party,uint256 deadline)");

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

        vm.startPrank(admin);
        clp.grantRole(clp.ENGINE_ROLE(), admin);
        ars.grantRole(ars.ENGINE_ROLE(), admin);
        hub.setAllowlist(alice, true);
        hub.setAllowlist(bob, true);
        hub.setAllowlist(carol, true);
        session.setFeeBps(50);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _mintInventory(address to, uint256 clpAmt, uint256 arsAmt, uint256 usdAmt) internal {
        vm.startPrank(admin);
        if (clpAmt > 0) clp.mint(to, clpAmt);
        if (arsAmt > 0) ars.mint(to, arsAmt);
        if (usdAmt > 0) usd.mint(to, usdAmt);
        vm.stopPrank();
        vm.startPrank(to);
        clp.approve(address(session), type(uint256).max);
        ars.approve(address(session), type(uint256).max);
        usd.approve(address(session), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Debtor posts, creditor acknowledges — the normal two-sided consent path
    function _agreed(address debtor, address creditor, uint8 currency, uint256 amount, bytes32 ref)
        internal
        returns (uint256 index)
    {
        vm.prank(debtor);
        index = session.postObligation(debtor, creditor, currency, amount, ref);
        uint256[] memory idx = new uint256[](1);
        idx[0] = index;
        vm.prank(creditor);
        session.acknowledge(idx);
    }

    function _sid() internal view returns (uint256) {
        return session.sessionId();
    }

    function _phase() internal view returns (INettingSession.Phase) {
        return session.phase();
    }

    function _depositAll(address party, uint8 currency) internal {
        uint256 outstanding = session.outstandingDeposit(_sid(), party, currency);
        vm.prank(party);
        session.deposit(currency, outstanding);
    }

    function _claim(address party, uint256 sid, uint8 currency) internal {
        vm.prank(party);
        session.claim(sid, currency);
    }

    // ---------------------------------------------- happy path / core netting

    function test_TriangleFullyNetsToZeroAndSettlesOnFreeze() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 50e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 50e18, "inv-2");
        _agreed(carol, alice, Currency.CLP, 50e18, "inv-3");

        vm.prank(admin);
        session.freezeSession();

        // No debtors, so full funding is vacuous: the session locks and settles immediately
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Settled));
        assertEq(session.netOf(_sid(), alice, Currency.CLP), 0);
        assertEq(session.eliminated(_sid(), Currency.CLP), 150e18);
        assertEq(session.accruedFees(Currency.CLP), 0, "an equal cycle is free");
    }

    /// Readme example graph: -90 / +60 / +30, and creditors are paid at FACE value (R1-M4)
    function test_ResidualNetsCreditorsPaidAtFaceValue() public {
        _mintInventory(alice, 101e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 40e18, "inv-2");
        _agreed(carol, alice, Currency.CLP, 10e18, "inv-3");

        vm.prank(admin);
        session.freezeSession();

        assertEq(session.netOf(_sid(), alice, Currency.CLP), -90e18);
        assertEq(session.netOf(_sid(), bob, Currency.CLP), 60e18);
        assertEq(session.netOf(_sid(), carol, Currency.CLP), 30e18);
        assertEq(session.eliminated(_sid(), Currency.CLP), 60e18);

        // The debtor funds net + fee (R1-M4), not the creditors taking a haircut
        assertEq(session.requiredDeposit(_sid(), alice, Currency.CLP), 90.45e18);
        assertEq(session.totalRequired(_sid(), Currency.CLP), 90.45e18);

        _depositAll(alice, Currency.CLP);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Locked));

        _claim(bob, _sid(), Currency.CLP);
        _claim(carol, _sid(), Currency.CLP);

        assertEq(clp.balanceOf(bob), 60e18, "creditor paid net at face value");
        assertEq(clp.balanceOf(carol), 30e18, "creditor paid net at face value");
        assertEq(session.accruedFees(Currency.CLP), 0.45e18, "fee came from the debtor");
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Settled));
    }

    function test_CrossCurrencyFundAndClaimAreIndependent() public {
        _mintInventory(alice, 101e18, 0, 0);
        _mintInventory(bob, 0, 71e18, 0);

        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "clp-1");
        _agreed(bob, carol, Currency.ARS, 70e18, "ars-1");
        vm.prank(admin);
        session.freezeSession();

        // CLP funded first: still Frozen because ARS is short
        _depositAll(alice, Currency.CLP);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Frozen));
        assertTrue(session.currencyFullyFunded(_sid(), Currency.CLP));
        assertFalse(session.currencyFullyFunded(_sid(), Currency.ARS));

        // Claims open only once every currency is funded — that is the DVP property
        uint256 sidC = _sid();
        vm.prank(bob);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.claim(sidC, Currency.CLP);

        _depositAll(bob, Currency.ARS);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Locked));

        _claim(bob, _sid(), Currency.CLP);
        _claim(carol, _sid(), Currency.ARS);
        assertEq(clp.balanceOf(bob), 100e18);
        assertEq(ars.balanceOf(carol), 70e18);
    }

    // ------------------------------------------------------ R1-C1: DVP and unwind

    /// The original C1 repro: one debtor never delivers. Escrow must be recoverable and the
    /// contract must not be bricked.
    function test_R1_C1_ShortDebtorDoesNotTrapEscrowOrBrickContract() public {
        _mintInventory(alice, 101e18, 0, 0);
        // bob holds no inventory and will not deliver
        vm.prank(admin);
        session.openSession();
        _agreed(alice, carol, Currency.CLP, 100e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 50e18, "inv-2");
        vm.prank(admin);
        session.freezeSession();
        uint256 sid = _sid();

        _depositAll(alice, Currency.CLP);
        assertEq(clp.balanceOf(address(session)), 100.5e18);
        assertEq(session.fundingShortfall(sid, Currency.CLP), 50.25e18);

        // Not discharged: nothing is claimable while short
        vm.prank(carol);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.claim(sid, Currency.CLP);

        // Anyone can declare failure once the deadline passes
        vm.expectRevert(NettingSession.DeadlineNotReached.selector);
        session.declareFailure(sid);
        vm.roll(session.fundingDeadline(sid) + 1);
        vm.prank(stranger);
        session.declareFailure(sid);
        assertEq(uint8(session.phaseOf(sid)), uint8(INettingSession.Phase.Failed));

        // Alice recovers every token she deposited
        vm.prank(alice);
        session.withdrawDeposit(sid, Currency.CLP);
        assertEq(clp.balanceOf(alice), 101e18, "deposit fully recovered");
        assertEq(clp.balanceOf(address(session)), 0);

        // And the contract is not bricked
        vm.prank(admin);
        session.openSession();
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Open));
        assertEq(_sid(), sid + 1);
    }

    /// While Frozen, nothing is discharged, so a depositor may withdraw at will (DVP)
    function test_R1_C1_DepositIsWithdrawableWhileFrozen() public {
        _mintInventory(alice, 101e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 200e18, "inv-2"); // keeps the session short
        vm.prank(admin);
        session.freezeSession();

        vm.prank(alice);
        session.deposit(Currency.CLP, 40e18);
        assertEq(session.escrowBalance(_sid(), Currency.CLP), 40e18);

        uint256 sidW = _sid();
        vm.prank(alice);
        session.withdrawDeposit(sidW, Currency.CLP);
        assertEq(clp.balanceOf(alice), 101e18);
        assertEq(session.escrowBalance(_sid(), Currency.CLP), 0);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Frozen));
    }

    /// A griefer posting a large unfundable obligation cannot hold others' deposits hostage
    function test_R1_C1_GrieferCannotHoldEscrowHostage() public {
        _mintInventory(alice, 101e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, carol, Currency.CLP, 100e18, "inv-1");
        // stranger is not allowlisted, so use bob as the griefer: huge self-declared debt
        _agreed(bob, carol, Currency.CLP, 1_000_000e18, "grief-1");
        vm.prank(admin);
        session.freezeSession();

        vm.prank(alice);
        session.deposit(Currency.CLP, 100.5e18);

        // Admin can abandon immediately; deposits stay with their depositors
        vm.prank(admin);
        session.cancelSession();
        uint256 sidW = _sid();
        vm.prank(alice);
        session.withdrawDeposit(sidW, Currency.CLP);
        assertEq(clp.balanceOf(alice), 101e18);
    }

    /// cancelSession used to revert with EscrowNotEmpty once anyone had funded
    function test_R1_C1_CancelWorksWithDepositsPresent() public {
        _mintInventory(alice, 101e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 500e18, "inv-2");
        vm.prank(admin);
        session.freezeSession();
        vm.prank(alice);
        session.deposit(Currency.CLP, 10e18);

        vm.prank(admin);
        session.cancelSession();
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Cancelled));
    }

    /// Escape hatches must work while paused, or pausing re-traps deposits
    function test_R1_C1_RecoveryWorksWhilePaused() public {
        _mintInventory(alice, 101e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        _agreed(bob, carol, Currency.CLP, 500e18, "inv-2");
        vm.prank(admin);
        session.freezeSession();
        vm.prank(alice);
        session.deposit(Currency.CLP, 100.5e18);
        uint256 sid = _sid();

        vm.roll(session.fundingDeadline(sid) + 1);
        vm.prank(admin);
        hub.pause();

        session.declareFailure(sid);
        vm.prank(alice);
        session.withdrawDeposit(sid, Currency.CLP);
        assertEq(clp.balanceOf(alice), 101e18);
    }

    function test_R1_C1_CannotDeclareFailureWhenFullyFunded() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);

        // Already locked, so failure is not a valid transition
        uint256 sid = _sid();
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.declareFailure(sid);
    }

    function test_R1_C1_PartialDepositsAccumulate() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();

        vm.startPrank(alice);
        session.deposit(Currency.CLP, 40e18);
        session.deposit(Currency.CLP, 40e18);
        assertEq(session.outstandingDeposit(_sid(), alice, Currency.CLP), 20.5e18);
        vm.expectRevert(abi.encodeWithSelector(NettingSession.DepositExceedsRequirement.selector, 20.5e18));
        session.deposit(Currency.CLP, 21e18);
        session.deposit(Currency.CLP, 20.5e18);
        vm.stopPrank();

        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Locked));
    }

    /// Unclaimed entitlements survive later sessions (they used to be wiped by openSession)
    function test_PastSessionClaimSurvivesNewSession() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);
        uint256 sid = _sid();

        // Bob does not claim; admin opens the next session
        vm.startPrank(admin);
        session.openSession();
        vm.stopPrank();
        assertEq(_sid(), sid + 1);

        // Old entitlement is still readable and still claimable
        assertEq(session.netOf(sid, bob, Currency.CLP), 100e18);
        vm.prank(bob);
        session.claim(sid, Currency.CLP);
        assertEq(clp.balanceOf(bob), 100e18);
    }

    // ------------------------------------------------------------ R1-H2: consent

    function test_R1_H2_UnacknowledgedRowDoesNotNet() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");

        assertEq(session.netOf(_sid(), alice, Currency.CLP), 0, "not netted until the creditor consents");
        assertEq(session.grossPosted(_sid(), Currency.CLP), 0, "gross counts consented rows only");
        assertEq(session.includedCount(_sid()), 0);
        assertEq(session.pendingAckCount(_sid()), 1);

        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(bob);
        session.acknowledge(idxs);
        assertEq(session.netOf(_sid(), alice, Currency.CLP), -100e18);
        assertEq(session.grossPosted(_sid(), Currency.CLP), 100e18);
    }

    /// The admin can still post on behalf of parties, but it binds nobody until both consent
    function test_R1_H2_AdminPostedRowNeedsBothParties() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(admin);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        assertEq(session.includedCount(_sid()), 0);

        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(bob);
        session.acknowledge(idxs);
        assertEq(session.includedCount(_sid()), 0, "creditor alone is not enough");

        vm.prank(alice);
        session.acknowledge(idxs);
        assertEq(session.includedCount(_sid()), 1);
    }

    function test_R1_H2_FreezeRejectsBookWithNoConsentedRows() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        vm.expectRevert(NettingSession.NoIncludedObligations.selector);
        session.freezeSession();
    }

    function test_R1_H2_CreditorMayPostAndDebtorAcknowledges() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(bob); // creditor issues the invoice
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        assertEq(session.includedCount(_sid()), 0);
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(alice);
        session.acknowledge(idxs);
        assertEq(session.netOf(_sid(), bob, Currency.CLP), 100e18);
    }

    function test_R1_H2_NonPartyCannotAcknowledge() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(carol);
        vm.expectRevert(NettingSession.NotParty.selector);
        session.acknowledge(idxs);
    }

    function test_R1_H2_AcknowledgeWithSignature() public {
        uint256 bobKey = 0xB0B;
        address bobSigner = vm.addr(bobKey);
        vm.prank(admin);
        hub.setAllowlist(bobSigner, true);

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bobSigner, Currency.CLP, 100e18, "inv-1");

        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(ACK_TYPEHASH, _sid(), idx, bytes32("inv-1"), bobSigner, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);

        // Relayed by anyone
        vm.prank(stranger);
        session.acknowledgeWithSig(idx, bobSigner, deadline, abi.encodePacked(r, s, v));
        assertEq(session.netOf(_sid(), bobSigner, Currency.CLP), 100e18);
    }

    function test_R1_H2_SignatureFromWrongPartyRejected() public {
        uint256 wrongKey = 0xDEAD;
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");

        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(ACK_TYPEHASH, _sid(), idx, bytes32("inv-1"), bob, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        vm.expectRevert(NettingSession.InvalidSignature.selector);
        session.acknowledgeWithSig(idx, bob, deadline, abi.encodePacked(r, s, v));
    }

    function test_R1_H2_ExpiredSignatureRejected() public {
        uint256 bobKey = 0xB0B;
        address bobSigner = vm.addr(bobKey);
        vm.prank(admin);
        hub.setAllowlist(bobSigner, true);
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bobSigner, Currency.CLP, 100e18, "inv-1");

        uint256 deadline = block.timestamp - 1;
        bytes32 structHash = keccak256(abi.encode(ACK_TYPEHASH, _sid(), idx, bytes32("inv-1"), bobSigner, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);

        vm.expectRevert(NettingSession.SignatureExpired.selector);
        session.acknowledgeWithSig(idx, bobSigner, deadline, abi.encodePacked(r, s, v));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NicoFX NettingSession"),
                keccak256("1"),
                block.chainid,
                address(session)
            )
        );
    }

    // ------------------------------------------- R1-H1: refs, dedupe, visibility

    function test_R1_H1_DuplicateRefRejected() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(alice);
        vm.expectRevert(NettingSession.DuplicateRef.selector);
        session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
    }

    function test_R1_H1_ZeroRefRejected() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.ZeroRef.selector);
        session.postObligation(alice, bob, Currency.CLP, 100e18, bytes32(0));
    }

    /// An invoice discharged by a locked session cannot be posted again
    function test_R1_H1_SettledRefCannotBeReposted() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.RefAlreadySettled.selector);
        session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
    }

    /// A ref from a failed session is free to re-post
    function test_R1_H1_RefFromFailedSessionCanBeReposted() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        uint256 sid = _sid();
        vm.roll(session.fundingDeadline(sid) + 1);
        session.declareFailure(sid);

        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        assertEq(session.obligationCount(_sid()), 1);
    }

    /// eliminated is only meaningful next to the participant/pair counts it is reported with
    function test_R1_H1_WashIsVisibleInPairCounts() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 1_000e18, "wash-1");
        _agreed(bob, alice, Currency.CLP, 1_000e18, "wash-2");
        vm.prank(admin);
        session.freezeSession();

        assertEq(session.eliminated(_sid(), Currency.CLP), 2_000e18);
        assertEq(session.participantCount(_sid()), 2, "two addresses only");
        assertEq(session.counterpartyPairs(_sid()), 2, "a wash shows as a single reciprocal pair set");
    }

    function test_VoidObligationReversesNets() public {
        vm.prank(admin);
        session.openSession();
        uint256 idx = _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        assertEq(session.netOf(_sid(), alice, Currency.CLP), -100e18);

        vm.prank(alice);
        session.voidObligation(idx);
        assertEq(session.netOf(_sid(), alice, Currency.CLP), 0);
        assertEq(session.grossPosted(_sid(), Currency.CLP), 0);
        assertEq(session.includedCount(_sid()), 0);

        // The ref is freed so a corrected row can replace it
        vm.prank(alice);
        session.postObligation(alice, bob, Currency.CLP, 80e18, "inv-1");
    }

    function test_VoidRequiresPartyOrAdmin() public {
        vm.prank(admin);
        session.openSession();
        uint256 idx = _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(carol);
        vm.expectRevert(NettingSession.NotParty.selector);
        session.voidObligation(idx);
    }

    // ---------------------------------------------------------- R1-H3: fee snapshot

    /// The fee is fixed when the session opens, before any party consents
    function test_R1_H3_FeeCannotBeRepricedMidSession() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();

        // Admin raises the fee to the cap after the book is frozen
        vm.prank(admin);
        session.setFeeBps(1000);

        assertEq(session.sessionFeeBps(_sid()), 50, "live session keeps its opening fee");
        assertEq(session.requiredDeposit(_sid(), alice, Currency.CLP), 100.5e18);
        _depositAll(alice, Currency.CLP);
        _claim(bob, _sid(), Currency.CLP);
        assertEq(clp.balanceOf(bob), 100e18, "creditor unaffected by the re-price");
        assertEq(session.accruedFees(Currency.CLP), 0.5e18);
    }

    function test_R1_H3_NewFeeAppliesToNextSession() public {
        vm.prank(admin);
        session.setFeeBps(200);
        vm.prank(admin);
        session.openSession();
        assertEq(session.sessionFeeBps(_sid()), 200);
    }

    function test_FeeTooHighReverts() public {
        vm.prank(admin);
        vm.expectRevert(NettingSession.FeeTooHigh.selector);
        session.setFeeBps(1001);
    }

    // ------------------------------------------------- R1-M2: allowlist and claims

    function test_R1_M2_DelistedCreditorCannotClaim() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);

        uint256 sidD = _sid();
        vm.prank(admin);
        hub.setAllowlist(bob, false);
        vm.prank(bob);
        vm.expectRevert(NettingSession.NotAllowlisted.selector);
        session.claim(sidD, Currency.CLP);

        // Entitlement survives: re-listing restores the claim
        vm.prank(admin);
        hub.setAllowlist(bob, true);
        _claim(bob, _sid(), Currency.CLP);
        assertEq(clp.balanceOf(bob), 100e18);
    }

    function test_R1_M2_QuarantineSweepOfDelistedClaim() public {
        address quarantine = address(0x9999);
        _mintInventory(alice, 200e18, 0, 0);
        vm.startPrank(admin);
        session.setQuarantineAddress(quarantine);
        session.openSession();
        vm.stopPrank();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);

        uint256 sidQ = _sid();
        vm.prank(admin);
        vm.expectRevert(NettingSession.StillAllowlisted.selector);
        session.sweepQuarantined(sidQ, bob, Currency.CLP);

        vm.startPrank(admin);
        hub.setAllowlist(bob, false);
        session.sweepQuarantined(sidQ, bob, Currency.CLP);
        vm.stopPrank();

        assertEq(clp.balanceOf(quarantine), 100e18);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Settled), "sweep completes settlement");
    }

    /// A de-listed debtor must still be able to meet what it owes, or the session deadlocks
    function test_R1_M2_DelistedDebtorCanStillDeposit() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();

        vm.prank(admin);
        hub.setAllowlist(alice, false);
        _depositAll(alice, Currency.CLP);
        assertEq(uint8(_phase()), uint8(INettingSession.Phase.Locked));
    }

    function test_NonAllowlistedCannotPost() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(stranger);
        vm.expectRevert(NettingSession.NotAllowlisted.selector);
        session.postObligation(stranger, bob, Currency.CLP, 1e18, "inv-1");
    }

    // ------------------------------------------------------------ R1-M5: reporting

    function test_R1_M5_EscrowBalanceExcludesFeeIncomeAndStrays() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);
        _claim(bob, _sid(), Currency.CLP);

        // 0.5 CLP of fee income remains in the contract
        assertEq(session.accruedFees(Currency.CLP), 0.5e18);
        vm.prank(admin);
        session.openSession();

        assertEq(session.escrowBalance(_sid(), Currency.CLP), 0, "fresh session reports no escrow");
        assertEq(session.tokenBalance(Currency.CLP), 0.5e18, "raw balance still visible for reconciliation");

        // A stray transfer does not move the escrow figure either
        vm.prank(admin);
        clp.mint(address(session), 7e18);
        assertEq(session.escrowBalance(_sid(), Currency.CLP), 0);
        assertEq(session.tokenBalance(Currency.CLP), 7.5e18);
    }

    // ------------------------------------------------------------ R1-M7: net caps

    function test_R1_M7_NetCapBlocksOversizedPosition() public {
        vm.startPrank(admin);
        session.setMaxNet(alice, Currency.CLP, 50e18);
        session.openSession();
        vm.stopPrank();

        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(NettingSession.NetLimitExceeded.selector, alice, Currency.CLP, -100e18, 50e18)
        );
        session.acknowledge(idxs);
    }

    function test_R1_M7_NetCapAppliesToCreditorExposureToo() public {
        vm.startPrank(admin);
        session.setMaxNet(bob, Currency.CLP, 50e18);
        session.openSession();
        vm.stopPrank();

        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(NettingSession.NetLimitExceeded.selector, bob, Currency.CLP, 100e18, 50e18)
        );
        session.acknowledge(idxs);
    }

    function test_R1_M7_WithinCapIsAccepted() public {
        vm.startPrank(admin);
        session.setMaxNet(alice, Currency.CLP, 100e18);
        session.openSession();
        vm.stopPrank();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        assertEq(session.netOf(_sid(), alice, Currency.CLP), -100e18);
    }

    // ------------------------------------------------------------ lifecycle gates

    function test_CannotPostAfterFreeze() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        session.freezeSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.postObligation(alice, bob, Currency.CLP, 1e18, "inv-2");
    }

    function test_CannotDepositBeforeFreeze() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(alice);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.deposit(Currency.CLP, 1e18);
    }

    function test_CannotOpenWhileSessionLive() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(admin);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        session.openSession();
    }

    function test_PauseBlocksPostAckDepositClaim() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        uint256 idx = session.postObligation(alice, bob, Currency.CLP, 100e18, "inv-1");
        vm.prank(admin);
        hub.pause();

        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        vm.prank(bob);
        vm.expectRevert(NettingSession.HubPaused.selector);
        session.acknowledge(idxs);
        vm.prank(alice);
        vm.expectRevert(NettingSession.HubPaused.selector);
        session.postObligation(alice, carol, Currency.CLP, 1e18, "inv-2");
        vm.prank(admin);
        vm.expectRevert(NettingSession.HubPaused.selector);
        session.freezeSession();
    }

    function test_OnlyDebtorCreditorOrAdminCanPost() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(carol);
        vm.expectRevert(NettingSession.NotPoster.selector);
        session.postObligation(alice, bob, Currency.CLP, 1e18, "inv-1");
    }

    function test_SelfDebtRejected() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.SelfDebt.selector);
        session.postObligation(alice, alice, Currency.CLP, 1e18, "inv-1");
    }

    function test_AmountTooLargeRejected() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.AmountTooLarge.selector);
        session.postObligation(alice, bob, Currency.CLP, uint256(type(uint128).max) + 1, "inv-1");
    }

    function test_InvalidCurrencyRejected() public {
        vm.prank(admin);
        session.openSession();
        vm.prank(alice);
        vm.expectRevert(NettingSession.InvalidCurrency.selector);
        session.postObligation(alice, bob, 3, 1e18, "inv-1");
    }

    // ------------------------------------------------------------- R1-H4: scaling

    /// openSession no longer clears state, so it is flat regardless of the previous book size,
    /// and freezeSession no longer loops over the book.
    function test_R1_H4_OpenAndFreezeGasAreFlatInBookSize() public {
        (uint256 freezeSmall, uint256 openSmall) = _runBook(10);
        (uint256 freezeLarge, uint256 openLarge) = _runBook(200);

        console2.log("book   10: freeze", freezeSmall, "next open", openSmall);
        console2.log("book  200: freeze", freezeLarge, "next open", openLarge);

        // Both are O(1): allow generous slack for warm/cold storage differences
        assertLt(openLarge, openSmall + 30_000, "openSession must not scale with the book");
        assertLt(freezeLarge, freezeSmall + 30_000, "freezeSession must not scale with the book");
        assertLt(freezeLarge, 300_000, "freeze fits comfortably in a block at 200 participants");
    }

    function _runBook(uint256 pairs) internal returns (uint256 freezeGas, uint256 openGas) {
        address[] memory ps = new address[](pairs + 1);
        for (uint256 i = 0; i < ps.length; ++i) {
            ps[i] = address(uint160(0x100000 + i + pairs * 1000));
            vm.prank(admin);
            hub.setAllowlist(ps[i], true);
        }
        vm.prank(admin);
        session.openSession();
        for (uint256 i = 0; i < pairs; ++i) {
            _agreed(ps[i], ps[i + 1], Currency.CLP, 1e18, bytes32(uint256(0xAA0000 + i + pairs * 1000)));
        }
        uint256 g = gasleft();
        vm.prank(admin);
        session.freezeSession();
        freezeGas = g - gasleft();

        vm.prank(admin);
        session.cancelSession();
        g = gasleft();
        vm.prank(admin);
        session.openSession();
        openGas = g - gasleft();
        vm.prank(admin);
        session.cancelSession();
    }

    // ------------------------------------------------------------- invariants

    /// Per-currency nets sum to zero, so the debtor and creditor sides are always equal
    function test_Invariant_NetsSumToZero() public {
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "i1");
        _agreed(bob, carol, Currency.CLP, 40e18, "i2");
        _agreed(carol, alice, Currency.CLP, 10e18, "i3");
        _agreed(alice, carol, Currency.ARS, 33e18, "i4");
        vm.prank(admin);
        session.freezeSession();

        for (uint8 c = 0; c < 3; ++c) {
            int256 sum;
            address[] memory ps = session.participants(_sid());
            for (uint256 i = 0; i < ps.length; ++i) {
                sum += session.netOf(_sid(), ps[i], c);
            }
            assertEq(sum, 0, "nets must sum to zero");
            assertEq(
                session.totalCreditorNets(_sid(), c), session.totalDebtorNets(_sid(), c), "sides must be equal"
            );
        }
    }

    /// Escrow held always covers the claims still outstanding
    function test_Invariant_EscrowCoversOutstandingClaims() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "i1");
        _agreed(alice, carol, Currency.CLP, 50e18, "i2");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);
        uint256 sid = _sid();

        _assertEscrowCoversClaims(sid);
        vm.prank(bob);
        session.claim(sid, Currency.CLP);
        _assertEscrowCoversClaims(sid);
        vm.prank(carol);
        session.claim(sid, Currency.CLP);
        _assertEscrowCoversClaims(sid);
        assertEq(session.escrowBalance(sid, Currency.CLP), 0);
    }

    function _assertEscrowCoversClaims(uint256 sid) internal view {
        address[] memory ps = session.participants(sid);
        uint256 outstanding;
        for (uint256 i = 0; i < ps.length; ++i) {
            int256 n = session.netOf(sid, ps[i], Currency.CLP);
            if (n > 0 && !session.claimedOf(sid, ps[i], Currency.CLP)) outstanding += uint256(n);
        }
        assertGe(session.escrowBalance(sid, Currency.CLP), outstanding, "escrow must cover open claims");
        assertGe(
            clp.balanceOf(address(session)),
            outstanding + session.accruedFees(Currency.CLP),
            "token balance must cover claims plus booked fees"
        );
    }

    /// Fee income is only ever booked for sessions that actually locked
    function test_Invariant_FailedSessionAccruesNoFees() public {
        _mintInventory(alice, 200e18, 0, 0);
        vm.prank(admin);
        session.openSession();
        _agreed(alice, bob, Currency.CLP, 100e18, "i1");
        _agreed(bob, carol, Currency.CLP, 900e18, "i2");
        vm.prank(admin);
        session.freezeSession();
        _depositAll(alice, Currency.CLP);
        uint256 sid = _sid();

        vm.roll(session.fundingDeadline(sid) + 1);
        session.declareFailure(sid);
        assertEq(session.accruedFees(Currency.CLP), 0, "no fee on a failed session");

        vm.prank(alice);
        session.withdrawDeposit(sid, Currency.CLP);
        assertEq(clp.balanceOf(alice), 200e18, "depositor made whole including the fee portion");
    }

    function test_WithdrawFeesCannotExceedAccrued() public {
        vm.prank(admin);
        vm.expectRevert(NettingSession.InsufficientFees.selector);
        session.withdrawFees(Currency.CLP, 1);
    }
}
