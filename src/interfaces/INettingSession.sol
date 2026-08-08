// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INettingSession {
    enum Phase {
        Idle,
        Open,
        Locked,
        Settled,
        Cancelled
    }

    struct Obligation {
        address debtor;
        address creditor;
        uint8 currency;
        uint256 amount;
    }

    function phase() external view returns (Phase);
    function sessionId() external view returns (uint256);
    function obligationCount() external view returns (uint256);
    function obligations(uint256 index) external view returns (Obligation memory);
    function participants() external view returns (address[] memory);
    function netOf(address party, uint8 currency) external view returns (int256);
    function fundedOf(address party, uint8 currency) external view returns (bool);
    function claimedOf(address party, uint8 currency) external view returns (bool);
    function totalCreditorNets(uint8 currency) external view returns (uint256);
    function escrowBalance(uint8 currency) external view returns (uint256);
    function currencyFullyFunded(uint8 currency) external view returns (bool);
}
