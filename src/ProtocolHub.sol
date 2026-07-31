// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ProtocolHub — shared allowlist, MRW calendar, and pause for all currency buckets
contract ProtocolHub is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    bytes32 public constant HUB_ADMIN_ROLE = keccak256("HUB_ADMIN_ROLE");

    uint256 public constant WITHDRAWAL_WINDOW_BLOCKS = 100;
    uint256 public constant DEFAULT_WINDOW_DURATION_BLOCKS = 200;

    /// @dev True after open until early close (stays true after auto-expiry until next open/close cycle)
    bool private _windowArmed;
    uint256 public windowNonce;
    /// @notice Inclusive end block for the current MRW (set on open)
    uint256 public windowEndBlock;
    /// @notice Duration applied on the next `openWindow` (default 200)
    uint256 public windowDurationBlocks;
    /// @notice Block when MRW was closed early; 0 if closed only by expiry (or never closed)
    uint256 public withdrawalWindowStart;

    mapping(address => bool) public allowlist;
    address[] private _allowlistedAccounts;
    /// @dev 1-based index into `_allowlistedAccounts`; 0 means not present
    mapping(address => uint256) private _allowlistIndex;

    event WindowOpened(uint256 indexed windowNonce, uint256 endBlock, uint256 durationBlocks);
    event WindowClosed(uint256 indexed windowNonce, uint256 withdrawalWindowStart);
    event WindowDurationUpdated(uint256 durationBlocks);
    event AllowlistUpdated(address indexed account, bool allowed);

    error ZeroAddress();
    error WindowAlreadyOpen();
    error WindowAlreadyClosed();
    error InvalidWindowDuration();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        windowDurationBlocks = DEFAULT_WINDOW_DURATION_BLOCKS;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(HUB_ADMIN_ROLE, admin);
        _setAllowlist(admin, true);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause() external onlyRole(HUB_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(HUB_ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // MRW calendar
    // -------------------------------------------------------------------------

    /// @notice Effective MRW status (false after early close or after `windowEndBlock`)
    function windowOpen() public view returns (bool) {
        return _windowArmed && block.number <= windowEndBlock;
    }

    function openWindow() external onlyRole(HUB_ADMIN_ROLE) {
        if (windowOpen()) revert WindowAlreadyOpen();
        if (windowDurationBlocks == 0) revert InvalidWindowDuration();

        _windowArmed = true;
        withdrawalWindowStart = 0; // cancel any active withdrawal window
        windowEndBlock = block.number + windowDurationBlocks;
        unchecked {
            ++windowNonce;
        }
        emit WindowOpened(windowNonce, windowEndBlock, windowDurationBlocks);
    }

    /// @notice Early close; also allowed path before auto-expiry. Starts reserve withdrawal window.
    function closeWindow() external onlyRole(HUB_ADMIN_ROLE) {
        if (!windowOpen()) revert WindowAlreadyClosed();
        _windowArmed = false;
        withdrawalWindowStart = block.number;
        emit WindowClosed(windowNonce, withdrawalWindowStart);
    }

    function setWindowDurationBlocks(uint256 durationBlocks) external onlyRole(HUB_ADMIN_ROLE) {
        if (durationBlocks == 0) revert InvalidWindowDuration();
        windowDurationBlocks = durationBlocks;
        emit WindowDurationUpdated(durationBlocks);
    }

    function withdrawalWindowActive() public view returns (bool) {
        if (windowOpen()) return false;

        uint256 start;
        if (withdrawalWindowStart != 0) {
            start = withdrawalWindowStart;
        } else if (_windowArmed && block.number > windowEndBlock) {
            start = windowEndBlock;
        } else {
            return false;
        }

        return block.number <= start + WITHDRAWAL_WINDOW_BLOCKS;
    }

    /// @notice Blocks remaining in the active MRW; 0 if closed/expired
    function windowBlocksRemaining() public view returns (uint256) {
        if (!windowOpen()) return 0;
        return windowEndBlock - block.number;
    }

    /// @notice Blocks remaining in the post-MRW reserve withdrawal window; 0 if inactive
    function withdrawalBlocksRemaining() public view returns (uint256) {
        if (!withdrawalWindowActive()) return 0;
        uint256 start = withdrawalWindowStart != 0 ? withdrawalWindowStart : windowEndBlock;
        return start + WITHDRAWAL_WINDOW_BLOCKS - block.number;
    }

    // -------------------------------------------------------------------------
    // Allowlist
    // -------------------------------------------------------------------------

    function setAllowlist(address account, bool allowed) external onlyRole(HUB_ADMIN_ROLE) {
        _setAllowlist(account, allowed);
    }

    function isAllowlisted(address account) external view returns (bool) {
        return allowlist[account];
    }

    function allowlistedAccounts() external view returns (address[] memory) {
        return _allowlistedAccounts;
    }

    function allowlistedCount() external view returns (uint256) {
        return _allowlistedAccounts.length;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _setAllowlist(address account, bool allowed) internal {
        if (account == address(0)) revert ZeroAddress();

        bool currently = allowlist[account];
        if (allowed == currently) {
            emit AllowlistUpdated(account, allowed);
            return;
        }

        allowlist[account] = allowed;
        if (allowed) {
            _allowlistedAccounts.push(account);
            _allowlistIndex[account] = _allowlistedAccounts.length; // 1-based
        } else {
            uint256 idx = _allowlistIndex[account] - 1;
            address last = _allowlistedAccounts[_allowlistedAccounts.length - 1];
            _allowlistedAccounts[idx] = last;
            _allowlistIndex[last] = idx + 1;
            _allowlistedAccounts.pop();
            delete _allowlistIndex[account];
        }

        emit AllowlistUpdated(account, allowed);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
