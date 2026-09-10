# FX Net — Permissioned Multicurrency FX Settlement (experimental)

Permissioned, crypto-collateralized FX settlement network. Settlement tokens (**CLP**, **ARS**) are each backed by an **isolated USD vault**, sharing one allowlist and one mint/redeem window calendar.

Tokens are not meant for retail use — only allowlisted enterprise addresses may mint or redeem. Transfers, however, of USD / CLP / ARS are unrestricted.

> **Assumption:** For simplicity, the **USD** token is always treated at par with the US dollar (1 USD token = 1 USD). The protocol does not price USD against fiat, haircut it, or model depeg risk. This will not be acceptable in a production setting.
>
> **FX risk** is per bucket: an adverse CLP or ARS move can exhaust that bucket's 10% buffer. v1 handles shortfall with a redemption race (proportional burn). See [devaluation-risk.md](./devaluation-risk.md).

See [`reviews/`](./reviews/) for the standing critical reviews. The current one is
[R1](./reviews/R1-cb95b96.md) (reviewed at `cb95b96`), including which findings are addressed here and
which remain open. Findings are cited in code and tests as `R1-<id>` — see
[reviews/README.md](./reviews/README.md).

**New here?** [walkthrough.md](./walkthrough.md) is a self-guided tour of the local dApp — three
terminals, a full CLP + ARS settlement session, then the failure paths.

## Goals

- Multilateral **obligation book** and session netting, settled **delivery-versus-payment** (this is the primary product)
- Mint **CLP** and **ARS** as ERC20 settlement inventory, each backed by an isolated **USD** vault
- Shared admin-controlled mint/redeem window (MRW) and allowlist via `ProtocolHub`
- Shared trusted oracle posting per-currency rates, **one rate per currency per window**, bounded by a max deviation
- 110% collateralization per bucket (10% admin buffer. provided by protocol operator for each bucket)
- **Two-way pricing:** protocol fee (bps) on both mint and redeem per bucket, plus a settlement fee on netting sessions
- dApp (FX Net): Settle / Admin / Oracle / User
- Local stack: Foundry (`forge`, `cast`, `anvil`)

## Architecture

| Contract | Role |
|----------|------|
| `USD` | Upgradeable ERC20 test dollar; admin mint / faucet (shared) |
| `ProtocolHub` | Shared allowlist (enumerable), MRW calendar, minimum window length, pause |
| `Oracle` | Trusted multi-rate publisher; one rate per currency per window, deviation-bounded |
| `SettlementToken` | Upgradeable ERC20 (CLP / ARS instances); mint/burn only via its bucket |
| `CurrencyBucket` | Isolated USD vault, mint/redeem, two-way fees, timelocked reserve exit |
| `NettingSession` | Multilateral obligation book with two-sided consent; DVP settlement via escrow |

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
Idle → Open      post obligations, counterparties acknowledge
     → Frozen    nets final, posting stopped, debtors deposit
                 (deposits freely withdrawable — nothing is discharged yet)
     → Locked    reached automatically once EVERY currency is fully funded:
                 obligations discharged, creditor claims open
     → Settled   every creditor claim taken

     Frozen/Open → Cancelled   admin abandons; deposits refundable
     Frozen      → Failed      funding deadline passed while short; deposits refundable
```

**Delivery-versus-payment.** Obligations are discharged only on the `Frozen → Locked` transition, and that transition requires every currency to be fully funded. While a session is `Frozen`, any depositor may withdraw at will. There is therefore no window in which a creditor has given up a gross claim without the net being deliverable.

**Two-sided consent.** `postObligation(debtor, creditor, currency, amount, ref)` may be posted by the debtor, the creditor, or the session admin. The poster's own acknowledgement is implied; the counterparty must `acknowledge` before the row is folded into the nets. Until both parties consent, a row counts toward neither the nets nor `grossPosted`. Off-chain consent is supported via `acknowledgeWithSig` (EIP-712, EIP-1271 signers included), so a counterparty can sign and anyone can relay.

**External references.** Every obligation carries a `bytes32 ref` (invoice or trade id). It must be unique within a session, and an invoice already discharged by a locked session cannot be posted again. `voidObligation` removes a row before the book is frozen and frees its reference so a corrected row can replace it.

**Deposit / claim.** After freeze, each party has a signed **net** per currency. Negative net → that party deposits `|net| + fee` (partial deposits allowed). Positive net → they `claim` their net **at face value** once the session locks. Funding is per-currency in the sense that shortfalls are reported per currency, but claims open only when *all* currencies are funded — that is what makes the settlement atomic across legs.

**Settlement failure.** `freezeSession` stamps a funding deadline (`fundingWindowBlocks`, default 200). If the deadline passes while any currency is short, **anyone** may call `declareFailure(sessionId)`; every depositor then pulls their tokens back with `withdrawDeposit`. Recovery does not depend on the admin being available and works while the hub is paused. Session admin may declare failure early.

**Fee.** Session `feeBps` (cap 1000) is snapshotted when the session **opens**, before any party consents, so it cannot be re-priced under participants. The **debtor** funds `|net| + fee`, so creditors receive their net at face value and an invoice settles for its full amount. Fees are booked to per-currency `accruedFees` only when a session locks — a session that fails accrues nothing and depositors are made whole. Equal cycles with no debtors are free.

**Exposure limits.** `setMaxNet(party, currency, max)` caps a party's absolute net (0 = unlimited). The cap is checked when a row is folded into the nets, so an obligation that would breach a limit is rejected at acknowledgement rather than at freeze.

**Allowlist and settlement.** `deposit` does **not** re-check the allowlist — a party must always be able to meet what it owes, or the session would deadlock. `claim` **does** require current allowlist standing: a de-listed party keeps its entitlement and can claim once re-listed, or the admin may `sweepQuarantined` it to the `quarantineAddress`.

**Eliminated volume** (informational, not billed): per currency `eliminated = grossPosted − residual`, where residual is `Σ` positive nets. Read it next to `participantCount` and `counterpartyPairs`: consenting parties can post offsetting rows, so this is an **operator-attested** service metric, not a trustless one.

**Session history:** all per-session state is keyed by `sessionId` and never cleared. Opening a new session does not touch earlier ones, so past nets stay queryable and past claims and refunds stay available indefinitely. Because nothing is cleared and nets are maintained incrementally, `openSession` and `freezeSession` are O(1) — around 51k gas regardless of book size.

**Follow-up (not in this version):** auto mint/redeem inside a session to cover residuals; pro-rata partial settlement at the deadline as an alternative to refunding; coupling the settlement calendar to MRW.

#### Example graph (Anvil #2 / #3 / #4)

Ensure **#2** holds at least **90.45 CLP** of inventory (mint via User tab or transfer) — the debtor funds its net plus the receipt fee. Then on **Settle**:

1. **Admin (#0)** — Open session
2. Post these obligations (poster = debtor, creditor, or Admin), then have each counterparty **Acknowledge**:

| Debtor | Creditor | Currency | Amount | Ref |
|--------|----------|----------|--------|-----|
| #2 User1 | #3 User2 | CLP | 100 | inv-1 |
| #3 User2 | #4 User3 | CLP | 40 | inv-2 |
| #4 User3 | #2 User1 | CLP | 10 | inv-3 |

3. **Freeze & net** — matrix should show:

```text
#2: −90 CLP  (deposit 90.45 = 90 + 0.45 fee)
#3: +60 CLP  (claim 60)
#4: +30 CLP  (claim 30)
```

4. Switch to **#2** → Deposit 90.45 CLP. The session locks automatically on full funding → **#3** Claim 60 → **#4** Claim 30 → **Settled**

At the default **50 bps** settlement fee, #3 receives **60 CLP** and #4 receives **30 CLP** — face value — and the 0.45 CLP fee came from the debtor. Gross obligations were 150 CLP; 90 CLP moves through escrow; **60 CLP eliminated** (shown in the UI, not billed). A perfect cycle (50+50+50 the other way) nets to zero, so it locks and settles on freeze with no deposits and no fee.

### Pause

`ProtocolHub` is Pausable. **Only hub admin may `pause` / `unpause`.**

| While paused | Allowed? |
|--------------|----------|
| `mint` / `redeem` (any bucket) | No |
| Oracle `setRate` / `forceSetRate` | No |
| Reserve withdrawal request / execute | No |
| Session `postObligation` / `acknowledge` / `deposit` / `claim` | No |
| Session `openSession` / `freezeSession` | No |
| Session `cancelSession` / `declareFailure` / `withdrawDeposit` | **Yes** — escape hatches; pausing must never trap deposits |
| `depositReserve` / `withdrawFees` | Yes |
| `openWindow` / `closeWindow`, allowlist, fee setters | Yes |
| ERC20 transfers | Yes |

### Roles

| Role | Capabilities |
|------|----------------|
| **USD_Admin** | Mint USD |
| **Hub_Admin** | Open/close MRW; set window duration and minimum length; pause/unpause; manage shared allowlist |
| **Bucket_Admin** | Per-bucket deposit reserve; request/execute/cancel reserve withdrawal; set mint and redeem fees; set max rate age; withdraw bucket fees; upgrade that bucket/token |
| **Session_Admin** | Open/freeze/cancel session; declare failure early; set session fee, funding window, net caps and quarantine address; sweep quarantined claims; withdraw settlement fees; upgrade NettingSession |
| **Trusted_Oracle** | Post CLP and ARS rates (MRW open, hub not paused, once per window, within the deviation bound) |
| **Oracle owner** | Rotate the trusted oracle, set the deviation bound, `forceSetRate` for a genuine large move |
| **Users** | Allowlisted: mint/redeem in open MRW; post/acknowledge/deposit/claim settlement; anyone: transfer tokens |

Anvil mapping: account 0 = admins, account 1 = oracle, accounts 2–4 = allowlisted users.

## Exchange rate

- Format: units of currency per 1 USD, 18 decimals (e.g. `950e18` ≈ 950 CLP/USD)
- Currencies: `0 = CLP`, `1 = ARS` (`2 = USD` is settlement inventory only, never a bucket or a rate)
- Posted only by Trusted_Oracle while hub MRW is open and hub is not paused
- **One rate per currency per window.** A second post in the same MRW reverts. This is what makes the mint price and the redeem price the same within a window; without it, an allowlisted party could mint at one rate and redeem at another for a risk-free profit funded by the operator's buffer.
- **Deviation bound.** A post further than `maxDeviationBps` from the previous rate reverts. The oracle owner can push a genuine large move with `forceSetRate`, which emits a distinct `RateForced` event.
- **Staleness.** Buckets reject any USD-moving action — mint, redeem, and reserve withdrawal — if the rate is not stamped with the current `windowNonce` or is older than the bucket's `maxRateAge` (default 1 hour).
- Feeder: `node scripts/oracle-feeder.mjs` posts CLP and ARS from [open.er-api.com](https://www.exchangerate-api.com/); it skips a currency whose rate is already set for the window.

```
mint:          collateralIn = usdIn − mintFee
               tokenOut     = collateralIn * ratePerUsd / 1e18
redeem gross:  grossUsd     = tokenIn * 1e18 / ratePerUsd
               userReceives = grossUsd − redeemFee
```

### Protocol fees

**Mint (per bucket):** `mintFeeBps` (cap 1000) on USD paid in. The fee is retained as `accruedFees`; the remainder becomes collateral and determines how much token is minted.

**Redeem (per bucket):** `redeemFeeBps` (cap 1000) on USD paid out. Fee USD stays in that bucket's vault as `accruedFees` (excluded from collateral).

Charging both directions is deliberate: a mint/redeem round trip costs `mintFeeBps + redeemFeeBps`, so inventory creation is no longer free. Fees do not remove FX exposure held **across** windows — see [Limitations](#limitations).

**Settlement (session):** `feeBps` (cap 1000), snapshotted at `openSession`, funded by the **debtor** on top of its net. Creditors are paid at face value. Fees stay in `NettingSession` as per-currency `accruedFees` (not bucket collateral) and are booked only when a session locks. Session admin `withdrawFees(currency, amount)` anytime.

## Collateralization (110%, per bucket)

```
vaultUsd         = USD.balanceOf(CurrencyBucket)
accruedFees      = tracked fee balance (subset of vaultUsd)
collateralUsd    = vaultUsd - accruedFees
liabilityUsd     = dollar value of that token's supply at its oracle rate
coverageRatioBps = collateralUsd * 10000 / liabilityUsd
```

Invariant per bucket: `collateralUsd >= 1.10 * liabilityUsd` for minting.

`liabilityUsd` **reverts** if the rate is missing while token supply is outstanding, rather than reporting zero liabilities — otherwise a reserve withdrawal could drain a vault that still backs tokens.

### Admin reserve withdraw

Reserve exit is deliberately harder than a single call:

- Only while the **post-MRW withdrawal window** is active (100 blocks after the MRW ends)
- An MRW must stay open at least `minWindowBlocks` (default 50) before `closeWindow` is accepted, so a withdrawal window cannot be manufactured on demand
- **Two steps with a timelock:** `requestReserveWithdrawal(amount)`, then `executeReserveWithdrawal()` at least `RESERVE_WITHDRAWAL_DELAY_BLOCKS` (25) later. `cancelReserveWithdrawal()` drops a pending request. Every condition is re-checked at execution.
- Must leave **115%** coverage (`WITHDRAW_RATIO_BPS`), stricter than the 110% mint floor, so the operator cannot sit exactly on the line
- Requires a fresh, current-window rate
- Opening a new MRW cancels the withdrawal window for all buckets
- Each bucket withdraws only from its own vault

## Mint / redeem window (MRW)

Shared on `ProtocolHub` (`openWindow` / `closeWindow`).

- Default **200 blocks**; configurable via `setWindowDurationBlocks`
- Minimum open length **50 blocks**; configurable via `setMinWindowBlocks` (must not exceed the duration)
- One open unlocks mint/redeem for **both** currencies (each still needs its own rate)
- While closed: mint/redeem/`setRate` revert; token balances unchanged

## Permissioning

- Shared on-chain allowlist on the hub; only listed addresses may mint or redeem
- Hub maintains an enumerable allowlist for the dApp (copy / pick recipient)
- Settlement token and USD transfers are **unrestricted**

## Limitations

Known and deliberate, so they are not mistaken for oversights:

- **Netting is strictly per currency.** A party who is +100 CLP and −100 USD funds the USD leg in full and claims the CLP leg separately; no FX offset is applied. `NettingSession` has **no Oracle dependency** by design, which means a frozen session's outcome cannot be changed by a rate post. Cross-currency netting in a USD numeraire would import oracle risk into the netting product and is deliberately not built.
- **Cross-window FX exposure remains.** One rate per window plus two-way fees removes the *risk-free* intra-window round trip, but a holder who keeps inventory across a rate change still gains or loses against the buffer. That residual is inherent to redeeming at an oracle rate and is the subject of [devaluation-risk.md](./devaluation-risk.md); per-bucket caps and a coverage breaker are the intended controls.
- **`eliminated` is operator-attested.** References, dedupe and two-sided consent stop accidental and one-sided inflation, but two consenting addresses can still post offsetting rows. Quote it alongside participant and counterparty-pair counts.
- **Trust model is a single admin.** One key holds `DEFAULT_ADMIN_ROLE` across every contract plus the oracle owner, with no timelock on upgrades, and `DEFAULT_ADMIN_ROLE` on a `SettlementToken` can grant itself `ENGINE_ROLE` and mint unbacked inventory. Splitting these roles and timelocking upgrades is open work (review R1-M9).
- **The dApp still grants blanket allowances** for bucket mint/redeem. Settlement deposits approve only the exact amount needed; the mint/redeem paths do not yet (review R1-M10).
- **Shortfall is still a redemption race**, not a pause/queue/pro-rata waterfall (see devaluation-risk.md).
- **Storage layout changed** in this revision. These contracts are UUPS-upgradeable, but the `NettingSession` state model moved to session-keyed mappings, so an in-place upgrade over an older deployment would corrupt state. Deploy fresh.

## Core flows

```
USD_Admin ──mint──► USD
Hub_Admin ──open/close MRW / pause / allowlist──► ProtocolHub
Trusted_Oracle ──setRate(currency, rate)──► Oracle   (once per window)

Bucket_Admin ──depositReserve──► CurrencyBucket (anytime)
User ──mint/redeem──► CurrencyBucket (allowlisted, MRW open, fresh rate)
User ──transfer──► USD / CLP / ARS (any address)

Bucket_Admin ──requestReserveWithdrawal──► …25 blocks…──► executeReserveWithdrawal
Bucket_Admin ──withdrawFees──► (anytime, per bucket)
```

## dApp (FX Net)

Vite + React + wagmi/viem against Anvil:

| View | Actions |
|------|---------|
| **Settle** | Open/freeze/cancel session; declare failure; post obligations with a reference; acknowledge or void rows; view nets, deposits and shortfalls; deposit, withdraw a deposit, claim |
| **Admin** | Shared MRW/pause/allowlist; mint USD; per-bucket reserve and timelocked withdrawal; mint and redeem fees; settlement fee and funding window |
| **Oracle** | Post CLP and ARS rates |
| **User** | Mint/redeem inventory; transfer USD/CLP/ARS; pick/copy allowlisted recipients |

## Repo layout

```
nicofx/
  foundry.toml
  src/           USD, ProtocolHub, Oracle, SettlementToken, CurrencyBucket, NettingSession, Currency
  script/        Deploy.s.sol
  test/          CurrencyBucket.t.sol, NettingSession.t.sol, PricingAndReserves.t.sol,
                 Walkthrough.t.sol
  app/           Vite + React dApp (FX Net)
  scripts/       oracle-feeder.mjs, sync-abis.sh
  reviews/       R<n>-<commit>.md critical reviews + README (citation convention)
  readme.md, walkthrough.md, devaluation-risk.md, ideation.md
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

# terminal 4 (optional) — post CLP+ARS (MRW must be open, once per window)
node scripts/oracle-feeder.mjs --once
# or: node scripts/oracle-feeder.mjs --currency clp
```

After changing a contract interface, refresh the dApp's ABIs:

```bash
./scripts/sync-abis.sh
```

### Walkthrough

[walkthrough.md](./walkthrough.md) is the guided version of the above: three terminals, reserves and
inventory in **both** currencies, a session with CLP and ARS legs settled delivery-versus-payment, then
eight failure paths with their expected errors. Its numbers are asserted by `test/Walkthrough.t.sol`.

Short version if you just want the settlement flow:

1. **Admin / Oracle** — Open MRW, post **both** rates, deposit reserve into **each** bucket (the vaults
   are isolated), mint inventory
2. **Settle** — run the [example graph](#example-graph-anvil-2--3--4) (open → post → acknowledge →
   freeze → deposit → claim)
3. (Optional) redeem flows for convertibility testing

## Test focus

- Shared allowlist / MRW / pause gating both buckets and oracle
- Per-bucket mint headroom and 110% floor; coverage ratio
- Cross-bucket isolation (ARS stress does not drain CLP vault)
- Two-way fees: mint fee accrual, headroom grossed up for it, round trip costs both fees
- One rate per window; deviation bound and the `forceSetRate` override
- Rate staleness rejected on mint, redeem and reserve withdrawal; `liabilityUsd` reverts on a missing rate
- Minimum MRW length; reserve withdrawal timelock, cancellation, expiry and the 115% floor
- NettingSession: two-sided consent, reference dedupe and replay, void and re-post, EIP-712 acknowledgement
- NettingSession DVP: deposit withdrawable while frozen, auto-lock on full funding, face-value claims
- NettingSession failure: deadline, permissionless `declareFailure`, full recovery, no fees on a failed session, recovery while paused
- NettingSession: net caps, quarantine sweep, escrow reporting, past-session claims after a new session opens
- Invariants: per-currency nets sum to zero; escrow always covers open claims
- O(1) scaling of `openSession` and `freezeSession`
- Walkthrough: the exact figures quoted in walkthrough.md, so the doc cannot drift
- UUPS upgrade smoke on USD
