// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    function ratePerUsd(uint8 currency) external view returns (uint256);
    function rateWindowNonce(uint8 currency) external view returns (uint256);
    function lastUpdated(uint8 currency) external view returns (uint256);
    function clpPerUsd() external view returns (uint256);
    function arsPerUsd() external view returns (uint256);
}
