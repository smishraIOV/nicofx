// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IEngineView {
    function windowOpen() external view returns (bool);
    function windowNonce() external view returns (uint256);
    function paused() external view returns (bool);
}
