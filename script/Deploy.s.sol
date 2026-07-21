// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {MXP} from "../src/MXP.sol";
import {Oracle} from "../src/Oracle.sol";
import {MXPEngine} from "../src/MXPEngine.sol";

/// @notice Deploys USD, MXP, Oracle, MXPEngine and wires roles for local Anvil.
contract Deploy is Script {
    // Anvil account 1 / 2 / 3 / 4
    address constant ORACLE_OP = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant USER1 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant USER2 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant USER3 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address admin = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        USD usd = USD(address(new ERC1967Proxy(address(new USD()), abi.encodeCall(USD.initialize, (admin)))));
        MXP mxp = MXP(address(new ERC1967Proxy(address(new MXP()), abi.encodeCall(MXP.initialize, (admin)))));
        Oracle oracle = new Oracle(admin, ORACLE_OP);
        MXPEngine engine = MXPEngine(
            address(
                new ERC1967Proxy(
                    address(new MXPEngine()),
                    abi.encodeCall(MXPEngine.initialize, (admin, address(usd), address(mxp), address(oracle)))
                )
            )
        );

        mxp.grantRole(mxp.ENGINE_ROLE(), address(engine));
        oracle.setEngine(address(engine));
        engine.setAllowlist(USER1, true);
        engine.setAllowlist(USER2, true);
        engine.setAllowlist(USER3, true);
        engine.setFeeBps(50);

        vm.stopBroadcast();

        string memory deployments = string.concat(
            "{\"chainId\":31337,",
            "\"usd\":\"", vm.toString(address(usd)), "\",",
            "\"mxp\":\"", vm.toString(address(mxp)), "\",",
            "\"oracle\":\"", vm.toString(address(oracle)), "\",",
            "\"engine\":\"", vm.toString(address(engine)), "\",",
            "\"admin\":\"", vm.toString(admin), "\",",
            "\"oracleOperator\":\"", vm.toString(ORACLE_OP), "\"}"
        );
        vm.writeFile("app/src/contracts/deployments.json", deployments);

        console2.log("USD", address(usd));
        console2.log("MXP", address(mxp));
        console2.log("Oracle", address(oracle));
        console2.log("MXPEngine", address(engine));
        console2.log("Admin", admin);
        console2.log("OracleOperator", ORACLE_OP);
        console2.log("Wrote app/src/contracts/deployments.json");
    }
}
