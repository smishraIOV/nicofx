# FX Net — Permissioned Multicurrency FX Settlement (experimental)

Permissioned, crypto-collateralized FX settlement network. Settlement tokens (**CLP**, **ARS**) are each backed by an **isolated USD vault**, sharing one allowlist and one mint/redeem window calendar.

Tokens are not meant for retail use — only allowlisted enterprise addresses may mint or redeem. Transfers, however, of USD / CLP / ARS are unrestricted.

> **Assumption:** For simplicity, the **USD** token is always treated at par with the US dollar (1 USD token = 1 USD). The protocol does not price USD against fiat, haircut it, or model depeg risk. This will not be acceptable in a production setting.
>
> **FX risk** is per bucket: an adverse CLP or ARS move can exhaust that bucket’s 10% buffer. v1 handles shortfall with a redemption race (proportional burn). See [devaluation-risk.md](./devaluation-risk.md).

## Goals

- Multilateral **obligation book** and session netting (this is the primary product)
- Mint **CLP** and **ARS** as ERC20 settlement inventory, each backed by an isolated **USD** vault
- Shared admin-controlled mint/redeem window (MRW) and allowlist via `ProtocolHub`
- Shared trusted oracle posting per-currency rates (`clpPerUsd`, `arsPerUsd`)
- 110% collateralization per bucket (10% admin buffer. provided by protocol operator for each bucket)
- Protocol fee (bps), only for redeeming USD, tracked as `accruedFees` per bucket
- dApp (FX Net): Settle / Admin / Oracle / User
- Local stack: Foundry (`forge`, `cast`, `anvil`)

## Architecture

| Contract | Role |
|----------|------|
| `USD` | Upgradeable ERC20 test dollar; admin mint / faucet (shared) |
| `ProtocolHub` | Shared allowlist (enumerable), MRW calendar, pause |
| `Oracle` | Trusted multi-rate publisher (`setRate(currency, rate)`) |
| `SettlementToken` | Upgradeable ERC20 (CLP / ARS instances); mint/burn only via its bucket |
| `CurrencyBucket` | Isolated USD vault, mint/redeem, fee, reserves for one currency |
| `NettingSession` | Multilateral obligation book; lock → net → holds token escrow for fund/claim |

Upgradeability: UUPS for `USD`, `ProtocolHub`, `SettlementToken`, `CurrencyBucket`, `NettingSession`. Oracle is non-upgradeable.

```text
ProtocolHub ──allowlist + pause──► buckets + oracle + NettingSession
USD / CLP / ARS ──inventory transfers──► NettingSession escrow
USD ──collateral──► CurrencyBucket(CLP|ARS) ──► SettlementToken
Oracle ──clpPerUsd / arsPerUsd──► buckets
```

**Isolation:** ARS redemptions cannot spend CLP vault USD (and vice versa). Netting is separate from mint/redeem.

### Multilateral settlement (obligation book)

Primary product flow (independent of MRW):

```text
Idle → Open (post obligations)
     → Locked (nets computed; posting frozen)
     → Funding (debtors transfer |net| into escrow)
     → Settled (creditors claim) | Cancelled
```

- `postObligation(debtor, creditor, currency, amount)` — currency is CLP / ARS / USD; poster is debtor or session admin; both parties allowlisted
- On `lockSession`, nets are `Σ owed_to − Σ owes` per party per currency (not the raw IOUs)
- Debtors `fund(currency)`; creditors `claim(currency)` once that currency’s escrow is fully funded
- Perfect multilateral cycles can net to zero and settle immediately on lock

**Fund / claim / escrow:** After lock, each party has a signed **net** per currency. Negative net → that party `fund`s `|net|` of the token into `NettingSession` (the escrow is this contract’s balance — there is no separate escrow contract). Positive net → they `claim` once that currency is fully funded. Funding is per-currency: CLP claims wait only on CLP debtors (same for ARS / USD).

#### Example graph (Anvil #2 / #3 / #4)

Ensure **#2** holds at least **90 CLP** of inventory (mint via User tab or transfer). Then on **Settle**:

1. **Admin (#0)** — Open session  
2. Post these obligations (poster = debtor or Admin):

| Debtor | Creditor | Currency | Amount |
|--------|----------|----------|--------|
| #2 User1 | #3 User2 | CLP | 100 |
| #3 User2 | #4 User3 | CLP | 40 |
| #4 User3 | #2 User1 | CLP | 10 |

3. **Lock & net** — matrix should show:

```text
#2: −90 CLP  (fund)
#3: +60 CLP  (claim)
#4: +30 CLP  (claim)
```

4. Switch to **#2** → Fund 90 CLP → **#3** Claim 60 → **#4** Claim 30 → **Settled**

Gross claims were 150 CLP; only **90 CLP** moves through escrow. A perfect cycle (50+50+50 the other way) nets to zero on lock with no fund/claim.

**Follow-up (not in this version):** auto mint/redeem inside a session to cover residuals; counterparty acceptance; coupling settlement calendar to MRW.

### Pause

`ProtocolHub` is Pausable. **Only hub admin may `pause` / `unpause`.**

| While paused | Allowed? |
|--------------|----------|
| `mint` / `redeem` (any bucket) | No |
| Oracle `setRate` | No |
| `withdrawReserve` (any bucket) | No |
| NettingSession post / fund / claim | No |
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
| **Users** | Allowlisted: mint/redeem in open MRW; post/fund/claim settlement; anyone: transfer tokens |

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
| **Settle** | Open/lock/cancel session; post obligations; view nets; fund/claim residuals |
| **Admin** | Shared MRW/pause/allowlist; mint USD; per-bucket reserve & fee (bucket switcher) |
| **Oracle** | Post CLP and ARS rates |
| **User** | Mint/redeem inventory; transfer USD/CLP/ARS; pick/copy allowlisted recipients |

## Repo layout

```
nicofx/
  foundry.toml
  src/           USD, ProtocolHub, Oracle, SettlementToken, CurrencyBucket, NettingSession, Currency
  script/        Deploy.s.sol
  test/          CurrencyBucket.t.sol, NettingSession.t.sol
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

Suggested smoke path (settlement-first):

1. **Admin / User** — mint USD and (via MRW) mint some CLP/ARS inventory; give **#2 ≥ 90 CLP**  
2. **Settle** — run the [example graph](#example-graph-anvil-2--3--4) (open → post three rows → lock → fund/claim)  
3. (Optional) Admin MRW / oracle / redeem flows for convertibility testing  

## Test focus

- Shared allowlist / MRW / pause gating both buckets and oracle
- Per-bucket mint headroom and 110% floor
- Cross-bucket isolation (ARS stress does not drain CLP vault)
- Redeem fee → `accruedFees`; partial redeem race; fees not spendable in race
- Token transfers without allowlist
- Allowlist enumeration
- NettingSession: triangle zero-net, cross-currency fund/claim, lifecycle + pause gates
- UUPS upgrade smoke on USD
