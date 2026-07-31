# FX Net — Permissioned Multicurrency FX Settlement (experimental)

Permissioned, crypto-collateralized FX settlement network. Settlement tokens (**CLP**, **ARS**) are each backed by an **isolated USD vault**, sharing one allowlist and one mint/redeem window calendar.

Tokens are not for retail use — only allowlisted enterprise addresses may mint or redeem. ERC20 transfers of USD / CLP / ARS are unrestricted.

> **Assumption:** The **USD** token is always at par with the US dollar (1 USD token = 1 USD). The protocol does not price USD against fiat, haircut it, or model depeg risk.
>
> **FX risk** is per bucket: an adverse CLP or ARS move can exhaust that bucket’s 10% buffer. v1 handles shortfall with a redemption race (proportional burn). See [devaluation-risk.md](./devaluation-risk.md).

## Goals

- Mint **CLP** and **ARS** as ERC20 settlement assets, each backed by its own **USD** collateral vault
- Shared admin-controlled mint/redeem window (MRW) and allowlist via `ProtocolHub`
- Shared trusted oracle posting per-currency rates (`clpPerUsd`, `arsPerUsd`)
- 110% collateralization per bucket (10% admin buffer)
- Redeem-only protocol fee (bps), tracked as `accruedFees` per bucket
- dApp (FX Net) for admin, oracle, and users — including token transfers and copyable allowlist addresses
- Local stack: Foundry (`forge`, `cast`, `anvil`)

## Architecture

| Contract | Role |
|----------|------|
| `USD` | Upgradeable ERC20 test dollar; admin mint / faucet (shared) |
| `ProtocolHub` | Shared allowlist (enumerable), MRW calendar, pause |
| `Oracle` | Trusted multi-rate publisher (`setRate(currency, rate)`) |
| `SettlementToken` | Upgradeable ERC20 (CLP / ARS instances); mint/burn only via its bucket |
| `CurrencyBucket` | Isolated USD vault, mint/redeem, fee, reserves for one currency |

Upgradeability: UUPS for `USD`, `ProtocolHub`, `SettlementToken`, `CurrencyBucket`. Oracle is non-upgradeable.

```text
ProtocolHub ──allowlist + MRW + pause──► both buckets + oracle
USD ──collateral──► CurrencyBucket(CLP) ──► SettlementToken CLP
USD ──collateral──► CurrencyBucket(ARS) ──► SettlementToken ARS
Oracle ──clpPerUsd / arsPerUsd──► both buckets
```

**Isolation:** ARS redemptions cannot spend CLP vault USD (and vice versa).

### Pause

`ProtocolHub` is Pausable. **Only hub admin may `pause` / `unpause`.**

| While paused | Allowed? |
|--------------|----------|
| `mint` / `redeem` (any bucket) | No |
| Oracle `setRate` | No |
| `withdrawReserve` (any bucket) | No |
| `depositReserve` / `withdrawFees` | Yes |
| `openWindow` / `closeWindow`, allowlist, `setFeeBps` | Yes |
| ERC20 transfers | Yes |

### Roles

| Role | Capabilities |
|------|----------------|
| **USD_Admin** | Mint USD |
| **Hub_Admin** | Open/close MRW; pause/unpause; manage shared allowlist |
| **Bucket_Admin** | Per-bucket deposit/withdraw reserve; set fee; withdraw fees; upgrade that bucket/token |
| **Trusted_Oracle** | Post CLP and ARS rates (MRW open, hub not paused) |
| **Users** | Allowlisted: mint/redeem in open MRW; anyone: transfer tokens |

Anvil mapping: account 0 = admins, account 1 = oracle, accounts 2–4 = allowlisted users.

## Exchange rate

- Format: units of currency per 1 USD, 18 decimals (e.g. `950e18` ≈ 950 CLP/USD)
- Currencies: `0 = CLP`, `1 = ARS`
- Posted only by Trusted_Oracle while hub MRW is open and hub is not paused
- Mint/redeem for a bucket require that currency’s rate stamped with the **current** hub `windowNonce`
- Feeder: `node scripts/oracle-feeder.mjs` posts CLP and ARS from [open.er-api.com](https://www.exchangerate-api.com/)

```
mint:          tokenOut = usdIn * ratePerUsd / 1e18
redeem gross:  grossUsd = tokenIn * 1e18 / ratePerUsd
```

### Protocol fee (redeem only)

Per-bucket `feeBps` (cap 1000). Fee USD stays in that bucket’s vault as `accruedFees` (excluded from collateral). Admin may `withdrawFees` anytime.

## Collateralization (110%, per bucket)

```
vaultUsd         = USD.balanceOf(CurrencyBucket)
accruedFees      = tracked fee balance (subset of vaultUsd)
collateralUsd    = vaultUsd - accruedFees
liabilityUsd     = dollar value of that token’s supply at its oracle rate
```

Invariant per bucket: `collateralUsd >= 1.10 * liabilityUsd`.

### Admin reserve withdraw

- Only during the first **100 blocks after MRW ends** (hub-derived)
- Opening a new MRW cancels the withdrawal window for all buckets
- Each bucket withdraws only from its own vault, still respecting 110%

## Mint / redeem window (MRW)

Shared on `ProtocolHub` (`openWindow` / `closeWindow`).

- Default **200 blocks**; configurable via `setWindowDurationBlocks`
- One open unlocks mint/redeem for **both** currencies (each still needs its own rate)
- While closed: mint/redeem/`setRate` revert; token balances unchanged

## Permissioning

- Shared on-chain allowlist on the hub; only listed addresses may mint or redeem
- Hub maintains an enumerable allowlist for the dApp (copy / pick recipient)
- Settlement token and USD transfers are **unrestricted**

## Core flows

```
USD_Admin ──mint──► USD
Hub_Admin ──open/close MRW / pause / allowlist──► ProtocolHub
Trusted_Oracle ──setRate(currency, rate)──► Oracle

Bucket_Admin ──depositReserve──► CurrencyBucket (anytime)
User ──mint/redeem──► CurrencyBucket (allowlisted, MRW open)
User ──transfer──► USD / CLP / ARS (any address)

Bucket_Admin ──withdrawReserve──► (post-MRW 100 blocks, per bucket)
Bucket_Admin ──withdrawFees──► (anytime, per bucket)
```

## dApp (FX Net)

Vite + React + wagmi/viem against Anvil:

| View | Actions |
|------|---------|
| **Admin** | Shared MRW/pause/allowlist; mint USD; per-bucket reserve & fee (bucket switcher) |
| **Oracle** | Post CLP and ARS rates |
| **User** | Mint/redeem active bucket; transfer USD/CLP/ARS; pick/copy allowlisted recipients |

## Repo layout

```
nicofx/
  foundry.toml
  src/           USD, ProtocolHub, Oracle, SettlementToken, CurrencyBucket, Currency
  script/        Deploy.s.sol
  test/          CurrencyBucket.t.sol
  app/           Vite + React dApp (FX Net)
  scripts/       oracle-feeder.mjs
  readme.md
  devaluation-risk.md
```

### Setup

**Requirements:** [Foundry](https://book.getfoundry.sh/getting-started/installation) and [Node.js](https://nodejs.org/) 18+.

```bash
git clone --recurse-submodules <repo-url>
cd nicofx
# or: git submodule update --init --recursive
```

### Local development

```bash
forge test

# terminal 1
anvil

# terminal 2 — deploy (writes app/src/contracts/deployments.json)
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# terminal 3
cd app && npm install && npm run dev

# terminal 4 (optional) — post CLP+ARS (MRW must be open)
node scripts/oracle-feeder.mjs --once
# or: node scripts/oracle-feeder.mjs --currency clp
```

Suggested smoke path:

1. **Admin** — mint USD; deposit reserve on CLP and ARS buckets; open MRW  
2. **Oracle** — post CLP and ARS rates (or run the feeder)  
3. **User** — mint/redeem each bucket; transfer tokens between accounts  
4. **Admin** — close MRW; withdraw reserves within 100 blocks if headroom allows  

## Test focus

- Shared allowlist / MRW / pause gating both buckets and oracle
- Per-bucket mint headroom and 110% floor
- Cross-bucket isolation (ARS stress does not drain CLP vault)
- Redeem fee → `accruedFees`; partial redeem race; fees not spendable in race
- Token transfers without allowlist
- Allowlist enumeration
- UUPS upgrade smoke on USD
