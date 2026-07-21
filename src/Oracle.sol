// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEngineView} from "./interfaces/IEngineView.sol";

/// @title Oracle — trusted MXP/USD rate publisher (non-upgradeable v1)
/// @notice Rate format: mxpPerUsd with 18 decimals. setRate only while MRW open and engine not paused.
contract Oracle is Ownable {
    IEngineView public engine;
    address public trustedOracle;

    uint256 public mxpPerUsd;
    uint256 public rateWindowNonce;
    uint256 public lastUpdated;

    event EngineUpdated(address indexed engine);
    event TrustedOracleUpdated(address indexed trustedOracle);
    event RateUpdated(uint256 mxpPerUsd, uint256 windowNonce, uint256 timestamp);

    error ZeroAddress();
    error ZeroRate();
    error EngineNotSet();
    error WindowClosed();
    error EnginePaused();
    error NotTrustedOracle();

    constructor(address owner_, address trustedOracle_) Ownable(owner_) {
        if (trustedOracle_ == address(0)) revert ZeroAddress();
        trustedOracle = trustedOracle_;
        emit TrustedOracleUpdated(trustedOracle_);
    }

    function setEngine(address engine_) external onlyOwner {
        if (engine_ == address(0)) revert ZeroAddress();
        engine = IEngineView(engine_);
        emit EngineUpdated(engine_);
    }

    function setTrustedOracle(address trustedOracle_) external onlyOwner {
        if (trustedOracle_ == address(0)) revert ZeroAddress();
        trustedOracle = trustedOracle_;
        emit TrustedOracleUpdated(trustedOracle_);
    }

    function setRate(uint256 mxpPerUsd_) external {
        if (msg.sender != trustedOracle) revert NotTrustedOracle();
        if (address(engine) == address(0)) revert EngineNotSet();
        if (!engine.windowOpen()) revert WindowClosed();
        if (engine.paused()) revert EnginePaused();
        if (mxpPerUsd_ == 0) revert ZeroRate();

        mxpPerUsd = mxpPerUsd_;
        rateWindowNonce = engine.windowNonce();
        lastUpdated = block.timestamp;

        emit RateUpdated(mxpPerUsd_, rateWindowNonce, lastUpdated);
    }
}
