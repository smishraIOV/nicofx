// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INettingSession {
    /// @notice Session lifecycle.
    /// @dev Delivery-versus-payment: obligations are discharged only on the `Frozen -> Locked`
    ///      transition, which happens when every currency is fully funded. While `Frozen`, deposits
    ///      are freely withdrawable and nothing is discharged, so no party is ever bound-but-unpaid.
    enum Phase {
        Idle, // no session yet
        Open, // posting + acknowledging
        Frozen, // nets final, debtors depositing, deposits withdrawable, nothing discharged
        Locked, // fully funded: obligations discharged, creditor claims open
        Settled, // every creditor claim taken
        Cancelled, // admin abandoned before locking; deposits refundable
        Failed // funding deadline passed while short; deposits refundable
    }

    struct Obligation {
        address debtor;
        address creditor;
        uint8 currency;
        uint256 amount;
        /// @notice Caller-supplied external reference (invoice / trade id). Unique per session.
        bytes32 ref;
        bool debtorAck;
        bool creditorAck;
        /// @notice True once both parties consented and the row was folded into the nets
        bool included;
        bool voided;
    }

    // Lifecycle
    function phase() external view returns (Phase);
    function phaseOf(uint256 sessionId) external view returns (Phase);
    function sessionId() external view returns (uint256);
    function fundingDeadline(uint256 sessionId) external view returns (uint256);

    // Obligation book
    function obligationCount(uint256 sessionId) external view returns (uint256);
    function obligations(uint256 sessionId, uint256 index) external view returns (Obligation memory);
    function includedCount(uint256 sessionId) external view returns (uint256);
    function pendingAckCount(uint256 sessionId) external view returns (uint256);
    function participants(uint256 sessionId) external view returns (address[] memory);
    function participantCount(uint256 sessionId) external view returns (uint256);

    // Nets
    function netOf(uint256 sessionId, address party, uint8 currency) external view returns (int256);
    function totalCreditorNets(uint256 sessionId, uint8 currency) external view returns (uint256);
    function totalDebtorNets(uint256 sessionId, uint8 currency) external view returns (uint256);

    // Funding
    function requiredDeposit(uint256 sessionId, address party, uint8 currency) external view returns (uint256);
    function depositedOf(uint256 sessionId, address party, uint8 currency) external view returns (uint256);
    function outstandingDeposit(uint256 sessionId, address party, uint8 currency) external view returns (uint256);
    function totalRequired(uint256 sessionId, uint8 currency) external view returns (uint256);
    function escrowBalance(uint256 sessionId, uint8 currency) external view returns (uint256);
    function tokenBalance(uint8 currency) external view returns (uint256);
    function currencyFullyFunded(uint256 sessionId, uint8 currency) external view returns (bool);
    function fundingShortfall(uint256 sessionId, uint8 currency) external view returns (uint256);
    function claimedOf(uint256 sessionId, address party, uint8 currency) external view returns (bool);

    // Fees and metrics
    function feeBps() external view returns (uint16);
    function sessionFeeBps(uint256 sessionId) external view returns (uint16);
    function accruedFees(uint8 currency) external view returns (uint256);
    function grossPosted(uint256 sessionId, uint8 currency) external view returns (uint256);
    function eliminated(uint256 sessionId, uint8 currency) external view returns (uint256);
    function counterpartyPairs(uint256 sessionId) external view returns (uint256);
    function feeOn(uint256 sessionId, uint256 amount) external view returns (uint256);
}
