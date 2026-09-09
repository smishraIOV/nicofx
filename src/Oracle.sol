// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Currency} from "./Currency.sol";
import {IProtocolHub} from "./interfaces/IProtocolHub.sol";

/// @title Oracle — trusted multi-currency FX rate publisher (non-upgradeable)
///
/// @notice Rates are units-of-currency per 1 USD with 18 decimals.
///
/// @dev Two guards close the intra-window round-trip arbitrage found in review R1-C2
///      (reviews/R1-cb95b96.md):
///  - **One rate per window.** A currency's rate can be posted at most once per hub MRW, so the price
///    a party mints at is the price it redeems at within that window. Without this, an allowlisted
///    party could mint at R, have a new rate posted, and redeem at R' in the same window for a
///    risk-free profit paid out of the operator's buffer.
///  - **Deviation bound.** A post more than `maxDeviationBps` away from the previous rate reverts, so a
///    fat-fingered or compromised oracle key cannot re-rate the book by orders of magnitude. The owner
///    can override with `forceSetRate` for a genuine large move, which emits a distinct event.
contract Oracle is Ownable {
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_DEVIATION_BPS_LIMIT = 5_000; // 50%

    IProtocolHub public hub;
    address public trustedOracle;
    /// @notice Maximum move from the previous rate, in bps. 0 disables the check.
    uint16 public maxDeviationBps;

    mapping(uint8 => uint256) private _ratePerUsd;
    mapping(uint8 => uint256) private _rateWindowNonce;
    mapping(uint8 => uint256) private _lastUpdated;

    event HubUpdated(address indexed hub);
    event TrustedOracleUpdated(address indexed trustedOracle);
    event MaxDeviationUpdated(uint16 maxDeviationBps);
    event RateUpdated(uint8 indexed currency, uint256 ratePerUsd, uint256 windowNonce, uint256 timestamp);
    event RateForced(uint8 indexed currency, uint256 previousRate, uint256 ratePerUsd, uint256 windowNonce);

    error ZeroAddress();
    error ZeroRate();
    error HubNotSet();
    error WindowClosed();
    error HubPaused();
    error NotTrustedOracle();
    error InvalidCurrency();
    error RateAlreadySetForWindow();
    error DeviationTooLarge(uint256 previousRate, uint256 newRate, uint256 maxDeviationBps);
    error DeviationOutOfRange();

    constructor(address owner_, address trustedOracle_, uint16 maxDeviationBps_) Ownable(owner_) {
        if (trustedOracle_ == address(0)) revert ZeroAddress();
        if (maxDeviationBps_ > MAX_DEVIATION_BPS_LIMIT) revert DeviationOutOfRange();
        trustedOracle = trustedOracle_;
        maxDeviationBps = maxDeviationBps_;
        emit TrustedOracleUpdated(trustedOracle_);
        emit MaxDeviationUpdated(maxDeviationBps_);
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

    function setMaxDeviationBps(uint16 maxDeviationBps_) external onlyOwner {
        if (maxDeviationBps_ > MAX_DEVIATION_BPS_LIMIT) revert DeviationOutOfRange();
        maxDeviationBps = maxDeviationBps_;
        emit MaxDeviationUpdated(maxDeviationBps_);
    }

    /// @notice Post this window's rate for `currency`. One post per currency per window.
    function setRate(uint8 currency, uint256 ratePerUsd_) external {
        uint256 nonce = _validate(currency, ratePerUsd_);

        uint256 previous = _ratePerUsd[currency];
        if (previous != 0 && maxDeviationBps != 0) {
            uint256 delta = ratePerUsd_ > previous ? ratePerUsd_ - previous : previous - ratePerUsd_;
            if (delta * BPS > previous * maxDeviationBps) {
                revert DeviationTooLarge(previous, ratePerUsd_, maxDeviationBps);
            }
        }

        _store(currency, ratePerUsd_, nonce);
    }

    /// @notice Owner escape hatch for a genuine move larger than `maxDeviationBps`.
    /// @dev Still one post per window, still gated on MRW open and hub not paused.
    function forceSetRate(uint8 currency, uint256 ratePerUsd_) external onlyOwner {
        uint256 nonce = _validate(currency, ratePerUsd_);
        uint256 previous = _ratePerUsd[currency];
        _store(currency, ratePerUsd_, nonce);
        emit RateForced(currency, previous, ratePerUsd_, nonce);
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

    /// @notice True if a rate can still be posted for `currency` in the current window
    function canSetRate(uint8 currency) external view returns (bool) {
        if (address(hub) == address(0) || !Currency.isBucketCurrency(currency)) return false;
        if (!hub.windowOpen() || hub.paused()) return false;
        return _rateWindowNonce[currency] != hub.windowNonce();
    }

    function clpPerUsd() external view returns (uint256) {
        return _ratePerUsd[Currency.CLP];
    }

    function arsPerUsd() external view returns (uint256) {
        return _ratePerUsd[Currency.ARS];
    }

    function _validate(uint8 currency, uint256 ratePerUsd_) internal view returns (uint256 nonce) {
        if (msg.sender != trustedOracle && msg.sender != owner()) revert NotTrustedOracle();
        if (address(hub) == address(0)) revert HubNotSet();
        if (!Currency.isBucketCurrency(currency)) revert InvalidCurrency();
        if (!hub.windowOpen()) revert WindowClosed();
        if (hub.paused()) revert HubPaused();
        if (ratePerUsd_ == 0) revert ZeroRate();

        nonce = hub.windowNonce();
        // One rate per currency per window: the mint price is the redeem price (R1-C2)
        if (_rateWindowNonce[currency] == nonce) revert RateAlreadySetForWindow();
    }

    function _store(uint8 currency, uint256 ratePerUsd_, uint256 nonce) internal {
        _ratePerUsd[currency] = ratePerUsd_;
        _rateWindowNonce[currency] = nonce;
        _lastUpdated[currency] = block.timestamp;
        emit RateUpdated(currency, ratePerUsd_, nonce, block.timestamp);
    }
}
