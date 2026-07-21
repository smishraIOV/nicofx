# NicoFX — Experimental Non-USD Stablecoin Protocol

Permissioned, crypto-collateralized stablecoin for currencies other than the US dollar. For local development and exploration we simulate the Mexican peso as **MXP** (not using MXN), collateralized by a test US dollar token **USD**.

MXP is not intended for retail users — only a select, allowlisted set of enterprise addresses may mint or redeem.

> **Assumption:** The **USD** token is always at par with the US dollar (1 USD token = 1 USD). The protocol does not price USD against fiat, haircut it, or model depeg risk. All collateralization, liability, and oracle math treat USD token balances as dollar value 1:1.
>
> This is separate from **MXP/USD FX risk**: an adverse peso rate move can still exhaust the 10% buffer and leave MXP undercollateralized. v1 handles that with a redemption race (first to exit at full rate; if the vault is short, proportional MXP burn for USD paid). Options and rationale: [devaluation-risk.md](./devaluation-risk.md).

## Goals

- Mint **MXP** as an ERC20, backed by **USD** collateral
- Admin-controlled mint/redeem windows (MRW)
- Trusted oracle for the MXP/USD exchange rate (not an always-on live feed)
- 110% collateralization (10% overcollateralization buffer) funded by MXP admin reserves
- Redeem-only protocol fee (bps), tracked as `accruedFees` in-engine
- On-chain allowlist to simulate KYC/AML
- Basic dApp for admins, users, and the oracle operator
- Local stack: Foundry (`forge`, `cast`, `anvil`)

## Architecture

Four on-chain components:

| Contract    | Role |
|-------------|------|
| `USD`       | Upgradeable ERC20 test dollar; admin mint / faucet |
| `MXP`       | Upgradeable ERC20 peso stablecoin; mint/burn only via the engine |
| `Oracle`    | Trusted rate publisher; stores last rate + timestamp |
| `MXPEngine` | Collateral vault, MRW, allowlist, mint/redeem, admin reserve deposit/withdraw; **Pausable** |

Upgradeability: UUPS proxies for `USD`, `MXP`, and `MXPEngine`. Oracle may be non-upgradeable for v1.

### Pause

`MXPEngine` is Pausable. **Only `MXP_Admin` may `pause` / `unpause`.** No other role can.

Pause is an emergency stop, separate from MRW:

| While paused | Allowed? |
|--------------|----------|
| `mint` / `redeem` | No |
| Oracle `setRate` | No |
| `withdrawReserve` | No |
| `depositReserve` | Yes (admin can still top up) |
| `withdrawFees` | Yes |
| `openWindow` / `closeWindow`, allowlist, `setFeeBps` | Yes |
| MXP ERC20 transfers | Yes (token is not paused) |

Pause does **not** replace the undercollateralization policy (v1 remains a redemption race); it is a manual kill switch for MXP_Admin.

### Roles

| Role | Capabilities |
|------|----------------|
| **USD_Admin** | Deploy/upgrade `USD`; mint USD (arbitrary, including test faucet) |
| **MXP_Admin** | Deploy/upgrade `MXP` + `MXPEngine`; open/close MRW; **pause/unpause engine**; manage allowlist; deposit/withdraw USD reserves; **set redeem `feeBps`**; **withdraw accrued fees** |
| **Trusted_Oracle** | Post MXP/USD exchange rate (only while MRW is open and engine is not paused) |
| **Users** | Allowlisted addresses only; mint/redeem MXP during open MRW (and engine not paused) |

Admin accounts are automatically allowlisted. Access control uses OpenZeppelin `AccessControl` (or equivalent role-based pattern).

For local Anvil runs, map roles to default accounts (e.g. account 0 = deployer/admins, account 1 = oracle, accounts 2–4 = users, others = non-permissioned).

## Exchange rate

- Rate format: `mxpPerUsd` with 18 decimals (e.g. `17.2e18` ≈ 17.2 MXP per 1 USD)
- Posted only by Trusted_Oracle, and **only while MRW is open**
- Mint and redeem require a rate that was set during the **current** open window
- After close, the last rate is frozen and used for liability / reserve checks during the withdrawal window

For oracle workflow testing, a small feeder script can pull a free FX API (e.g. USD→MXN) and call `setRate`.

### Conversion

```
mint:          mxpOut = usdIn * mxpPerUsd / 1e18
redeem gross:  grossUsd = mxpIn * 1e18 / mxpPerUsd
```

Then apply the redeem fee and any shortfall handling below. Outputs round in favor of the protocol (floor).

### Protocol fee (redeem only)

Mint has **no** fee. Redeem charges a protocol fee in basis points of the gross USD redemption value.

- `feeBps` set by **MXP_Admin** (recommended cap, e.g. max 10% = 1000 bps)
- Fee is taken in USD; the user receives the net amount
- Fee USD **stays in the engine’s USD balance**, but is tracked separately as `accruedFees` (excluded from collateral / buffer math)
- MXP_Admin may `withdrawFees` anytime (including while paused), independently of the post-MRW reserve window

```
grossUsd     = mxpIn * 1e18 / mxpPerUsd          # before shortfall handling
feeUsd       = grossUsd * feeBps / 10_000
netUsd       = grossUsd - feeUsd                 # what the user is owed at par
```

Full redeem (`collateralUsd >= grossUsd`): send `netUsd` to the user, burn all `mxpIn`; increase `accruedFees` by `feeUsd`.

Partial redeem (race, `0 < collateralUsd < grossUsd`) — shortfall uses **collateral only**, not accrued fees:

```
usdCap       = collateralUsd                     # gross USD claim that can be settled
mxpBurned    = mxpIn * usdCap / grossUsd         # proportional
feeUsd       = usdCap * feeBps / 10_000
userReceives = usdCap - feeUsd
# accruedFees += feeUsd; unburned MXP stays with the user
```

If `collateralUsd == 0`, redeem reverts.

## Collateralization (110%)

One USD ERC20 balance in the engine; split **logically** for accounting:

```
vaultUsd         = USD.balanceOf(MXPEngine)
accruedFees      = tracked protocol fee balance (subset of vaultUsd)
collateralUsd    = vaultUsd - accruedFees        # backs liabilities + 10% buffer
liabilityUsd     = dollar value of outstanding MXP (via latest oracle rate)
reserve (buffer) = collateralUsd - liabilityUsd
requiredReserve  = 0.10 * liabilityUsd

Invariant (always):
  collateralUsd >= 1.10 * liabilityUsd
  ⇔ reserve >= 0.10 * liabilityUsd
  ⇔ vaultUsd >= accruedFees + 1.10 * liabilityUsd
```

- Users deposit USD 1:1 with the dollar value of MXP minted (liability-matching collateral)
- MXP_Admin deposits additional USD as the **10% buffer** via `depositReserve`; that reserve sets max MXP supply
- Example: to mint $100 worth of MXP, the vault must already have ≥ $10 free buffer (admin-funded), and the user deposits $100
- Accrued fees are **not** counted toward the 10% buffer or mint headroom; the redemption race cannot spend them

### Mint headroom

```
mintHeadroomUsd = (collateralUsd - 1.10 * liabilityUsd) / 0.10
```

Mints that would exceed headroom revert. Admin can `depositReserve` at any time to increase capacity.

### Admin reserve withdraw

- MXP_Admin may withdraw **collateral** USD via `withdrawReserve` **only** during the first **100 blocks after MRW ends** (early close or auto-expiry)
- Even then, post-withdraw: `collateralUsd >= 1.10 * liabilityUsd`
- Opening a new MRW **immediately cancels** any remaining withdrawal window (mint/redeem and reserve withdrawal never overlap)
- Each early `closeWindow` sets `withdrawalWindowStart` to the current block; auto-expiry uses `windowEndBlock` as that start

### Fee withdraw

- MXP_Admin may `withdrawFees(amount)` anytime (including while paused), with `amount <= accruedFees`
- Decreases `accruedFees` and sends USD out; collateral ratio unchanged (`collateralUsd` stays the same)

## Mint / redeem window (MRW)

Controlled by MXP_Admin (`openWindow` / `closeWindow`).

- Default duration: **200 blocks** (`windowDurationBlocks`, configurable via `setWindowDurationBlocks`)
- On open, the window runs until `windowEndBlock` (inclusive), then auto-closes
- Admin may **close early** with `closeWindow` before the deadline
- Opening a new window cancels any active reserve-withdrawal window

While **open** (armed and `block.number <= windowEndBlock`):

- Allowlisted users may mint and redeem
- Trusted_Oracle may post rates

While **closed** (early close or expired):

- Mint, redeem, and rate updates revert
- Outstanding MXP is unchanged
- Admin may withdraw reserves for **100 blocks** after the effective close (`closeWindow` block, or `windowEndBlock` on expiry)
- Admin may still `withdrawFees` (accrued fees are outside collateral)

## Permissioning

- On-chain allowlist; only listed addresses may mint or redeem MXP
- Admins are auto-allowlisted
- MXP transfers are **unrestricted** in v1 (allowlist gates mint/redeem only)

## Core flows

```
USD_Admin ──mint──► USD
MXP_Admin ──depositReserve──► MXPEngine (anytime)
MXP_Admin ──open/close MRW──► MXPEngine
Trusted_Oracle ──setRate──► Oracle (MRW open only)

User ──approve USD──► mint ──► MXPEngine locks USD, mints MXP
User ──approve MXP──► redeem ──► MXPEngine burns MXP, returns net USD, accrues fee

MXP_Admin ──withdrawReserve──► (only blocks [close, close+100], 110% on collateralUsd)
MXP_Admin ──withdrawFees──► (anytime; amount ≤ accruedFees)
```

## Engine surface (sketch)

- `pause()` / `unpause()` — **MXP_Admin only**
- `openWindow()` / `closeWindow()` — MXP_Admin (close may be early; else auto-ends after `windowDurationBlocks`, default 200)
- `setWindowDurationBlocks(uint256)` — MXP_Admin (applies to the next open)
- `setAllowlist(user, allowed)` — MXP_Admin
- `setFeeBps(uint16 feeBps)` — MXP_Admin (redeem fee only; mint remains 0)
- `depositReserve(usdAmount)` — MXP_Admin, anytime (including while paused)
- `withdrawReserve(usdAmount)` — MXP_Admin, post-MRW window only; not while paused
- `withdrawFees(usdAmount)` — MXP_Admin, anytime (including while paused); `amount <= accruedFees`
- `mint(usdAmount)` / `redeem(mxpAmount)` — allowlisted; MRW open; not paused
- Views: `paused`, `feeBps`, `accruedFees`, `vaultBalance`, `collateralUsd`, `liabilityUsd`, `reserveUsd`, `requiredReserveUsd`, `mintHeadroomUsd`, `windowOpen`, `windowEndBlock`, `windowDurationBlocks`, `windowBlocksRemaining`, `withdrawalWindowActive`

Emit events for pause, fee updates, fee withdraw, window changes, allowlist updates, rate updates, mint, redeem, and reserve deposit/withdraw.

## dApp

Minimal Vite + React + wagmi/viem app against Anvil:

| View | Actions |
|------|---------|
| **Admin** | Mint USD; open/close MRW; pause/unpause; set redeem fee; withdraw fees; allowlist; deposit/withdraw reserve; utilization & withdrawal countdown |
| **Oracle** | Post rate (disabled when window closed); show last rate |
| **User** | Obtain USD (faucet); approve + mint MXP; redeem MXP; balances |

Also show window status, current rate, and whether the connected wallet is allowlisted.

## Repo layout

```
nicofx/
  foundry.toml
  src/           USD.sol, MXP.sol, Oracle.sol, MXPEngine.sol
  script/        Deploy.s.sol
  test/          MXPEngine.t.sol
  app/           Vite + React dApp (wagmi/viem)
  scripts/       oracle-feeder.mjs
  readme.md
  devaluation-risk.md
```

### Setup

**Requirements:** [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`) and [Node.js](https://nodejs.org/) (for the dApp; Node 18+ recommended).

Clone with submodules (OpenZeppelin + forge-std live under `lib/`):

```bash
git clone --recurse-submodules <repo-url>
cd nicofx
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

Then run the local stack below.

### Local development

```bash
# tests
forge test

# terminal 1 — local chain
anvil

# terminal 2 — deploy (writes app/src/contracts/deployments.json)
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# terminal 3 — dApp
cd app && npm install && npm run dev

# terminal 4 (optional) — oracle feeder (MRW must be open) uses live data (real USD/MXN quotes) from Frankfurter FE api
node scripts/oracle-feeder.mjs --once
# or loop every 60s:
node scripts/oracle-feeder.mjs
```

Open the printed Vite URL (usually `http://localhost:5173`). Use the Anvil account dropdown to switch Admin / Oracle / User roles.

Anvil roles after deploy: account 0 admin (USD + MXP), account 1 oracle operator, accounts 2–4 allowlisted users. Deploy sets redeem fee to 50 bps.

Suggested smoke path in the dApp:

1. **Admin** — mint USD to admin + user; approve + deposit reserve; open MRW  
2. **Oracle** (dApp or feeder) — post a rate  
3. **User** — approve + mint MXP; later redeem  
4. **Admin** — close MRW; withdraw reserve within 100 blocks if headroom allows

The feeder uses [Frankfurter](https://www.frankfurter.app/) (USD→MXN) and Anvil account 1’s key by default.

## Test focus

- Allowlist and MRW gating (including oracle `setRate`)
- Only MXP_Admin can pause/unpause; pause blocks mint/redeem/setRate/withdrawReserve
- Mint headroom / 10% buffer on `collateralUsd` (excludes `accruedFees`)
- Reserve deposit anytime (including while paused); withdraw only in post-close 100 blocks
- Withdraw reserve cannot breach 110% collateral floor
- `withdrawFees` anytime ≤ `accruedFees`; does not change `collateralUsd`
- Open MRW cancels active withdrawal window
- Redeem math, rounding, vault solvency, and redeem-only fee → `accruedFees`
- Partial redeem: proportional MXP burn when `collateralUsd` < grossUsd; fee on settled cap; fees not spendable in race; revert when collateral empty
- Rate must be set in current open window for mint/redeem
- UUPS upgrade smoke tests
