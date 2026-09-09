// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Currency {
    uint8 internal constant CLP = 0;
    uint8 internal constant ARS = 1;
    /// @notice Fiat USD token (settlement inventory / obligation denomination only; not a CurrencyBucket)
    uint8 internal constant USD = 2;

    /// @notice Number of valid currency ids. Loop bounds and validation MUST use this, never `USD`,
    /// @dev    so that adding a currency does not silently skip it in per-currency loops.
    uint8 internal constant COUNT = 3;

    /// @notice Currencies backed by a CurrencyBucket (CLP, ARS). USD is inventory only.
    uint8 internal constant BUCKET_COUNT = 2;

    function isValid(uint8 currency) internal pure returns (bool) {
        return currency < COUNT;
    }

    function isBucketCurrency(uint8 currency) internal pure returns (bool) {
        return currency < BUCKET_COUNT;
    }
}
