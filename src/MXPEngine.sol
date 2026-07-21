// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MXP} from "./MXP.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @title MXPEngine — vault, MRW, allowlist, mint/redeem, reserves, fees
contract MXPEngine is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant MXP_ADMIN_ROLE = keccak256("MXP_ADMIN_ROLE");

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant REQUIRED_RATIO_BPS = 11_000; // 110%
    uint256 public constant BUFFER_BPS = 1_000; // 10%
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant WITHDRAWAL_WINDOW_BLOCKS = 100;
    uint256 public constant DEFAULT_WINDOW_DURATION_BLOCKS = 200;

    IERC20 public usd;
    MXP public mxp;
    IOracle public oracle;

    /// @dev True after open until early close (stays true after auto-expiry until next open/close cycle)
    bool private _windowArmed;
    uint256 public windowNonce;
    /// @notice Inclusive end block for the current MRW (set on open)
    uint256 public windowEndBlock;
    /// @notice Duration applied on the next `openWindow` (default 200)
    uint256 public windowDurationBlocks;
    /// @notice Block when MRW was closed early; 0 if closed only by expiry (or never closed)
    uint256 public withdrawalWindowStart;

    uint16 public feeBps;
    uint256 public accruedFees;

    mapping(address => bool) public allowlist;

    event WindowOpened(uint256 indexed windowNonce, uint256 endBlock, uint256 durationBlocks);
    event WindowClosed(uint256 indexed windowNonce, uint256 withdrawalWindowStart);
    event WindowDurationUpdated(uint256 durationBlocks);
    event AllowlistUpdated(address indexed account, bool allowed);
    event FeeBpsUpdated(uint16 feeBps);
    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Minted(address indexed user, uint256 usdIn, uint256 mxpOut);
    event Redeemed(address indexed user, uint256 mxpBurned, uint256 usdPaid, uint256 feeUsd, bool partialRedeem);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error NotAllowlisted();
    error WindowAlreadyOpen();
    error WindowAlreadyClosed();
    error WindowNotOpen();
    error WithdrawalWindowInactive();
    error InsufficientHeadroom();
    error InsufficientCollateral();
    error InsufficientFees();
    error RateInvalid();
    error InsufficientFeeBalance();
    error InvalidWindowDuration();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address usd_, address mxp_, address oracle_) external initializer {
        if (admin == address(0) || usd_ == address(0) || mxp_ == address(0) || oracle_ == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        usd = IERC20(usd_);
        mxp = MXP(mxp_);
        oracle = IOracle(oracle_);
        windowDurationBlocks = DEFAULT_WINDOW_DURATION_BLOCKS;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MXP_ADMIN_ROLE, admin);
        _setAllowlist(admin, true);
    }

    // -------------------------------------------------------------------------
    // Admin: pause, window, allowlist, fee
    // -------------------------------------------------------------------------

    function pause() external onlyRole(MXP_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(MXP_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Effective MRW status (false after early close or after `windowEndBlock`)
    function windowOpen() public view returns (bool) {
        return _windowArmed && block.number <= windowEndBlock;
    }

    function openWindow() external onlyRole(MXP_ADMIN_ROLE) {
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
    function closeWindow() external onlyRole(MXP_ADMIN_ROLE) {
        if (!windowOpen()) revert WindowAlreadyClosed();
        _windowArmed = false;
        withdrawalWindowStart = block.number;
        emit WindowClosed(windowNonce, withdrawalWindowStart);
    }

    function setWindowDurationBlocks(uint256 durationBlocks) external onlyRole(MXP_ADMIN_ROLE) {
        if (durationBlocks == 0) revert InvalidWindowDuration();
        windowDurationBlocks = durationBlocks;
        emit WindowDurationUpdated(durationBlocks);
    }

    function setAllowlist(address account, bool allowed) external onlyRole(MXP_ADMIN_ROLE) {
        _setAllowlist(account, allowed);
    }

    function setFeeBps(uint16 feeBps_) external onlyRole(MXP_ADMIN_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    // -------------------------------------------------------------------------
    // Reserves & fees
    // -------------------------------------------------------------------------

    function depositReserve(uint256 usdAmount) external onlyRole(MXP_ADMIN_ROLE) {
        if (usdAmount == 0) revert ZeroAmount();
        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        emit ReserveDeposited(msg.sender, usdAmount);
    }

    function withdrawReserve(uint256 usdAmount) external onlyRole(MXP_ADMIN_ROLE) whenNotPaused {
        if (usdAmount == 0) revert ZeroAmount();
        if (!withdrawalWindowActive()) revert WithdrawalWindowInactive();

        uint256 collateral = collateralUsd();
        if (usdAmount > collateral) revert InsufficientCollateral();
        uint256 collateralAfter = collateral - usdAmount;
        uint256 minCollateral = Math.mulDiv(liabilityUsd(), REQUIRED_RATIO_BPS, BPS);
        if (collateralAfter < minCollateral) revert InsufficientCollateral();

        usd.safeTransfer(msg.sender, usdAmount);
        emit ReserveWithdrawn(msg.sender, usdAmount);
    }

    function withdrawFees(uint256 amount) external onlyRole(MXP_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (amount > accruedFees) revert InsufficientFees();
        unchecked {
            accruedFees -= amount;
        }
        usd.safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Mint / redeem
    // -------------------------------------------------------------------------

    function mint(uint256 usdAmount) external whenNotPaused {
        if (usdAmount == 0) revert ZeroAmount();
        if (!windowOpen()) revert WindowNotOpen();
        if (!allowlist[msg.sender]) revert NotAllowlisted();
        _requireValidRateForCurrentWindow();
        if (usdAmount > mintHeadroomUsd()) revert InsufficientHeadroom();

        uint256 rate = oracle.mxpPerUsd();
        uint256 mxpOut = Math.mulDiv(usdAmount, rate, WAD);
        if (mxpOut == 0) revert ZeroAmount();

        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        mxp.mint(msg.sender, mxpOut);

        emit Minted(msg.sender, usdAmount, mxpOut);
    }

    function redeem(uint256 mxpAmount) external whenNotPaused {
        if (mxpAmount == 0) revert ZeroAmount();
        if (!windowOpen()) revert WindowNotOpen();
        if (!allowlist[msg.sender]) revert NotAllowlisted();
        _requireValidRateForCurrentWindow();

        uint256 rate = oracle.mxpPerUsd();
        uint256 grossUsd = Math.mulDiv(mxpAmount, WAD, rate);
        if (grossUsd == 0) revert ZeroAmount();

        uint256 collateral = collateralUsd();
        if (collateral == 0) revert InsufficientCollateral();

        uint256 mxpBurned;
        uint256 usdCap;
        bool partialRedeem;

        if (collateral >= grossUsd) {
            mxpBurned = mxpAmount;
            usdCap = grossUsd;
            partialRedeem = false;
        } else {
            // Race shortfall: settle against collateral only; proportional burn
            usdCap = collateral;
            mxpBurned = Math.mulDiv(mxpAmount, usdCap, grossUsd);
            if (mxpBurned == 0) revert ZeroAmount();
            partialRedeem = true;
        }

        uint256 feeUsd = Math.mulDiv(usdCap, feeBps, BPS);
        uint256 userReceives = usdCap - feeUsd;

        mxp.burn(msg.sender, mxpBurned);
        if (feeUsd > 0) {
            accruedFees += feeUsd;
        }
        if (userReceives > 0) {
            usd.safeTransfer(msg.sender, userReceives);
        }

        emit Redeemed(msg.sender, mxpBurned, userReceives, feeUsd, partialRedeem);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function vaultBalance() public view returns (uint256) {
        return usd.balanceOf(address(this));
    }

    function collateralUsd() public view returns (uint256) {
        uint256 vault = vaultBalance();
        uint256 fees = accruedFees;
        if (fees > vault) revert InsufficientFeeBalance();
        return vault - fees;
    }

    function liabilityUsd() public view returns (uint256) {
        uint256 supply = mxp.totalSupply();
        if (supply == 0) return 0;
        uint256 rate = oracle.mxpPerUsd();
        if (rate == 0) return 0;
        return Math.mulDiv(supply, WAD, rate);
    }

    function reserveUsd() public view returns (uint256) {
        uint256 collateral = collateralUsd();
        uint256 liability = liabilityUsd();
        if (collateral <= liability) return 0;
        return collateral - liability;
    }

    function requiredReserveUsd() public view returns (uint256) {
        return Math.mulDiv(liabilityUsd(), BUFFER_BPS, BPS);
    }

    function mintHeadroomUsd() public view returns (uint256) {
        uint256 collateral = collateralUsd();
        uint256 liability = liabilityUsd();
        uint256 minCollateral = Math.mulDiv(liability, REQUIRED_RATIO_BPS, BPS);
        if (collateral <= minCollateral) return 0;
        // headroom = (collateral - 1.1 * liability) / 0.1 = 10 * collateral - 11 * liability
        return (collateral - minCollateral) * BPS / BUFFER_BPS;
    }

    function withdrawalWindowActive() public view returns (bool) {
        if (windowOpen()) return false;

        uint256 start;
        if (withdrawalWindowStart != 0) {
            // Early admin close
            start = withdrawalWindowStart;
        } else if (_windowArmed && block.number > windowEndBlock) {
            // Auto-expired at windowEndBlock
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
    // Internal
    // -------------------------------------------------------------------------

    function _setAllowlist(address account, bool allowed) internal {
        if (account == address(0)) revert ZeroAddress();
        allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    function _requireValidRateForCurrentWindow() internal view {
        if (oracle.mxpPerUsd() == 0) revert RateInvalid();
        if (oracle.rateWindowNonce() != windowNonce) revert RateInvalid();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
