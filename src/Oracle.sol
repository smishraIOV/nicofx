// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Currency} from "./Currency.sol";
import {IProtocolHub} from "./interfaces/IProtocolHub.sol";

/// @title Oracle — trusted multi-currency FX rate publisher (non-upgradeable)
/// @notice Rates are units-of-currency per 1 USD with 18 decimals. setRate only while hub MRW open and not paused.
contract Oracle is Ownable {
    IProtocolHub public hub;
    address public trustedOracle;

    mapping(uint8 => uint256) private _ratePerUsd;
    mapping(uint8 => uint256) private _rateWindowNonce;
    mapping(uint8 => uint256) private _lastUpdated;

    event HubUpdated(address indexed hub);
    event TrustedOracleUpdated(address indexed trustedOracle);
    event RateUpdated(uint8 indexed currency, uint256 ratePerUsd, uint256 windowNonce, uint256 timestamp);

    error ZeroAddress();
    error ZeroRate();
    error HubNotSet();
    error WindowClosed();
    error HubPaused();
    error NotTrustedOracle();
    error InvalidCurrency();

    constructor(address owner_, address trustedOracle_) Ownable(owner_) {
        if (trustedOracle_ == address(0)) revert ZeroAddress();
        trustedOracle = trustedOracle_;
        emit TrustedOracleUpdated(trustedOracle_);
    }

    function setHub(address hub_) external onlyOwner {
        if (hub_ == address(0)) revert ZeroAddress();
        hub = IProtocolHub(hub_);
        emit HubUpdated(hub_);
    }

    function setTrustedOracle(address trustedOracle_) external onlyOwner {
        if (trustedOracle_ == address(0)) revert ZeroAddress();
        trustedOracle = trustedOracle_;
        emit TrustedOracleUpdated(trustedOracle_);
    }

    function setRate(uint8 currency, uint256 ratePerUsd_) external {
        if (msg.sender != trustedOracle) revert NotTrustedOracle();
        if (address(hub) == address(0)) revert HubNotSet();
        if (currency > Currency.ARS) revert InvalidCurrency();
        if (!hub.windowOpen()) revert WindowClosed();
        if (hub.paused()) revert HubPaused();
        if (ratePerUsd_ == 0) revert ZeroRate();

        uint256 nonce = hub.windowNonce();
        _ratePerUsd[currency] = ratePerUsd_;
        _rateWindowNonce[currency] = nonce;
        _lastUpdated[currency] = block.timestamp;

        emit RateUpdated(currency, ratePerUsd_, nonce, block.timestamp);
    }

    function ratePerUsd(uint8 currency) external view returns (uint256) {
        return _ratePerUsd[currency];
    }

    function rateWindowNonce(uint8 currency) external view returns (uint256) {
        return _rateWindowNonce[currency];
    }

    function lastUpdated(uint8 currency) external view returns (uint256) {
        return _lastUpdated[currency];
    }

    function clpPerUsd() external view returns (uint256) {
        return _ratePerUsd[Currency.CLP];
    }

    function arsPerUsd() external view returns (uint256) {
        return _ratePerUsd[Currency.ARS];
    }
}
