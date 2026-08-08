// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "./Currency.sol";
import {IProtocolHub} from "./interfaces/IProtocolHub.sol";
import {INettingSession} from "./interfaces/INettingSession.sol";

/// @title NettingSession — multilateral obligation book; settle nets via token escrow
/// @notice Does not mint/redeem through CurrencyBucket. Tokens are settlement inventory only.
contract NettingSession is Initializable, AccessControlUpgradeable, UUPSUpgradeable, INettingSession {
    using SafeERC20 for IERC20;

    bytes32 public constant SESSION_ADMIN_ROLE = keccak256("SESSION_ADMIN_ROLE");

    IProtocolHub public hub;
    mapping(uint8 => IERC20) public tokens;

    Phase public phase;
    uint256 public sessionId;

    Obligation[] private _obligations;
    address[] private _participants;
    mapping(address => bool) private _isParticipant;

    /// @dev After lock: net position (positive = creditor, negative = debtor)
    mapping(address => mapping(uint8 => int256)) private _net;
    mapping(address => mapping(uint8 => bool)) private _funded;
    mapping(address => mapping(uint8 => bool)) private _claimed;
    mapping(uint8 => uint256) private _totalCreditorNets;
    mapping(uint8 => uint256) private _totalDebtorNets;
    mapping(uint8 => uint256) private _escrowReceived;
    mapping(uint8 => uint256) private _escrowClaimed;

    event SessionOpened(uint256 indexed sessionId);
    event ObligationPosted(
        uint256 indexed sessionId, uint256 indexed index, address debtor, address creditor, uint8 currency, uint256 amount
    );
    event SessionLocked(uint256 indexed sessionId, uint256 obligationCount, uint256 participantCount);
    event Funded(uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount);
    event Claimed(uint256 indexed sessionId, address indexed party, uint8 currency, uint256 amount);
    event SessionSettled(uint256 indexed sessionId);
    event SessionCancelled(uint256 indexed sessionId);

    error ZeroAddress();
    error InvalidCurrency();
    error InvalidPhase();
    error ZeroAmount();
    error SelfDebt();
    error NotAllowlisted();
    error NotPoster();
    error HubPaused();
    error NothingToFund();
    error AlreadyFunded();
    error NothingToClaim();
    error AlreadyClaimed();
    error CurrencyNotFullyFunded();
    error EscrowNotEmpty();
    error TokenNotSet();

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

        hub = IProtocolHub(hub_);
        tokens[Currency.USD] = IERC20(usd_);
        tokens[Currency.CLP] = IERC20(clp_);
        tokens[Currency.ARS] = IERC20(ars_);
        phase = Phase.Idle;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SESSION_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Admin: session lifecycle
    // -------------------------------------------------------------------------

    function openSession() external onlyRole(SESSION_ADMIN_ROLE) {
        _requireNotPaused();
        if (phase != Phase.Idle && phase != Phase.Settled && phase != Phase.Cancelled) {
            revert InvalidPhase();
        }
        _clearSessionState();
        unchecked {
            ++sessionId;
        }
        phase = Phase.Open;
        emit SessionOpened(sessionId);
    }

    function lockSession() external onlyRole(SESSION_ADMIN_ROLE) {
        _requireNotPaused();
        if (phase != Phase.Open) revert InvalidPhase();
        if (_obligations.length == 0) revert ZeroAmount();

        _recomputeNets();
        phase = Phase.Locked;
        emit SessionLocked(sessionId, _obligations.length, _participants.length);
        _maybeMarkSettled();
    }

    /// @notice Cancel only from Open/Locked with zero escrow received
    function cancelSession() external onlyRole(SESSION_ADMIN_ROLE) {
        if (phase != Phase.Open && phase != Phase.Locked) revert InvalidPhase();
        if (_escrowReceived[Currency.CLP] != 0 || _escrowReceived[Currency.ARS] != 0 || _escrowReceived[Currency.USD] != 0)
        {
            revert EscrowNotEmpty();
        }
        phase = Phase.Cancelled;
        emit SessionCancelled(sessionId);
    }

    // -------------------------------------------------------------------------
    // Obligations
    // -------------------------------------------------------------------------

    /// @notice Poster must be the debtor or session admin. Both parties must be allowlisted.
    function postObligation(address debtor, address creditor, uint8 currency, uint256 amount) external {
        _requireNotPaused();
        if (phase != Phase.Open) revert InvalidPhase();
        if (debtor == address(0) || creditor == address(0)) revert ZeroAddress();
        if (debtor == creditor) revert SelfDebt();
        if (amount == 0) revert ZeroAmount();
        if (currency > Currency.USD) revert InvalidCurrency();
        if (address(tokens[currency]) == address(0)) revert TokenNotSet();
        if (!hub.isAllowlisted(debtor) || !hub.isAllowlisted(creditor)) revert NotAllowlisted();
        if (msg.sender != debtor && !hasRole(SESSION_ADMIN_ROLE, msg.sender)) revert NotPoster();

        _obligations.push(Obligation({debtor: debtor, creditor: creditor, currency: currency, amount: amount}));
        _ensureParticipant(debtor);
        _ensureParticipant(creditor);

        uint256 index = _obligations.length - 1;
        emit ObligationPosted(sessionId, index, debtor, creditor, currency, amount);
    }

    // -------------------------------------------------------------------------
    // Settlement: fund / claim
    // -------------------------------------------------------------------------

    function fund(uint8 currency) external {
        _requireNotPaused();
        if (phase != Phase.Locked) revert InvalidPhase();
        if (currency > Currency.USD) revert InvalidCurrency();

        int256 n = _net[msg.sender][currency];
        if (n >= 0) revert NothingToFund();
        if (_funded[msg.sender][currency]) revert AlreadyFunded();

        uint256 amount = uint256(-n);
        _funded[msg.sender][currency] = true;
        _escrowReceived[currency] += amount;
        tokens[currency].safeTransferFrom(msg.sender, address(this), amount);

        emit Funded(sessionId, msg.sender, currency, amount);
        _maybeMarkSettled();
    }

    function claim(uint8 currency) external {
        _requireNotPaused();
        if (phase != Phase.Locked) revert InvalidPhase();
        if (currency > Currency.USD) revert InvalidCurrency();
        if (!currencyFullyFunded(currency)) revert CurrencyNotFullyFunded();

        int256 n = _net[msg.sender][currency];
        if (n <= 0) revert NothingToClaim();
        if (_claimed[msg.sender][currency]) revert AlreadyClaimed();

        uint256 amount = uint256(n);
        _claimed[msg.sender][currency] = true;
        _escrowClaimed[currency] += amount;
        tokens[currency].safeTransfer(msg.sender, amount);

        emit Claimed(sessionId, msg.sender, currency, amount);
        _maybeMarkSettled();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function obligationCount() external view returns (uint256) {
        return _obligations.length;
    }

    function obligations(uint256 index) external view returns (Obligation memory) {
        return _obligations[index];
    }

    function getObligations() external view returns (Obligation[] memory) {
        return _obligations;
    }

    function participants() external view returns (address[] memory) {
        return _participants;
    }

    function netOf(address party, uint8 currency) external view returns (int256) {
        return _net[party][currency];
    }

    function fundedOf(address party, uint8 currency) external view returns (bool) {
        return _funded[party][currency];
    }

    function claimedOf(address party, uint8 currency) external view returns (bool) {
        return _claimed[party][currency];
    }

    function totalCreditorNets(uint8 currency) external view returns (uint256) {
        return _totalCreditorNets[currency];
    }

    function totalDebtorNets(uint8 currency) external view returns (uint256) {
        return _totalDebtorNets[currency];
    }

    function escrowBalance(uint8 currency) public view returns (uint256) {
        IERC20 token = tokens[currency];
        if (address(token) == address(0)) return 0;
        return token.balanceOf(address(this));
    }

    function currencyFullyFunded(uint8 currency) public view returns (bool) {
        uint256 need = _totalDebtorNets[currency];
        if (need == 0) return _totalCreditorNets[currency] == 0;
        return _escrowReceived[currency] >= need;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireNotPaused() internal view {
        if (hub.paused()) revert HubPaused();
    }

    function _ensureParticipant(address account) internal {
        if (!_isParticipant[account]) {
            _isParticipant[account] = true;
            _participants.push(account);
        }
    }

    function _clearSessionState() internal {
        delete _obligations;

        uint256 n = _participants.length;
        for (uint256 i = 0; i < n; ++i) {
            address p = _participants[i];
            _isParticipant[p] = false;
            for (uint8 c = 0; c <= Currency.USD; ++c) {
                delete _net[p][c];
                delete _funded[p][c];
                delete _claimed[p][c];
            }
        }
        delete _participants;

        for (uint8 c = 0; c <= Currency.USD; ++c) {
            delete _totalCreditorNets[c];
            delete _totalDebtorNets[c];
            delete _escrowReceived[c];
            delete _escrowClaimed[c];
        }
    }

    function _recomputeNets() internal {
        uint256 n = _obligations.length;
        for (uint256 i = 0; i < n; ++i) {
            Obligation storage o = _obligations[i];
            _net[o.debtor][o.currency] -= int256(o.amount);
            _net[o.creditor][o.currency] += int256(o.amount);
        }

        uint256 pCount = _participants.length;
        for (uint256 i = 0; i < pCount; ++i) {
            address p = _participants[i];
            for (uint8 c = 0; c <= Currency.USD; ++c) {
                int256 net = _net[p][c];
                if (net > 0) {
                    _totalCreditorNets[c] += uint256(net);
                } else if (net < 0) {
                    _totalDebtorNets[c] += uint256(-net);
                }
            }
        }
    }

    function _maybeMarkSettled() internal {
        if (phase != Phase.Locked) return;

        // Settled when every non-zero creditor claim is done (debtor-only currencies with 0 creditors are vacuously done)
        for (uint8 c = 0; c <= Currency.USD; ++c) {
            uint256 credit = _totalCreditorNets[c];
            if (credit == 0) continue;
            if (!currencyFullyFunded(c)) return;
            if (_escrowClaimed[c] < credit) return;
        }

        // Also require all debtor funding done when there are debts
        for (uint8 c = 0; c <= Currency.USD; ++c) {
            uint256 debt = _totalDebtorNets[c];
            if (debt == 0) continue;
            if (_escrowReceived[c] < debt) return;
        }

        phase = Phase.Settled;
        emit SessionSettled(sessionId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
