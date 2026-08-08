// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Currency {
    uint8 internal constant CLP = 0;
    uint8 internal constant ARS = 1;
    /// @notice Fiat USD token (settlement inventory / obligation denomination only; not a CurrencyBucket)
    uint8 internal constant USD = 2;
}
