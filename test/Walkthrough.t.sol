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
import {NettingSession} from "../src/NettingSession.sol";
import {INettingSession} from "../src/interfaces/INettingSession.sol";

/// @notice Mirrors walkthrough.md exactly, so the numbers printed in that document cannot drift
///         away from what the contracts actually do.
contract WalkthroughTest is Test {
    USD usd; ProtocolHub hub; Oracle oracle;
    SettlementToken clp; SettlementToken ars;
    CurrencyBucket clpB; CurrencyBucket arsB; NettingSession s;

    address admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil #0
    address op    = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil #1
    address u1    = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil #2 "User1"
    address u2    = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // anvil #3 "User2"
    address u3    = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // anvil #4 "User3"

    function setUp() public {
        usd = USD(address(new ERC1967Proxy(address(new USD()), abi.encodeCall(USD.initialize,(admin)))));
        hub = ProtocolHub(address(new ERC1967Proxy(address(new ProtocolHub()), abi.encodeCall(ProtocolHub.initialize,(admin)))));
        oracle = new Oracle(admin, op, 500);
        vm.prank(admin); oracle.setHub(address(hub));
        clp = SettlementToken(address(new ERC1967Proxy(address(new SettlementToken()), abi.encodeCall(SettlementToken.initialize,(admin,"FX Net CLP","CLP")))));
        ars = SettlementToken(address(new ERC1967Proxy(address(new SettlementToken()), abi.encodeCall(SettlementToken.initialize,(admin,"FX Net ARS","ARS")))));
        clpB = CurrencyBucket(address(new ERC1967Proxy(address(new CurrencyBucket()), abi.encodeCall(CurrencyBucket.initialize,(admin,address(usd),address(clp),address(oracle),address(hub),Currency.CLP)))));
        arsB = CurrencyBucket(address(new ERC1967Proxy(address(new CurrencyBucket()), abi.encodeCall(CurrencyBucket.initialize,(admin,address(usd),address(ars),address(oracle),address(hub),Currency.ARS)))));
        s = NettingSession(address(new ERC1967Proxy(address(new NettingSession()), abi.encodeCall(NettingSession.initialize,(admin,address(hub),address(usd),address(clp),address(ars))))));
        // exactly what script/Deploy.s.sol does
        vm.startPrank(admin);
        clp.grantRole(clp.ENGINE_ROLE(), address(clpB));
        ars.grantRole(ars.ENGINE_ROLE(), address(arsB));
        hub.setAllowlist(u1,true); hub.setAllowlist(u2,true); hub.setAllowlist(u3,true);
        clpB.setMintFeeBps(25); clpB.setRedeemFeeBps(50);
        arsB.setMintFeeBps(25); arsB.setRedeemFeeBps(50);
        s.setFeeBps(50);
        vm.stopPrank();
    }

    function _ack(address who, uint256 i) internal {
        uint256[] memory ix = new uint256[](1); ix[0] = i;
        vm.prank(who); s.acknowledge(ix);
    }

    function test_Walkthrough_HappyPath() public {
        // --- Part 2: window + BOTH rates -------------------------------------------------
        vm.prank(admin); hub.openWindow();
        vm.prank(op); oracle.setRate(Currency.CLP, 950e18);
        vm.prank(op); oracle.setRate(Currency.ARS, 1000e18);

        // --- Part 3: reserve for BOTH buckets (isolated vaults) --------------------------
        vm.startPrank(admin);
        usd.mint(admin, 1_000_000e18);
        usd.approve(address(clpB), type(uint256).max);
        usd.approve(address(arsB), type(uint256).max);
        clpB.depositReserve(100e18);
        arsB.depositReserve(100e18);
        usd.mint(u1, 10e18);
        usd.mint(u2, 10e18);
        vm.stopPrank();

        // --- Part 4: inventory ------------------------------------------------------------
        vm.startPrank(u1); usd.approve(address(clpB), type(uint256).max); clpB.mint(1e18); vm.stopPrank();
        vm.startPrank(u2); usd.approve(address(arsB), type(uint256).max); arsB.mint(1e18); vm.stopPrank();
        console2.log("CLP minted to User1 (1 USD in) :", clp.balanceOf(u1));
        console2.log("ARS minted to User2 (1 USD in) :", ars.balanceOf(u2));
        assertEq(clp.balanceOf(u1), 947.625e18);
        assertEq(ars.balanceOf(u2), 997.5e18);
        assertEq(clpB.accruedFees(), 0.0025e18);
        assertEq(arsB.accruedFees(), 0.0025e18);

        // --- Part 5: one session, CLP triangle + an ARS leg ------------------------------
        vm.prank(admin); s.openSession();
        uint256 sid = s.sessionId();
        vm.prank(u1); s.postObligation(u1, u2, Currency.CLP, 100e18, "clp-001"); // row 0
        vm.prank(u2); s.postObligation(u2, u3, Currency.CLP,  40e18, "clp-002"); // row 1
        vm.prank(u2); s.postObligation(u2, u3, Currency.ARS,  50e18, "ars-001"); // row 2
        vm.prank(u3); s.postObligation(u3, u1, Currency.CLP,  10e18, "clp-003"); // row 3
        assertEq(s.includedCount(sid), 0, "nothing nets until counterparties consent");
        assertEq(s.pendingAckCount(sid), 4);

        _ack(u2, 0); _ack(u3, 1); _ack(u3, 2); _ack(u1, 3);
        assertEq(s.includedCount(sid), 4);
        assertEq(s.pendingAckCount(sid), 0);

        vm.prank(admin); s.freezeSession();
        assertEq(uint8(s.phase()), uint8(INettingSession.Phase.Frozen));

        assertEq(s.netOf(sid, u1, Currency.CLP), -90e18);
        assertEq(s.netOf(sid, u2, Currency.CLP),  60e18);
        assertEq(s.netOf(sid, u3, Currency.CLP),  30e18);
        assertEq(s.netOf(sid, u2, Currency.ARS), -50e18);
        assertEq(s.netOf(sid, u3, Currency.ARS),  50e18);
        assertEq(s.requiredDeposit(sid, u1, Currency.CLP), 90.45e18);
        assertEq(s.requiredDeposit(sid, u2, Currency.ARS), 50.25e18);
        assertEq(s.eliminated(sid, Currency.CLP), 60e18);
        assertEq(s.grossPosted(sid, Currency.CLP), 150e18);
        assertEq(s.eliminated(sid, Currency.ARS), 0);
        assertEq(s.grossPosted(sid, Currency.ARS), 50e18);
        assertEq(s.counterpartyPairs(sid), 3);

        // CLP funded first: claims must STILL be closed because ARS is short (atomic across legs)
        vm.startPrank(u1); clp.approve(address(s), type(uint256).max); s.deposit(Currency.CLP, 90.45e18); vm.stopPrank();
        assertTrue(s.currencyFullyFunded(sid, Currency.CLP));
        assertFalse(s.currencyFullyFunded(sid, Currency.ARS));
        assertEq(s.fundingShortfall(sid, Currency.ARS), 50.25e18);
        assertEq(uint8(s.phase()), uint8(INettingSession.Phase.Frozen), "still frozen: ARS short");
        vm.prank(u2);
        vm.expectRevert(NettingSession.InvalidPhase.selector);
        s.claim(sid, Currency.CLP);

        // ARS funded -> locks automatically
        vm.startPrank(u2); ars.approve(address(s), type(uint256).max); s.deposit(Currency.ARS, 50.25e18); vm.stopPrank();
        assertEq(uint8(s.phase()), uint8(INettingSession.Phase.Locked));

        // --- Part 6: claims at face value -------------------------------------------------
        uint256 clpBefore2 = clp.balanceOf(u2);
        vm.prank(u2); s.claim(sid, Currency.CLP);
        vm.prank(u3); s.claim(sid, Currency.CLP);
        vm.prank(u3); s.claim(sid, Currency.ARS);
        assertEq(clp.balanceOf(u2) - clpBefore2, 60e18, "User2 receives 60 CLP at face value");
        assertEq(clp.balanceOf(u3), 30e18, "User3 receives 30 CLP at face value");
        assertEq(ars.balanceOf(u3), 50e18, "User3 receives 50 ARS at face value");
        assertEq(s.accruedFees(Currency.CLP), 0.45e18);
        assertEq(s.accruedFees(Currency.ARS), 0.25e18);
        assertEq(uint8(s.phase()), uint8(INettingSession.Phase.Settled));

        console2.log("final: session settled; CLP fee 0.45, ARS fee 0.25");
    }

    /// The block arithmetic quoted in the failure-path section
    function test_Walkthrough_CloseWindowMinimum() public {
        vm.prank(admin); hub.openWindow();
        uint256 closable = hub.windowClosableFromBlock();
        assertEq(closable, block.number + 50);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProtocolHub.MinWindowNotElapsed.selector, closable));
        hub.closeWindow();
        vm.roll(closable);
        vm.prank(admin); hub.closeWindow();
        assertTrue(hub.withdrawalWindowActive());
    }
}
