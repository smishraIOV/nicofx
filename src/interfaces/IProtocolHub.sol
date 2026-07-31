// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IProtocolHub {
    function windowOpen() external view returns (bool);
    function windowNonce() external view returns (uint256);
    function paused() external view returns (bool);
    function isAllowlisted(address account) external view returns (bool);
    function withdrawalWindowActive() external view returns (bool);
    function windowEndBlock() external view returns (uint256);
    function withdrawalWindowStart() external view returns (uint256);
}
