// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USD} from "../src/USD.sol";
import {Currency} from "../src/Currency.sol";
import {SettlementToken} from "../src/SettlementToken.sol";
import {Oracle} from "../src/Oracle.sol";
import {ProtocolHub} from "../src/ProtocolHub.sol";
import {CurrencyBucket} from "../src/CurrencyBucket.sol";

/// @notice Deploys USD, ProtocolHub, shared Oracle, and CLP+ARS CurrencyBuckets for local Anvil.
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
        ProtocolHub hub = ProtocolHub(
            address(new ERC1967Proxy(address(new ProtocolHub()), abi.encodeCall(ProtocolHub.initialize, (admin))))
        );
        Oracle oracle = new Oracle(admin, ORACLE_OP);
        oracle.setHub(address(hub));

        SettlementToken clp = SettlementToken(
            address(
                new ERC1967Proxy(
                    address(new SettlementToken()),
                    abi.encodeCall(SettlementToken.initialize, (admin, "FX Net CLP", "CLP"))
                )
            )
        );
        SettlementToken ars = SettlementToken(
            address(
                new ERC1967Proxy(
                    address(new SettlementToken()),
                    abi.encodeCall(SettlementToken.initialize, (admin, "FX Net ARS", "ARS"))
                )
            )
        );

        CurrencyBucket clpBucket = CurrencyBucket(
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
        CurrencyBucket arsBucket = CurrencyBucket(
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

        clp.grantRole(clp.ENGINE_ROLE(), address(clpBucket));
        ars.grantRole(ars.ENGINE_ROLE(), address(arsBucket));

        hub.setAllowlist(USER1, true);
        hub.setAllowlist(USER2, true);
        hub.setAllowlist(USER3, true);
        clpBucket.setFeeBps(50);
        arsBucket.setFeeBps(50);

        vm.stopBroadcast();

        string memory deployments = string.concat(
            "{\"chainId\":31337,",
            "\"usd\":\"",
            vm.toString(address(usd)),
            "\",",
            "\"hub\":\"",
            vm.toString(address(hub)),
            "\",",
            "\"oracle\":\"",
            vm.toString(address(oracle)),
            "\",",
            "\"admin\":\"",
            vm.toString(admin),
            "\",",
            "\"oracleOperator\":\"",
            vm.toString(ORACLE_OP),
            "\",",
            "\"allowlistedUsers\":[\"",
            vm.toString(admin),
            "\",\"",
            vm.toString(USER1),
            "\",\"",
            vm.toString(USER2),
            "\",\"",
            vm.toString(USER3),
            "\"],",
            "\"buckets\":{",
            "\"clp\":{\"token\":\"",
            vm.toString(address(clp)),
            "\",\"engine\":\"",
            vm.toString(address(clpBucket)),
            "\"},",
            "\"ars\":{\"token\":\"",
            vm.toString(address(ars)),
            "\",\"engine\":\"",
            vm.toString(address(arsBucket)),
            "\"}",
            "}}"
        );
        vm.writeFile("app/src/contracts/deployments.json", deployments);

        console2.log("USD", address(usd));
        console2.log("ProtocolHub", address(hub));
        console2.log("Oracle", address(oracle));
        console2.log("CLP", address(clp));
        console2.log("CLP Bucket", address(clpBucket));
        console2.log("ARS", address(ars));
        console2.log("ARS Bucket", address(arsBucket));
        console2.log("Admin", admin);
        console2.log("OracleOperator", ORACLE_OP);
        console2.log("Wrote app/src/contracts/deployments.json");
    }
}
