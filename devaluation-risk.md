# FX devaluation risk

The protocol assumes the **USD** token stays at par with the US dollar (see [readme](./readme.md)). It does **not** assume a stable MXP/USD (peso) rate.

The 10% overcollateralization buffer absorbs limited adverse FX moves. If the dollar falls enough against the peso that the dollar value of outstanding MXP exceeds vault USD (roughly more than a ~10% adverse move vs the rate that funded the buffer), full par redemptions are no longer fully backed for every holder.

Because the oracle can update the rate only while MRW is open, a large update at or after window open can tip the system underwater while mint/redeem are live.

## Chosen approach (v1)

**First-come, first-served (race)** with **proportional burn** on shortfall:

1. Compute full `usdOut` at the oracle rate.
2. If `collateralUsd >= grossUsd`, pay net (after fee) and burn all `mxpIn`.
3. If `0 < collateralUsd < grossUsd`, settle `usdCap = collateralUsd`, burn `mxpBurned = mxpIn * usdCap / grossUsd` (floor), apply redeem fee on `usdCap` into `accruedFees`, send net USD to the user; unburned MXP stays with the user. Accrued fees are not available to the race.
4. If `collateralUsd == 0`, revert.

Early redeemers exit at par while USD lasts; later ones take a partial fill or fail when empty. Unfair under contention; acceptable as an experimental default.

`MXPEngine` is also **Pausable**, but only **MXP_Admin** may pause/unpause. That is a manual emergency stop, not an automatic undercollateralization response — v1 does not auto-pause on FX shocks.

## Options considered

### 1. First-come, first-served (race) — **selected for v1**

Redeem at full oracle rate while **collateral** can pay. On shortfall: settle against `collateralUsd` only (not `accruedFees`), burn MXP proportionally, accrue redeem fee; revert only if collateral is empty.

- **Pros:** Simple; no global haircut accounting; matches “exit while you can.”
- **Cons:** Unfair to slower participants; gas wars; poor fit for a long-term enterprise product.

### 2. Pro-rata haircut

Every redemption pays `usdOut = fullAmount * vaultUsd / liabilityUsd` (same ratio for all).

- **Pros:** Equal treatment; no race; predictable shortfall.
- **Cons:** Breaks par redemption; UX and communication must make the haircut explicit.

### 3. Emergency pause / freeze MRW

If `vaultUsd < liabilityUsd` (or below the 110% floor), auto-pause mint and redeem (and optionally rate updates) until admin tops up or another resolution runs.

- **Pros:** Stops the race; buys time; fits an admin-operated design.
- **Cons:** Does not clear undercollateralization by itself; capital can remain trapped until a cure.

### 4. Admin recapitalization (mandatory top-up)

Require MXP_Admin to `depositReserve` before MRW can open (or before any redeem) when undercollateralized; optionally block `openWindow` until `vault >= 1.10 * liability`.

- **Pros:** Restores the par-redemption promise; natural for an enterprise/admin-run system.
- **Cons:** Depends on admin having USD ready; the window may stay closed indefinitely.

### 5. Block adverse rate updates

Oracle `setRate` reverts if the new rate would push `liabilityUsd` above `vaultUsd / 1.10` (or above vault).

- **Pros:** Prevents insolvency from oracle posts; the buffer always “works” on-chain.
- **Cons:** On-chain FX can go stale/wrong; mint/redeem may use a rate that no longer matches the market.

### 6. Partial fills only (soft race)

Redeem up to available backing; return unused MXP; no global haircut formula — `min(requested, remainingBacking)`.

- **Pros:** Does not oversell the vault; simpler than pro-rata accounting.
- **Cons:** Still ordered by who transacts first; last in line waits or fails.

### 7. Settlement / shortfall auction

When undercollateralized, auction MXP for remaining USD, or auction redemption rights at a clearing price.

- **Pros:** Market discovers the shortfall price.
- **Cons:** Heavy for v1; awkward for a small allowlisted set.

### 8. Socialize via fees / rebuild buffer

Pause or apply a light haircut now; rebuild toward 110% via mint/redeem fees or admin deposits over time.

- **Pros:** Path back to a healthy collateral ratio.
- **Cons:** Multi-phase policy and more moving parts.

### 9. Delayed redemption (queue)

Queue redeems at a pre-shock rate or TWAP; process when reserves are restored.

- **Pros:** Avoids instant mark-to-market loss for redeemers.
- **Cons:** Queue complexity; timing risk; priority still matters unless combined with pro-rata.
