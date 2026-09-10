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
///
/// @dev Changes from review R1 (reviews/R1-cb95b96.md):
///  - **Two-way pricing (R1-C2).** `mintFeeBps` charges for inventory creation, not just exit. Together
///    with the Oracle's one-rate-per-window rule this removes the free round trip that previously paid
///    out of the operator's buffer. A round trip now costs `mintFeeBps + redeemFeeBps`.
///  - **Rate freshness everywhere (R1-H5).** `withdrawReserve` used to price liabilities with whatever rate
///    happened to be stored — including a stale one, during the post-MRW window when no new rate can be
///    posted. Every path that moves USD now requires a rate stamped with the current window nonce and
///    no older than `maxRateAge`.
///  - **`liabilityUsd` reverts on a missing rate (R1-H5)** rather than reporting zero liabilities, which
///    would have let a reserve withdrawal drain the vault while tokens were outstanding.
///  - **Timelocked reserve withdrawal (R1-M1).** Withdrawals are requested and then executed after a delay,
///    so participants can observe a pending withdrawal instead of it landing in one block. Execution
///    also requires a ratio above the mint floor, so the operator cannot sit exactly on 110%.
contract CurrencyBucket is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant BUCKET_ADMIN_ROLE = keccak256("BUCKET_ADMIN_ROLE");

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant REQUIRED_RATIO_BPS = 11_000; // 110% floor for mint
    /// @notice Reserve withdrawals must leave more headroom than the mint floor
    uint256 public constant WITHDRAW_RATIO_BPS = 11_500; // 115%
    uint256 public constant BUFFER_BPS = 1_000; // 10%
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant RESERVE_WITHDRAWAL_DELAY_BLOCKS = 25;
    uint256 public constant DEFAULT_MAX_RATE_AGE = 1 hours;

    IERC20 public usd;
    SettlementToken public token;
    IOracle public oracle;
    IProtocolHub public hub;
    uint8 public currency;

    /// @notice Fee on USD paid in on mint (R1-C2)
    uint16 public mintFeeBps;
    /// @notice Fee on USD paid out on redeem
    uint16 public redeemFeeBps;
    uint256 public accruedFees;
    /// @notice Maximum age of the posted rate for any USD-moving action (R1-H5)
    uint256 public maxRateAge;

    struct PendingWithdrawal {
        uint256 amount;
        uint256 requestBlock;
    }

    PendingWithdrawal public pendingWithdrawal;

    event MintFeeBpsUpdated(uint16 mintFeeBps);
    event RedeemFeeBpsUpdated(uint16 redeemFeeBps);
    event MaxRateAgeUpdated(uint256 maxRateAge);
    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawalRequested(address indexed by, uint256 amount, uint256 executableFromBlock);
    event ReserveWithdrawalCancelled(address indexed by, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Minted(address indexed user, uint256 usdIn, uint256 feeUsd, uint256 collateralUsd, uint256 tokenOut);
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
    error RateStale(uint256 lastUpdated, uint256 maxAge);
    error InvalidCurrency();
    error NoPendingWithdrawal();
    error WithdrawalNotExecutable(uint256 executableFromBlock);
    error WithdrawalAlreadyPending();
    error InvalidRateAge();

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
        if (!Currency.isBucketCurrency(currency_)) revert InvalidCurrency();

        __AccessControl_init();

        usd = IERC20(usd_);
        token = SettlementToken(token_);
        oracle = IOracle(oracle_);
        hub = IProtocolHub(hub_);
        currency = currency_;
        maxRateAge = DEFAULT_MAX_RATE_AGE;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BUCKET_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Admin: fees and rate policy
    // -------------------------------------------------------------------------

    function setMintFeeBps(uint16 mintFeeBps_) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (mintFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        mintFeeBps = mintFeeBps_;
        emit MintFeeBpsUpdated(mintFeeBps_);
    }

    function setRedeemFeeBps(uint16 redeemFeeBps_) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (redeemFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        redeemFeeBps = redeemFeeBps_;
        emit RedeemFeeBpsUpdated(redeemFeeBps_);
    }

    function setMaxRateAge(uint256 maxRateAge_) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (maxRateAge_ == 0) revert InvalidRateAge();
        maxRateAge = maxRateAge_;
        emit MaxRateAgeUpdated(maxRateAge_);
    }

    // -------------------------------------------------------------------------
    // Reserves & fees
    // -------------------------------------------------------------------------

    function depositReserve(uint256 usdAmount) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (usdAmount == 0) revert ZeroAmount();
        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        emit ReserveDeposited(msg.sender, usdAmount);
    }

    /// @notice Announce a reserve withdrawal. Executable after `RESERVE_WITHDRAWAL_DELAY_BLOCKS` (R1-M1).
    function requestReserveWithdrawal(uint256 usdAmount) external onlyRole(BUCKET_ADMIN_ROLE) {
        if (usdAmount == 0) revert ZeroAmount();
        if (pendingWithdrawal.amount != 0) revert WithdrawalAlreadyPending();
        if (hub.paused()) revert HubPaused();
        if (!hub.withdrawalWindowActive()) revert WithdrawalWindowInactive();
        _requireWithdrawable(usdAmount);

        pendingWithdrawal = PendingWithdrawal({amount: usdAmount, requestBlock: block.number});
        emit ReserveWithdrawalRequested(msg.sender, usdAmount, block.number + RESERVE_WITHDRAWAL_DELAY_BLOCKS);
    }

    function cancelReserveWithdrawal() external onlyRole(BUCKET_ADMIN_ROLE) {
        uint256 amount = pendingWithdrawal.amount;
        if (amount == 0) revert NoPendingWithdrawal();
        delete pendingWithdrawal;
        emit ReserveWithdrawalCancelled(msg.sender, amount);
    }

    /// @notice Execute a matured withdrawal request. Re-checks every condition at execution time.
    function executeReserveWithdrawal() external onlyRole(BUCKET_ADMIN_ROLE) {
        PendingWithdrawal memory request = pendingWithdrawal;
        if (request.amount == 0) revert NoPendingWithdrawal();

        uint256 executableFrom = request.requestBlock + RESERVE_WITHDRAWAL_DELAY_BLOCKS;
        if (block.number < executableFrom) revert WithdrawalNotExecutable(executableFrom);

        if (hub.paused()) revert HubPaused();
        if (!hub.withdrawalWindowActive()) revert WithdrawalWindowInactive();
        _requireWithdrawable(request.amount);

        delete pendingWithdrawal;
        usd.safeTransfer(msg.sender, request.amount);
        emit ReserveWithdrawn(msg.sender, request.amount);
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

    /// @notice Deposit USD for settlement inventory. `mintFeeBps` of the USD is retained as fee income,
    ///         the remainder becomes collateral and sets the amount of token minted (R1-C2).
    function mint(uint256 usdAmount) external {
        if (usdAmount == 0) revert ZeroAmount();
        if (hub.paused()) revert HubPaused();
        if (!hub.windowOpen()) revert WindowNotOpen();
        if (!hub.isAllowlisted(msg.sender)) revert NotAllowlisted();
        _requireValidRate();
        if (usdAmount > mintHeadroomUsd()) revert InsufficientHeadroom();

        uint256 feeUsd = Math.mulDiv(usdAmount, mintFeeBps, BPS);
        uint256 collateralIn = usdAmount - feeUsd;
        if (collateralIn == 0) revert ZeroAmount();

        uint256 rate = oracle.ratePerUsd(currency);
        uint256 tokenOut = Math.mulDiv(collateralIn, rate, WAD);
        if (tokenOut == 0) revert ZeroAmount();

        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        if (feeUsd > 0) {
            accruedFees += feeUsd;
        }
        token.mint(msg.sender, tokenOut);

        emit Minted(msg.sender, usdAmount, feeUsd, collateralIn, tokenOut);
    }

    function redeem(uint256 tokenAmount) external {
        if (tokenAmount == 0) revert ZeroAmount();
        if (hub.paused()) revert HubPaused();
        if (!hub.windowOpen()) revert WindowNotOpen();
        if (!hub.isAllowlisted(msg.sender)) revert NotAllowlisted();
        _requireValidRate();

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

        uint256 feeUsd = Math.mulDiv(usdCap, redeemFeeBps, BPS);
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
        // Saturate rather than revert: this view backs every other view and the UI (review R1 L-item)
        return vault > fees ? vault - fees : 0;
    }

    /// @dev Reverts on a missing rate while tokens are outstanding, rather than reporting no
    ///      liabilities and letting a reserve withdrawal drain the vault (R1-H5).
    function liabilityUsd() public view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        uint256 rate = oracle.ratePerUsd(currency);
        if (rate == 0) revert RateInvalid();
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

    /// @notice Current collateralisation in bps. `type(uint256).max` when there are no liabilities.
    function coverageRatioBps() public view returns (uint256) {
        uint256 liability = liabilityUsd();
        if (liability == 0) return type(uint256).max;
        return Math.mulDiv(collateralUsd(), BPS, liability);
    }

    /// @notice Maximum gross USD that can be paid in, accounting for the mint fee.
    /// @dev A mint adds `usdIn - fee` to both collateral and liability, so the ratio constraint gives
    ///      `net <= 10 * (collateral - 1.1 * liability)`; gross is that grossed up for the fee.
    function mintHeadroomUsd() public view returns (uint256) {
        uint256 collateral = collateralUsd();
        uint256 liability = liabilityUsd();
        uint256 minCollateral = Math.mulDiv(liability, REQUIRED_RATIO_BPS, BPS);
        if (collateral <= minCollateral) return 0;

        uint256 netHeadroom = (collateral - minCollateral) * BPS / BUFFER_BPS;
        uint256 fee = mintFeeBps;
        if (fee == 0) return netHeadroom;
        return Math.mulDiv(netHeadroom, BPS, BPS - fee);
    }

    /// @notice USD the admin could withdraw right now, ignoring window and timelock gating
    function withdrawableReserveUsd() public view returns (uint256) {
        uint256 collateral = collateralUsd();
        uint256 minCollateral = Math.mulDiv(liabilityUsd(), WITHDRAW_RATIO_BPS, BPS);
        if (collateral <= minCollateral) return 0;
        return collateral - minCollateral;
    }

    function rateIsFresh() public view returns (bool) {
        if (oracle.ratePerUsd(currency) == 0) return false;
        if (oracle.rateWindowNonce(currency) != hub.windowNonce()) return false;
        return block.timestamp - oracle.lastUpdated(currency) <= maxRateAge;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Required by every action that moves USD, including reserve withdrawal (R1-H5)
    function _requireValidRate() internal view {
        if (oracle.ratePerUsd(currency) == 0) revert RateInvalid();
        if (oracle.rateWindowNonce(currency) != hub.windowNonce()) revert RateInvalid();
        uint256 updatedAt = oracle.lastUpdated(currency);
        if (block.timestamp - updatedAt > maxRateAge) revert RateStale(updatedAt, maxRateAge);
    }

    function _requireWithdrawable(uint256 usdAmount) internal view {
        _requireValidRate();

        uint256 collateral = collateralUsd();
        if (usdAmount > collateral) revert InsufficientCollateral();
        uint256 collateralAfter = collateral - usdAmount;
        // Stricter than the mint floor, so a withdrawal cannot leave the bucket on the 110% line
        uint256 minCollateral = Math.mulDiv(liabilityUsd(), WITHDRAW_RATIO_BPS, BPS);
        if (collateralAfter < minCollateral) revert InsufficientCollateral();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
