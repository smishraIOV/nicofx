// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracle {
    function mxpPerUsd() external view returns (uint256);
    function rateWindowNonce() external view returns (uint256);
    function lastUpdated() external view returns (uint256);
}
