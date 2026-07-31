// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title SettlementToken — FX settlement ERC20; mint/burn only via its CurrencyBucket
contract SettlementToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant TOKEN_ADMIN_ROLE = keccak256("TOKEN_ADMIN_ROLE");
    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, string memory name_, string memory symbol_) external initializer {
        __ERC20_init(name_, symbol_);
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TOKEN_ADMIN_ROLE, admin);
    }

    function mint(address to, uint256 amount) external onlyRole(ENGINE_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(ENGINE_ROLE) {
        _burn(from, amount);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
