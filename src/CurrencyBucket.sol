// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency} from "./Currency.sol";
import {SettlementToken} from "./SettlementToken.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IProtocolHub} from "./interfaces/IProtocolHub.sol";

/// @title CurrencyBucket — isolated USD vault, mint/redeem, reserves, fees for one settlement currency
contract CurrencyBucket is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant BUCKET_ADMIN_ROLE = keccak256("BUCKET_ADMIN_ROLE");

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant REQUIRED_RATIO_BPS = 11_000; // 110%
    uint256 public constant BUFFER_BPS = 1_000; // 10%
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%

    IERC20 public usd;
    SettlementToken public token;
    IOracle public oracle;
    IProtocolHub public hub;
    uint8 public currency;

    uint16 public feeBps;
    uint256 public accruedFees;

    event FeeBpsUpdated(uint16 feeBps);
    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Minted(address indexed user, uint256 usdIn, uint256 tokenOut);
    event Redeemed(address indexed user, uint256 tokenBurned, uint256 usdPaid, uint256 feeUsd, bool partialRedeem);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error NotAllowlisted();
    error WindowNotOpen();
    error HubPaused();
    error WithdrawalWindowInactive();
    error InsufficientHeadroom();
    error InsufficientCollateral();
    error InsufficientFees();
    error RateInvalid();
    error InsufficientFeeBalance();
    error InvalidCurrency();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address usd_,
        address token_,
        address oracle_,
        address hub_,
        uint8 currency_
    ) external initializer {
        if (
            admin == address(0) || usd_ == address(0) || token_ == address(0) || oracle_ == address(0)
                || hub_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (currency_ > Currency.ARS) revert InvalidCurrency();

        __AccessControl_init();

        usd = IERC20(usd_);
        token = SettlementToken(token_);
        oracle = IOracle(oracle_);
        hub = IProtocolHub(hub_);
        currency = currency_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BUCKET_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Admin: fee
    // -------------------------------------------------------------------------

    function setFeeBps(uint16 feeBps_) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    // -------------------------------------------------------------------------
    // Reserves & fees
    // -------------------------------------------------------------------------

    function depositReserve(uint256 usdAmount) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (usdAmount == 0) revert ZeroAmount();
        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        emit ReserveDeposited(msg.sender, usdAmount);
    }

    function withdrawReserve(uint256 usdAmount) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (usdAmount == 0) revert ZeroAmount();
        if (hub.paused()) revert HubPaused();
        if (!hub.withdrawalWindowActive()) revert WithdrawalWindowInactive();

        uint256 collateral = collateralUsd();
        if (usdAmount > collateral) revert InsufficientCollateral();
        uint256 collateralAfter = collateral - usdAmount;
        uint256 minCollateral = Math.mulDiv(liabilityUsd(), REQUIRED_RATIO_BPS, BPS);
        if (collateralAfter < minCollateral) revert InsufficientCollateral();

        usd.safeTransfer(msg.sender, usdAmount);
        emit ReserveWithdrawn(msg.sender, usdAmount);
    }

    function withdrawFees(uint256 amount) external onlyRole(BUCKET_ADMIN_ROLE) {
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

    function mint(uint256 usdAmount) external {
        if (usdAmount == 0) revert ZeroAmount();
        if (hub.paused()) revert HubPaused();
        if (!hub.windowOpen()) revert WindowNotOpen();
        if (!hub.isAllowlisted(msg.sender)) revert NotAllowlisted();
        _requireValidRateForCurrentWindow();
        if (usdAmount > mintHeadroomUsd()) revert InsufficientHeadroom();

        uint256 rate = oracle.ratePerUsd(currency);
        uint256 tokenOut = Math.mulDiv(usdAmount, rate, WAD);
        if (tokenOut == 0) revert ZeroAmount();

        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        token.mint(msg.sender, tokenOut);

        emit Minted(msg.sender, usdAmount, tokenOut);
    }

    function redeem(uint256 tokenAmount) external {
        if (tokenAmount == 0) revert ZeroAmount();
        if (hub.paused()) revert HubPaused();
        if (!hub.windowOpen()) revert WindowNotOpen();
        if (!hub.isAllowlisted(msg.sender)) revert NotAllowlisted();
        _requireValidRateForCurrentWindow();

        uint256 rate = oracle.ratePerUsd(currency);
        uint256 grossUsd = Math.mulDiv(tokenAmount, WAD, rate);
        if (grossUsd == 0) revert ZeroAmount();

        uint256 collateral = collateralUsd();
        if (collateral == 0) revert InsufficientCollateral();

        uint256 tokenBurned;
        uint256 usdCap;
        bool partialRedeem;

        if (collateral >= grossUsd) {
            tokenBurned = tokenAmount;
            usdCap = grossUsd;
            partialRedeem = false;
        } else {
            // Race shortfall: settle against collateral only; proportional burn
            usdCap = collateral;
            tokenBurned = Math.mulDiv(tokenAmount, usdCap, grossUsd);
            if (tokenBurned == 0) revert ZeroAmount();
            partialRedeem = true;
        }

        uint256 feeUsd = Math.mulDiv(usdCap, feeBps, BPS);
        uint256 userReceives = usdCap - feeUsd;

        token.burn(msg.sender, tokenBurned);
        if (feeUsd > 0) {
            accruedFees += feeUsd;
        }
        if (userReceives > 0) {
            usd.safeTransfer(msg.sender, userReceives);
        }

        emit Redeemed(msg.sender, tokenBurned, userReceives, feeUsd, partialRedeem);
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
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        uint256 rate = oracle.ratePerUsd(currency);
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

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireValidRateForCurrentWindow() internal view {
        if (oracle.ratePerUsd(currency) == 0) revert RateInvalid();
        if (oracle.rateWindowNonce(currency) != hub.windowNonce()) revert RateInvalid();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
