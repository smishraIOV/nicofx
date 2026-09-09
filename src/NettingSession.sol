// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency} from "./Currency.sol";
import {IProtocolHub} from "./interfaces/IProtocolHub.sol";
import {INettingSession} from "./interfaces/INettingSession.sol";

/// @title NettingSession — multilateral obligation book settled delivery-versus-payment
///
/// @notice Lifecycle: `Open` (post + acknowledge) -> `Frozen` (nets final, debtors deposit)
///         -> `Locked` (fully funded: discharged, claims open) -> `Settled`.
///         Escape hatches: `Cancelled` (admin, pre-lock) and `Failed` (deadline passed while short).
///
/// @dev Design notes, each tied to a finding from review R1 (reviews/R1-cb95b96.md):
///  - **DVP (R1-C1).** Obligations are discharged only on `Frozen -> Locked`, which requires every
///    currency to be fully funded. While `Frozen`, a depositor may withdraw at will, so there is no
///    window in which a creditor has given up a gross claim without the net being deliverable.
///    A funding deadline plus permissionless `declareFailure` guarantees deposits are always
///    recoverable; every refund and claim is a pull, so no path loops over participants.
///  - **Session-keyed state (R1-H4).** All per-session state is keyed by `sessionId` and never cleared,
///    so `openSession` is O(1) and past sessions stay queryable and claimable forever. Nets, gross,
///    totals and required amounts are maintained incrementally, so no entry point is O(book size).
///  - **Consent (R1-H2).** A row is folded into the nets only once both debtor and creditor have
///    acknowledged it. The poster's own acknowledgement is implied.
///  - **Fee (R1-H3, R1-M4).** `feeBps` is snapshotted at `openSession`, before any party consents, and the
///    *debtor* funds `|net| + fee` so creditors are paid their net at face value.
///  - **No Oracle dependency (R1-M8).** Netting is strictly per currency; a frozen session's outcome
///    cannot be changed by a rate post. See readme "Limitations".
contract NettingSession is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    INettingSession
{
    using SafeERC20 for IERC20;

    bytes32 public constant SESSION_ADMIN_ROLE = keccak256("SESSION_ADMIN_ROLE");

    bytes32 private constant ACK_TYPEHASH =
        keccak256("Acknowledgement(uint256 sessionId,uint256 index,bytes32 ref,address party,uint256 deadline)");

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant DEFAULT_FUNDING_WINDOW_BLOCKS = 200;
    /// @notice Per-obligation ceiling. Keeps the signed net arithmetic far from `int256` limits even
    ///         with an implausibly large book, so no net can be overflowed into the wrong sign.
    uint256 public constant MAX_OBLIGATION_AMOUNT = type(uint128).max;

    IProtocolHub public hub;
    mapping(uint8 => IERC20) public tokens;

    uint256 public sessionId;
    /// @notice Receipt fee applied to sessions opened from now on (snapshotted per session)
    uint16 public feeBps;
    /// @notice Blocks a `Frozen` session has to reach full funding before it can be failed
    uint256 public fundingWindowBlocks;
    /// @notice Destination for claims swept from parties removed from the allowlist (R1-M2)
    address public quarantineAddress;

    /// @dev Per-currency fee income, booked when a session locks. Persists across sessions.
    mapping(uint8 => uint256) private _accruedFees;

    /// @dev Optional per-party absolute net cap, in token units. 0 = unlimited. (R1-M7)
    mapping(address => mapping(uint8 => uint256)) public maxNet;

    // ----- per-session state, keyed by sessionId and never cleared (R1-H4) ----------------------
    mapping(uint256 => Phase) private _phase;
    mapping(uint256 => uint16) private _sessionFeeBps;
    mapping(uint256 => uint256) private _fundingDeadline;
    mapping(uint256 => Obligation[]) private _obligations;
    mapping(uint256 => uint256) private _includedCount;
    mapping(uint256 => uint256) private _voidedCount;
    mapping(uint256 => address[]) private _participants;
    mapping(uint256 => mapping(address => bool)) private _isParticipant;
    mapping(uint256 => mapping(address => mapping(uint8 => int256))) private _net;
    /// @dev Sum of |net| over parties with net < 0. Equals the sum of positive nets by construction.
    mapping(uint256 => mapping(uint8 => uint256)) private _totalNets;
    /// @dev Sum over debtors of (|net| + fee(|net|)) — what escrow must receive to lock
    mapping(uint256 => mapping(uint8 => uint256)) private _totalRequired;
    mapping(uint256 => mapping(uint8 => uint256)) private _grossPosted;
    /// @dev Deposits received, net of withdrawals
    mapping(uint256 => mapping(uint8 => uint256)) private _escrowReceived;
    mapping(uint256 => mapping(uint8 => uint256)) private _escrowClaimed;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) private _deposited;
    mapping(uint256 => mapping(address => mapping(uint8 => bool))) private _claimed;
    mapping(uint256 => uint256) private _pairCount;
    mapping(uint256 => mapping(bytes32 => bool)) private _pairSeen;

    /// @dev Where an external reference was last posted, for duplicate and replay guards (R1-H1)
    struct RefRecord {
        uint256 sessionId;
        uint256 index;
    }

    mapping(bytes32 => RefRecord) private _refRecord;

    event SessionOpened(uint256 indexed sessionId, uint16 feeBps, uint256 fundingWindowBlocks);
    event ObligationPosted(
        uint256 indexed sessionId,
        uint256 indexed index,
        address indexed poster,
        address debtor,
        address creditor,
        uint8 currency,
        uint256 amount,
        bytes32 ref
    );
    event ObligationAcknowledged(uint256 indexed sessionId, uint256 indexed index, address indexed party);
    event ObligationIncluded(uint256 indexed sessionId, uint256 indexed index);
    event ObligationVoided(uint256 indexed sessionId, uint256 indexed index, address indexed by);
    event NetComputed(uint256 indexed sessionId, address indexed party, uint8 indexed currency, int256 net);
    event SessionFrozen(
        uint256 indexed sessionId, uint256 fundingDeadline, uint256 includedCount, uint256 participantCount
    );
    event SessionVolume(
        uint256 indexed sessionId,
        uint8 indexed currency,
        uint256 gross,
        uint256 residual,
        uint256 eliminated,
        uint256 participantCount,
        uint256 counterpartyPairs
    );
    event Deposited(uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount, uint256 total);
    event DepositWithdrawn(uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount);
    event SessionLocked(uint256 indexed sessionId, uint256 blockNumber);
    event Claimed(uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount);
    event SessionSettled(uint256 indexed sessionId);
    event SessionCancelled(uint256 indexed sessionId, address indexed by);
    event SessionFailed(uint256 indexed sessionId, address indexed by, uint256 blockNumber);
    event QuarantineSwept(
        uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount, address to
    );
    event FeeBpsUpdated(uint16 feeBps);
    event FundingWindowUpdated(uint256 blocks);
    event MaxNetUpdated(address indexed party, uint8 currency, uint256 max);
    event QuarantineAddressUpdated(address indexed quarantineAddress);
    event FeesWithdrawn(address indexed to, uint8 currency, uint256 amount);

    error ZeroAddress();
    error InvalidCurrency();
    error InvalidPhase();
    error ZeroAmount();
    error AmountTooLarge();
    error SelfDebt();
    error NotAllowlisted();
    error NotPoster();
    error NotParty();
    error HubPaused();
    error TokenNotSet();
    error FeeTooHigh();
    error InsufficientFees();
    error ZeroRef();
    error DuplicateRef();
    error RefAlreadySettled();
    error AlreadyAcknowledged();
    error AlreadyIncluded();
    error ObligationInactive();
    error NothingToDeposit();
    error DepositExceedsRequirement(uint256 outstanding);
    error NothingToWithdraw();
    error NothingToClaim();
    error AlreadyClaimed();
    error NoIncludedObligations();
    error DeadlineNotReached();
    error AlreadyFullyFunded();
    error NetLimitExceeded(address party, uint8 currency, int256 net, uint256 max);
    error InvalidWindow();
    error SignatureExpired();
    error InvalidSignature();
    error StillAllowlisted();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address hub_, address usd_, address clp_, address ars_) external initializer {
        if (
            admin == address(0) || hub_ == address(0) || usd_ == address(0) || clp_ == address(0) || ars_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __EIP712_init("NicoFX NettingSession", "1");

        hub = IProtocolHub(hub_);
        tokens[Currency.USD] = IERC20(usd_);
        tokens[Currency.CLP] = IERC20(clp_);
        tokens[Currency.ARS] = IERC20(ars_);
        fundingWindowBlocks = DEFAULT_FUNDING_WINDOW_BLOCKS;
        quarantineAddress = admin;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SESSION_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Admin configuration
    // -------------------------------------------------------------------------

    /// @notice Takes effect on the next `openSession`; a live session keeps the fee it was opened with (R1-H3)
    function setFeeBps(uint16 feeBps_) external onlyRole(SESSION_ADMIN_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    function setFundingWindowBlocks(uint256 blocks_) external onlyRole(SESSION_ADMIN_ROLE) {
        if (blocks_ == 0) revert InvalidWindow();
        fundingWindowBlocks = blocks_;
        emit FundingWindowUpdated(blocks_);
    }

    /// @notice Cap a party's absolute net per currency. 0 = unlimited. Enforced when a row is included (R1-M7).
    function setMaxNet(address party, uint8 currency, uint256 max) external onlyRole(SESSION_ADMIN_ROLE) {
        if (party == address(0)) revert ZeroAddress();
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        maxNet[party][currency] = max;
        emit MaxNetUpdated(party, currency, max);
    }

    function setQuarantineAddress(address quarantineAddress_) external onlyRole(SESSION_ADMIN_ROLE) {
        if (quarantineAddress_ == address(0)) revert ZeroAddress();
        quarantineAddress = quarantineAddress_;
        emit QuarantineAddressUpdated(quarantineAddress_);
    }

    function withdrawFees(uint8 currency, uint256 amount) external onlyRole(SESSION_ADMIN_ROLE) {
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        if (amount == 0) revert ZeroAmount();
        if (amount > _accruedFees[currency]) revert InsufficientFees();
        unchecked {
            _accruedFees[currency] -= amount;
        }
        tokens[currency].safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(msg.sender, currency, amount);
    }

    // -------------------------------------------------------------------------
    // Session lifecycle
    // -------------------------------------------------------------------------

    function openSession() external onlyRole(SESSION_ADMIN_ROLE) {
        _requireNotPaused();
        // Only a live book blocks the next cycle. A `Locked` session is already discharged and its
        // unclaimed receipts survive in session-keyed state, so the operator is not held up by a
        // slow claimant.
        Phase current = _phase[sessionId];
        if (current == Phase.Open || current == Phase.Frozen) revert InvalidPhase();

        uint256 sid;
        unchecked {
            sid = sessionId + 1;
        }
        sessionId = sid;
        _phase[sid] = Phase.Open;
        // Snapshot the fee before any party can consent, so it cannot be re-priced under them (R1-H3)
        _sessionFeeBps[sid] = feeBps;

        emit SessionOpened(sid, feeBps, fundingWindowBlocks);
    }

    /// @notice Freeze the book: nets become final and debtors may deposit. Nothing is discharged yet.
    function freezeSession() external onlyRole(SESSION_ADMIN_ROLE) {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Open) revert InvalidPhase();
        if (_includedCount[sid] == 0) revert NoIncludedObligations();

        uint256 deadline = block.number + fundingWindowBlocks;
        _fundingDeadline[sid] = deadline;
        _phase[sid] = Phase.Frozen;

        emit SessionFrozen(sid, deadline, _includedCount[sid], _participants[sid].length);
        _emitSessionVolume(sid);
        // A book with no debtors (a perfect cycle) is already fully funded and locks immediately
        _maybeLock(sid);
    }

    /// @notice Abandon a session before it locks. Deposits stay withdrawable by their depositors.
    /// @dev Allowed while paused: this is an escape hatch, and pausing must not trap deposits.
    function cancelSession() external onlyRole(SESSION_ADMIN_ROLE) {
        uint256 sid = sessionId;
        Phase current = _phase[sid];
        if (current != Phase.Open && current != Phase.Frozen) revert InvalidPhase();
        _phase[sid] = Phase.Cancelled;
        emit SessionCancelled(sid, msg.sender);
    }

    /// @notice Declare settlement failure once the funding deadline passes while a currency is short.
    /// @dev Permissionless by design (R1-C1): recovering deposits must not depend on the admin, and it
    ///      works while paused for the same reason. Session admin may declare early.
    function declareFailure(uint256 sid) external {
        if (_phase[sid] != Phase.Frozen) revert InvalidPhase();
        if (!hasRole(SESSION_ADMIN_ROLE, msg.sender)) {
            if (block.number <= _fundingDeadline[sid]) revert DeadlineNotReached();
        }
        if (_isFullyFunded(sid)) revert AlreadyFullyFunded();

        _phase[sid] = Phase.Failed;
        emit SessionFailed(sid, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // Obligation book
    // -------------------------------------------------------------------------

    /// @notice Assert an obligation. Poster may be the debtor, the creditor, or the session admin;
    ///         the poster's own acknowledgement is implied. A row nets only once both parties consent (R1-H2).
    function postObligation(address debtor, address creditor, uint8 currency, uint256 amount, bytes32 ref)
        external
        returns (uint256 index)
    {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Open) revert InvalidPhase();
        if (debtor == address(0) || creditor == address(0)) revert ZeroAddress();
        if (debtor == creditor) revert SelfDebt();
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_OBLIGATION_AMOUNT) revert AmountTooLarge();
        if (ref == bytes32(0)) revert ZeroRef();
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        if (address(tokens[currency]) == address(0)) revert TokenNotSet();
        if (!hub.isAllowlisted(debtor) || !hub.isAllowlisted(creditor)) revert NotAllowlisted();

        bool isDebtor = msg.sender == debtor;
        bool isCreditor = msg.sender == creditor;
        if (!isDebtor && !isCreditor && !hasRole(SESSION_ADMIN_ROLE, msg.sender)) revert NotPoster();

        _guardRef(sid, ref);

        index = _obligations[sid].length;
        _obligations[sid].push(
            Obligation({
                debtor: debtor,
                creditor: creditor,
                currency: currency,
                amount: amount,
                ref: ref,
                debtorAck: isDebtor,
                creditorAck: isCreditor,
                included: false,
                voided: false
            })
        );
        _refRecord[ref] = RefRecord({sessionId: sid, index: index});

        _ensureParticipant(sid, debtor);
        _ensureParticipant(sid, creditor);
        _countPair(sid, debtor, creditor);

        emit ObligationPosted(sid, index, msg.sender, debtor, creditor, currency, amount, ref);
        if (isDebtor || isCreditor) emit ObligationAcknowledged(sid, index, msg.sender);

        // Admin-posted rows need both parties; a party-posted row needs only its counterparty
        _maybeInclude(sid, index);
    }

    /// @notice Acknowledge rows you are a party to. Batched so a counterparty confirms a book in one tx.
    function acknowledge(uint256[] calldata indices) external {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Open) revert InvalidPhase();

        uint256 n = indices.length;
        for (uint256 i = 0; i < n; ++i) {
            _acknowledge(sid, indices[i], msg.sender);
        }
    }

    /// @notice Relay an off-chain acknowledgement. Supports EIP-1271 signers (enterprise multisigs).
    function acknowledgeWithSig(uint256 index, address party, uint256 deadline, bytes calldata signature) external {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Open) revert InvalidPhase();
        if (block.timestamp > deadline) revert SignatureExpired();

        Obligation storage o = _obligations[sid][index];
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(ACK_TYPEHASH, sid, index, o.ref, party, deadline)));
        if (!SignatureChecker.isValidSignatureNow(party, digest, signature)) revert InvalidSignature();

        _acknowledge(sid, index, party);
    }

    /// @notice Remove a row before the book is frozen. Poster-side parties and the admin may void.
    /// @dev Reverses the row's effect on the nets if it had already been included, and frees its ref
    ///      so a corrected row can be re-posted under the same invoice id.
    function voidObligation(uint256 index) external {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Open) revert InvalidPhase();

        Obligation storage o = _obligations[sid][index];
        if (o.voided) revert ObligationInactive();
        if (
            msg.sender != o.debtor && msg.sender != o.creditor && !hasRole(SESSION_ADMIN_ROLE, msg.sender)
        ) revert NotParty();

        if (o.included) {
            o.included = false;
            unchecked {
                --_includedCount[sid];
            }
            _grossPosted[sid][o.currency] -= o.amount;
            _applyNet(sid, o.debtor, o.currency, int256(o.amount));
            _applyNet(sid, o.creditor, o.currency, -int256(o.amount));
        }
        o.voided = true;
        unchecked {
            ++_voidedCount[sid];
        }
        delete _refRecord[o.ref];

        emit ObligationVoided(sid, index, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Settlement: deposit / claim / refund
    // -------------------------------------------------------------------------

    /// @notice Deposit toward your funding requirement. Partial deposits allowed (R1-C1).
    /// @dev No allowlist re-check: a party must always be able to meet an obligation it owes (R1-M2).
    function deposit(uint8 currency, uint256 amount) external {
        _requireNotPaused();
        uint256 sid = sessionId;
        if (_phase[sid] != Phase.Frozen) revert InvalidPhase();
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        if (amount == 0) revert ZeroAmount();

        uint256 outstanding = outstandingDeposit(sid, msg.sender, currency);
        if (outstanding == 0) revert NothingToDeposit();
        if (amount > outstanding) revert DepositExceedsRequirement(outstanding);

        uint256 total = _deposited[sid][msg.sender][currency] + amount;
        _deposited[sid][msg.sender][currency] = total;
        _escrowReceived[sid][currency] += amount;

        tokens[currency].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(sid, msg.sender, currency, amount, total);
        // Reaching full funding discharges the obligations in this same transaction, so there is no
        // window where funding is complete but deposits are still withdrawable.
        _maybeLock(sid);
    }

    /// @notice Reclaim a deposit. Free while `Frozen` (nothing is discharged yet), and the recovery
    ///         path once a session is `Cancelled` or `Failed`. Works while paused (R1-C1).
    function withdrawDeposit(uint256 sid, uint8 currency) external {
        Phase current = _phase[sid];
        if (current != Phase.Frozen && current != Phase.Cancelled && current != Phase.Failed) revert InvalidPhase();
        if (!Currency.isValid(currency)) revert InvalidCurrency();

        uint256 amount = _deposited[sid][msg.sender][currency];
        if (amount == 0) revert NothingToWithdraw();

        _deposited[sid][msg.sender][currency] = 0;
        _escrowReceived[sid][currency] -= amount;

        tokens[currency].safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(sid, msg.sender, currency, amount);
    }

    /// @notice Claim your net receipt at face value once the session is locked (R1-M4).
    /// @dev Requires current allowlist standing (R1-M2). A de-listed party keeps its entitlement and can
    ///      claim after being re-listed; the admin may sweep it to quarantine instead.
    function claim(uint256 sid, uint8 currency) external {
        _requireNotPaused();
        Phase current = _phase[sid];
        if (current != Phase.Locked && current != Phase.Settled) revert InvalidPhase();
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        if (!hub.isAllowlisted(msg.sender)) revert NotAllowlisted();

        int256 n = _net[sid][msg.sender][currency];
        if (n <= 0) revert NothingToClaim();
        if (_claimed[sid][msg.sender][currency]) revert AlreadyClaimed();

        uint256 amount = uint256(n);
        _claimed[sid][msg.sender][currency] = true;
        _escrowClaimed[sid][currency] += amount;

        tokens[currency].safeTransfer(msg.sender, amount);

        emit Claimed(sid, msg.sender, currency, amount);
        _maybeSettle(sid);
    }

    /// @notice Move a de-listed party's claim to the quarantine address (R1-M2).
    function sweepQuarantined(uint256 sid, address party, uint8 currency) external onlyRole(SESSION_ADMIN_ROLE) {
        Phase current = _phase[sid];
        if (current != Phase.Locked && current != Phase.Settled) revert InvalidPhase();
        if (!Currency.isValid(currency)) revert InvalidCurrency();
        if (hub.isAllowlisted(party)) revert StillAllowlisted();

        int256 n = _net[sid][party][currency];
        if (n <= 0) revert NothingToClaim();
        if (_claimed[sid][party][currency]) revert AlreadyClaimed();

        uint256 amount = uint256(n);
        address to = quarantineAddress;
        _claimed[sid][party][currency] = true;
        _escrowClaimed[sid][currency] += amount;

        tokens[currency].safeTransfer(to, amount);

        emit QuarantineSwept(sid, party, currency, amount, to);
        _maybeSettle(sid);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function phase() external view returns (Phase) {
        return _phase[sessionId];
    }

    function phaseOf(uint256 sid) external view returns (Phase) {
        return _phase[sid];
    }

    function fundingDeadline(uint256 sid) external view returns (uint256) {
        return _fundingDeadline[sid];
    }

    function sessionFeeBps(uint256 sid) external view returns (uint16) {
        return _sessionFeeBps[sid];
    }

    function accruedFees(uint8 currency) external view returns (uint256) {
        return _accruedFees[currency];
    }

    function obligationCount(uint256 sid) external view returns (uint256) {
        return _obligations[sid].length;
    }

    function obligations(uint256 sid, uint256 index) external view returns (Obligation memory) {
        return _obligations[sid][index];
    }

    function getObligations(uint256 sid) external view returns (Obligation[] memory) {
        return _obligations[sid];
    }

    function includedCount(uint256 sid) external view returns (uint256) {
        return _includedCount[sid];
    }

    function pendingAckCount(uint256 sid) external view returns (uint256) {
        return _obligations[sid].length - _includedCount[sid] - _voidedCount[sid];
    }

    function participants(uint256 sid) external view returns (address[] memory) {
        return _participants[sid];
    }

    function participantCount(uint256 sid) external view returns (uint256) {
        return _participants[sid].length;
    }

    function netOf(uint256 sid, address party, uint8 currency) external view returns (int256) {
        return _net[sid][party][currency];
    }

    /// @dev Equal to `totalDebtorNets` by construction: every obligation adds `-a` and `+a`, so the
    ///      per-currency nets sum to zero and the positive and negative sides are the same magnitude.
    function totalCreditorNets(uint256 sid, uint8 currency) external view returns (uint256) {
        return _totalNets[sid][currency];
    }

    function totalDebtorNets(uint256 sid, uint8 currency) external view returns (uint256) {
        return _totalNets[sid][currency];
    }

    function totalRequired(uint256 sid, uint8 currency) external view returns (uint256) {
        return _totalRequired[sid][currency];
    }

    /// @notice What a debtor must deposit: its net plus the receipt fee the creditors are spared (R1-M4)
    function requiredDeposit(uint256 sid, address party, uint8 currency) public view returns (uint256) {
        int256 n = _net[sid][party][currency];
        if (n >= 0) return 0;
        uint256 owed = uint256(-n);
        return owed + Math.mulDiv(owed, _sessionFeeBps[sid], BPS);
    }

    function depositedOf(uint256 sid, address party, uint8 currency) external view returns (uint256) {
        return _deposited[sid][party][currency];
    }

    function outstandingDeposit(uint256 sid, address party, uint8 currency) public view returns (uint256) {
        uint256 required = requiredDeposit(sid, party, currency);
        uint256 paid = _deposited[sid][party][currency];
        return required > paid ? required - paid : 0;
    }

    /// @notice Tokens still owed to this session's creditors. Excludes fee income booked at lock and
    ///         any stray transfers into the contract (R1-M5).
    function escrowBalance(uint256 sid, uint8 currency) public view returns (uint256) {
        uint256 held = _escrowReceived[sid][currency] - _escrowClaimed[sid][currency];
        Phase current = _phase[sid];
        if (current == Phase.Locked || current == Phase.Settled) {
            uint256 booked = _totalRequired[sid][currency] - _totalNets[sid][currency];
            return held > booked ? held - booked : 0;
        }
        return held;
    }

    /// @notice Raw contract token balance, for reconciliation. Includes fee income and strays (R1-M5).
    function tokenBalance(uint8 currency) external view returns (uint256) {
        IERC20 token = tokens[currency];
        if (address(token) == address(0)) return 0;
        return token.balanceOf(address(this));
    }

    function currencyFullyFunded(uint256 sid, uint8 currency) public view returns (bool) {
        return _escrowReceived[sid][currency] >= _totalRequired[sid][currency];
    }

    function fundingShortfall(uint256 sid, uint8 currency) public view returns (uint256) {
        uint256 required = _totalRequired[sid][currency];
        uint256 received = _escrowReceived[sid][currency];
        return required > received ? required - received : 0;
    }

    function claimedOf(uint256 sid, address party, uint8 currency) external view returns (bool) {
        return _claimed[sid][party][currency];
    }

    /// @notice Gross of *consented* obligations only — unacknowledged rows never count (R1-H1)
    function grossPosted(uint256 sid, uint8 currency) external view returns (uint256) {
        return _grossPosted[sid][currency];
    }

    /// @notice Payment volume removed by netting. Meaningful once the book is frozen.
    /// @dev Read alongside `participantCount` and `counterpartyPairs`: this is an operator-attested
    ///      service metric, not a trustless one, since consenting parties can post offsetting rows (R1-H1).
    function eliminated(uint256 sid, uint8 currency) external view returns (uint256) {
        Phase current = _phase[sid];
        if (current == Phase.Idle || current == Phase.Open) return 0;
        uint256 gross = _grossPosted[sid][currency];
        uint256 residual = _totalNets[sid][currency];
        return gross > residual ? gross - residual : 0;
    }

    /// @notice Distinct ordered debtor/creditor pairs in the book, so a two-address wash is visible (R1-H1)
    function counterpartyPairs(uint256 sid) external view returns (uint256) {
        return _pairCount[sid];
    }

    function feeOn(uint256 sid, uint256 amount) external view returns (uint256) {
        return Math.mulDiv(amount, _sessionFeeBps[sid], BPS);
    }

    function isFullyFunded(uint256 sid) external view returns (bool) {
        return _isFullyFunded(sid);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireNotPaused() internal view {
        if (hub.paused()) revert HubPaused();
    }

    function _guardRef(uint256 sid, bytes32 ref) internal view {
        RefRecord memory record = _refRecord[ref];
        if (record.sessionId == 0) return;
        if (record.sessionId == sid) revert DuplicateRef();

        Obligation storage prior = _obligations[record.sessionId][record.index];
        Phase priorPhase = _phase[record.sessionId];
        // Discharged only if the row actually netted in a session that locked
        if (prior.included && (priorPhase == Phase.Locked || priorPhase == Phase.Settled)) {
            revert RefAlreadySettled();
        }
    }

    function _ensureParticipant(uint256 sid, address account) internal {
        if (!_isParticipant[sid][account]) {
            _isParticipant[sid][account] = true;
            _participants[sid].push(account);
        }
    }

    function _countPair(uint256 sid, address debtor, address creditor) internal {
        bytes32 key = keccak256(abi.encodePacked(debtor, creditor));
        if (!_pairSeen[sid][key]) {
            _pairSeen[sid][key] = true;
            unchecked {
                ++_pairCount[sid];
            }
        }
    }

    function _acknowledge(uint256 sid, uint256 index, address party) internal {
        Obligation storage o = _obligations[sid][index];
        if (o.voided) revert ObligationInactive();

        if (party == o.debtor) {
            if (o.debtorAck) revert AlreadyAcknowledged();
            o.debtorAck = true;
        } else if (party == o.creditor) {
            if (o.creditorAck) revert AlreadyAcknowledged();
            o.creditorAck = true;
        } else {
            revert NotParty();
        }

        emit ObligationAcknowledged(sid, index, party);
        _maybeInclude(sid, index);
    }

    /// @dev Folds a fully consented row into the running nets. Incremental, so no entry point ever
    ///      loops over the book (R1-H4).
    function _maybeInclude(uint256 sid, uint256 index) internal {
        Obligation storage o = _obligations[sid][index];
        if (o.included || o.voided) return;
        if (!o.debtorAck || !o.creditorAck) return;

        o.included = true;
        unchecked {
            ++_includedCount[sid];
        }
        _grossPosted[sid][o.currency] += o.amount;
        _applyNet(sid, o.debtor, o.currency, -int256(o.amount));
        _applyNet(sid, o.creditor, o.currency, int256(o.amount));

        emit ObligationIncluded(sid, index);
    }

    /// @dev Single point of net mutation. Keeps `_totalNets` and `_totalRequired` in step, enforces the
    ///      per-party net cap, and emits the audit trail (R1-M3, R1-M7).
    function _applyNet(uint256 sid, address party, uint8 currency, int256 delta) internal {
        int256 old = _net[sid][party][currency];
        int256 updated = old + delta;

        uint256 nets = _totalNets[sid][currency];
        uint256 required = _totalRequired[sid][currency];
        uint16 fee = _sessionFeeBps[sid];

        if (old < 0) {
            uint256 owed = uint256(-old);
            nets -= owed;
            required -= owed + Math.mulDiv(owed, fee, BPS);
        }
        if (updated < 0) {
            uint256 owed = uint256(-updated);
            nets += owed;
            required += owed + Math.mulDiv(owed, fee, BPS);
        }

        _net[sid][party][currency] = updated;
        _totalNets[sid][currency] = nets;
        _totalRequired[sid][currency] = required;

        uint256 cap = maxNet[party][currency];
        if (cap != 0) {
            uint256 magnitude = updated < 0 ? uint256(-updated) : uint256(updated);
            if (magnitude > cap) revert NetLimitExceeded(party, currency, updated, cap);
        }

        emit NetComputed(sid, party, currency, updated);
    }

    function _isFullyFunded(uint256 sid) internal view returns (bool) {
        for (uint8 c = 0; c < Currency.COUNT; ++c) {
            if (!currencyFullyFunded(sid, c)) return false;
        }
        return true;
    }

    /// @dev The DVP moment: full funding discharges the obligations and opens claims (R1-C1).
    function _maybeLock(uint256 sid) internal {
        if (_phase[sid] != Phase.Frozen) return;
        if (!_isFullyFunded(sid)) return;

        _phase[sid] = Phase.Locked;
        // Book the fee only now. A session that never locks accrues nothing, so refunds are whole.
        for (uint8 c = 0; c < Currency.COUNT; ++c) {
            uint256 fee = _totalRequired[sid][c] - _totalNets[sid][c];
            if (fee != 0) _accruedFees[c] += fee;
        }

        emit SessionLocked(sid, block.number);
        _maybeSettle(sid);
    }

    function _maybeSettle(uint256 sid) internal {
        if (_phase[sid] != Phase.Locked) return;
        for (uint8 c = 0; c < Currency.COUNT; ++c) {
            if (_escrowClaimed[sid][c] < _totalNets[sid][c]) return;
        }
        _phase[sid] = Phase.Settled;
        emit SessionSettled(sid);
    }

    function _emitSessionVolume(uint256 sid) internal {
        uint256 pCount = _participants[sid].length;
        uint256 pairs = _pairCount[sid];
        for (uint8 c = 0; c < Currency.COUNT; ++c) {
            uint256 gross = _grossPosted[sid][c];
            uint256 residual = _totalNets[sid][c];
            uint256 elim = gross > residual ? gross - residual : 0;
            emit SessionVolume(sid, c, gross, residual, elim, pCount, pairs);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
