# FX Net — Permissioned Multicurrency FX Settlement (experimental)

A permissioned, crypto-collateralized FX settlement network. The product is a **multilateral
obligation book**: participants post what they owe each other, the book is netted, and only the
residual moves — settled delivery-versus-payment, so nothing is discharged until everything is
deliverable.

Settlement inventory is **CLP** and **ARS** ERC20s, each backed by its own isolated **USD** vault.
Only allowlisted enterprise addresses may mint or redeem; token transfers are currently unrestricted.

> **▸ Want to just run it?** [**walkthrough.md**](./walkthrough.md) is a self-guided tour — three
> terminals, a full CLP + ARS settlement session, then eight failure paths with their expected errors.
> Start there and come back for the detail.
>
> **▸ Want the critique?** [**reviews/**](./reviews/) holds the standing critical reviews. The current
> one is [R1](./reviews/R1-cb95b96.md), which records what is fixed and what is still open. Findings
> are cited in code and tests as `R1-<id>` — see [reviews/README.md](./reviews/README.md).

**Contents** · [Quick start](#quick-start) · [What it does](#what-it-does) ·
[Architecture](#architecture) · [Who can do what](#who-can-do-what) ·
[Settlement](#settlement-the-obligation-book) · [Inventory](#inventory-buckets-rates-and-fees) ·
[Operations](#operations) · [Limitations](#limitations) · [Reference](#reference)

---

## Quick start

**Requirements:** [Foundry](https://book.getfoundry.sh/getting-started/installation) and
[Node.js](https://nodejs.org/) 18+.

```bash
git clone --recurse-submodules <repo-url>
cd nicofx                     # or: git submodule update --init --recursive
forge test
```

Then three terminals:

```bash
anvil                                                                    # 1 — chain

forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --broadcast                                                            # 2 — deploy

cd app && npm install && npm run dev                                     # 3 — dApp
```

Deploying writes `app/src/contracts/deployments.json`, which the dApp reads. Optional fourth terminal
feeds live FX rates (MRW must be open, one post per currency per window):

```bash
node scripts/oracle-feeder.mjs --once
```

After changing a contract interface, refresh the dApp's ABIs with `./scripts/sync-abis.sh`.

The dApp has four views:

| View | Actions |
|------|---------|
| **Settle** | Open/freeze/cancel session; declare failure; post obligations with a reference; acknowledge or void rows; view nets, deposits and shortfalls; deposit, withdraw a deposit, claim |
| **Admin** | Shared MRW/pause/allowlist; mint USD; per-bucket reserve and timelocked withdrawal; mint and redeem fees; settlement fee and funding window |
| **Oracle** | Post CLP and ARS rates |
| **User** | Mint/redeem inventory; transfer USD/CLP/ARS; pick/copy allowlisted recipients |

**[walkthrough.md](./walkthrough.md) drives all of this step by step** — its figures are asserted by
`test/Walkthrough.t.sol`, so they cannot drift from what the contracts do.

## What it does

- **Multilateral netting, settled DVP.** The primary product. A book of obligations nets to residuals;
  obligations are discharged only once every currency in the session is fully funded.
- **Two-sided consent.** An obligation nets only after both parties acknowledge it, and carries an
  external invoice reference that cannot be reused once discharged.
- **Convertible inventory.** CLP and ARS mint against USD at an oracle rate, each from an isolated
  vault held at 110% collateralization, inside a shared mint/redeem window.
- **Two-way pricing.** Fees on both mint and redeem, plus a settlement fee funded by debtors so
  creditors are paid at face value.

Local stack is Foundry (`forge`, `cast`, `anvil`) plus a Vite/React dApp.

## Architecture

| Contract | Role |
|----------|------|
| `USD` | Upgradeable ERC20 test dollar; admin mint / faucet (shared) |
| `ProtocolHub` | Shared allowlist (enumerable), MRW calendar, minimum window length, pause |
| `Oracle` | Trusted multi-rate publisher; one rate per currency per window, deviation-bounded |
| `SettlementToken` | Upgradeable ERC20 (CLP / ARS instances); mint/burn only via its bucket |
| `CurrencyBucket` | Isolated USD vault, mint/redeem, two-way fees, timelocked reserve exit |
| `NettingSession` | Multilateral obligation book with two-sided consent; DVP settlement via escrow |

```text
ProtocolHub ──allowlist + pause──► buckets + oracle + NettingSession
Oracle ──clpPerUsd / arsPerUsd──► buckets
USD ──collateral──► CurrencyBucket(CLP|ARS) ──mint/burn──► SettlementToken
USD / CLP / ARS ──inventory transfers──► NettingSession escrow
```

**Isolation:** ARS redemptions cannot spend CLP vault USD, and vice versa. Netting is entirely separate
from mint/redeem — a session never reads the oracle.

**Upgradeability:** UUPS for `USD`, `ProtocolHub`, `SettlementToken`, `CurrencyBucket` and
`NettingSession`. `Oracle` is non-upgradeable.

## Who can do what

| Role | Capabilities |
|------|----------------|
| **USD_Admin** | Mint USD |
| **Hub_Admin** | Open/close MRW; set window duration and minimum length; pause/unpause; manage the shared allowlist |
| **Bucket_Admin** | Per-bucket deposit reserve; request/execute/cancel reserve withdrawal; set mint and redeem fees; set max rate age; withdraw bucket fees; upgrade that bucket/token |
| **Session_Admin** | Open/freeze/cancel session; declare failure early; set session fee, funding window, net caps and quarantine address; sweep quarantined claims; withdraw settlement fees; upgrade NettingSession |
| **Trusted_Oracle** | Post CLP and ARS rates (MRW open, hub not paused, once per window, within the deviation bound) |
| **Oracle owner** | Rotate the trusted oracle, set the deviation bound, `forceSetRate` for a genuine large move |
| **Users** | Allowlisted: mint/redeem in an open MRW, and post/acknowledge/deposit/claim in a session. Anyone: transfer tokens |

**Allowlist.** One shared, enumerable allowlist on the hub gates minting, redeeming and being named in
an obligation. Token transfers are **unrestricted**, so inventory can leave the permissioned set —
those holders can move tokens but cannot mint, redeem or settle.

Locally: Anvil account 0 holds every admin role, 1 is the oracle, 2–4 are allowlisted users, labelled
`User A`–`User C` in the dApp.

## Settlement: the obligation book

The primary product, and independent of the mint/redeem window.

```text
Idle → Open      post obligations, counterparties acknowledge
     → Frozen    nets final, posting stopped, debtors deposit
                 (deposits freely withdrawable — nothing is discharged yet)
     → Locked    reached automatically once EVERY currency is fully funded:
                 obligations discharged, creditor claims open
     → Settled   every creditor claim taken

     Open/Frozen → Cancelled   admin abandons; deposits refundable
     Frozen      → Failed      funding deadline passed while short; deposits refundable
```

**Delivery-versus-payment.** Discharge happens only on `Frozen → Locked`, which requires every
currency fully funded. While `Frozen`, any depositor may withdraw at will — so there is no window in
which a creditor has given up a gross claim without the net being deliverable.

**Two-sided consent.** `postObligation(debtor, creditor, currency, amount, ref)` may be posted by
either party or the session admin; the poster's own consent is implied. Until the counterparty
`acknowledge`s, the row counts toward neither the nets nor `grossPosted`. `acknowledgeWithSig` takes
off-chain consent (EIP-712, EIP-1271 signers included) so anyone can relay a signature.

**External references.** Every obligation carries a `bytes32 ref` (invoice or trade id), unique within
a session and never reusable once a locked session has discharged it. `voidObligation` removes a row
before freeze and frees its reference for a corrected replacement.

**Deposit / claim.** Each party holds a signed **net** per currency. Negative → deposit `|net| + fee`
(partial deposits allowed). Positive → `claim` the net **at face value** once the session locks.
Shortfalls report per currency, but claims open only when *all* currencies are funded, which is what
makes settlement atomic across legs.

**Settlement failure.** `freezeSession` stamps a deadline (`fundingWindowBlocks`, default 200). If it
passes while any currency is short, **anyone** may `declareFailure(sessionId)` and every depositor
recovers via `withdrawDeposit` — no dependence on the admin, and it works while paused. Session admin
may declare failure early.

**Fee.** Session `feeBps` (cap 1000) is snapshotted at **open**, before anyone consents, so it cannot
be re-priced under participants. The **debtor** funds `|net| + fee`, so an invoice settles for its face
amount. Fees book to `accruedFees` only when a session locks — a failed session accrues nothing and
depositors are made whole. Equal cycles with no debtors are free.

**Exposure limits.** `setMaxNet(party, currency, max)` caps a party's absolute net (0 = unlimited),
checked at inclusion — so a breaching obligation is rejected at acknowledgement, not at freeze.

**Allowlist during settlement.** `claim` requires current standing; `deposit` deliberately does not,
since a party must always be able to meet what it owes. A de-listed creditor keeps its entitlement for
re-listing, or the admin may `sweepQuarantined` it to the `quarantineAddress`.

**Eliminated volume** (informational, not billed): `eliminated = grossPosted − residual` per currency,
residual being `Σ` positive nets. Read it next to `participantCount` and `counterpartyPairs` —
consenting parties can post offsetting rows, so it is **operator-attested**, not trustless.

**Session history.** State is keyed by `sessionId` and never cleared, so past nets, claims and refunds
stay available indefinitely. With nothing to clear and nets maintained incrementally, `openSession` and
`freezeSession` are O(1) — about 51k gas regardless of book size.

**Not in this version:** auto mint/redeem inside a session to cover residuals; pro-rata partial
settlement at the deadline as an alternative to refunding; coupling the settlement calendar to the MRW.

## Inventory: buckets, rates and fees

CLP and ARS exist so that a residual can actually be delivered. Each is minted against USD at the
oracle rate, from its own vault, during a shared window.

### Mint / redeem window (MRW)

Shared on `ProtocolHub` (`openWindow` / `closeWindow`).

- Default **200 blocks**, configurable via `setWindowDurationBlocks`
- Minimum open length **50 blocks**, configurable via `setMinWindowBlocks` (must not exceed the duration)
- One open unlocks mint/redeem for **both** currencies — each still needs its own rate
- While closed, mint, redeem and `setRate` all revert; balances are untouched

### Exchange rates

- Units of currency per 1 USD, 18 decimals (`950e18` ≈ 950 CLP/USD)
- Currency ids: `0 = CLP`, `1 = ARS`. `2 = USD` is settlement inventory only — never a bucket or a rate
- Posted only by Trusted_Oracle, while the MRW is open and the hub is not paused
- **One rate per currency per window.** A second post in the same MRW reverts, making the mint and
  redeem price identical inside a window. Without it, a party could mint at one rate and redeem at
  another for a risk-free profit out of the operator's buffer.
- **Deviation bound.** A post further than `maxDeviationBps` from the previous rate reverts. The oracle
  owner can push a genuine large move with `forceSetRate`, which emits a distinct `RateForced` event.
- **Staleness.** Every USD-moving action — mint, redeem, reserve withdrawal — is rejected if the rate
  is not stamped with the current `windowNonce`, or is older than `maxRateAge` (default 1 hour).
- Feeder: `node scripts/oracle-feeder.mjs` pulls from
  [open.er-api.com](https://www.exchangerate-api.com/) and skips a currency already rated this window.

```text
mint:    collateralIn = usdIn − mintFee
         tokenOut     = collateralIn * ratePerUsd / 1e18
redeem:  grossUsd     = tokenIn * 1e18 / ratePerUsd
         userReceives = grossUsd − redeemFee
```

### Fees

| Fee | Base | Where it goes |
|---|---|---|
| `mintFeeBps` (cap 1000) | USD paid in | bucket `accruedFees`; the remainder becomes collateral and sets how much token is minted |
| `redeemFeeBps` (cap 1000) | USD paid out | bucket `accruedFees`, excluded from collateral |
| session `feeBps` (cap 1000) | the debtor's net | `NettingSession` `accruedFees`, per currency, booked only when a session locks |

Charging both mint and redeem is deliberate: a round trip costs `mintFeeBps + redeemFeeBps`, so
creating inventory is no longer free. It does not remove FX exposure held **across** windows — see
[Limitations](#limitations).

### Collateralization (110%, per bucket)

```text
vaultUsd         = USD.balanceOf(CurrencyBucket)
accruedFees      = tracked fee balance (subset of vaultUsd)
collateralUsd    = vaultUsd − accruedFees
liabilityUsd     = dollar value of that token's supply at its oracle rate
coverageRatioBps = collateralUsd * 10000 / liabilityUsd
```

Minting requires `collateralUsd >= 1.10 * liabilityUsd`. The 10% buffer is operator capital, deposited
per bucket with `depositReserve` (allowed at any time, including while paused).

`liabilityUsd` **reverts** when the rate is missing while token supply is outstanding, rather than
reporting zero liabilities — otherwise a reserve withdrawal could drain a vault that still backs tokens.

## Operations

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

### Reserve withdrawal

Getting operator capital back out is deliberately harder than a single call:

- Only while the **post-MRW withdrawal window** is active (100 blocks after the MRW ends). Opening a
  new MRW cancels it for all buckets.
- An MRW must stay open at least `minWindowBlocks` before `closeWindow` is accepted, so a withdrawal
  window cannot be manufactured on demand.
- **Two steps with a timelock:** `requestReserveWithdrawal(amount)`, then `executeReserveWithdrawal()`
  at least `RESERVE_WITHDRAWAL_DELAY_BLOCKS` (25) later. `cancelReserveWithdrawal()` drops a pending
  request. Every condition is re-checked at execution.
- Must leave **115%** coverage (`WITHDRAW_RATIO_BPS`) — stricter than the 110% mint floor, so the
  operator cannot sit exactly on the line.
- Requires a fresh, current-window rate, and draws only on that bucket's own vault.

Bucket and session fee income is separate: `withdrawFees` is available at any time and is excluded from
collateral.

## Limitations

Known and deliberate, so they are not mistaken for oversights.

- **USD is assumed at par.** The `USD` token is always treated as 1 USD. The protocol does not price it
  against fiat, haircut it, or model depeg risk. Not acceptable in production.
- **FX risk is per bucket.** An adverse CLP or ARS move can exhaust that bucket's 10% buffer, and v1
  handles shortfall with a redemption race (proportional burn) rather than a pause/queue/pro-rata
  waterfall. See [devaluation-risk.md](./devaluation-risk.md).
- **Cross-window FX exposure remains.** One rate per window plus two-way fees removes the *risk-free*
  intra-window round trip, but a holder keeping inventory across a rate change still gains or loses
  against the buffer — inherent to redeeming at an oracle rate. Per-bucket caps and a coverage breaker
  are the intended controls.
- **Netting is strictly per currency.** A party who is +100 CLP and −100 USD funds the USD leg in full
  and claims the CLP leg separately; no FX offset is applied. `NettingSession` has **no Oracle
  dependency** by design, so a frozen session's outcome cannot be changed by a rate post. A USD-numeraire
  mode would import oracle risk into the netting product, so it is deliberately not built.
- **`eliminated` is operator-attested.** References, dedupe and two-sided consent stop accidental and
  one-sided inflation, but two consenting addresses can still post offsetting rows.
- **Trust model is a single admin.** One key holds `DEFAULT_ADMIN_ROLE` across every contract plus the
  oracle owner, with no timelock on upgrades — and admin on a `SettlementToken` can grant itself
  `ENGINE_ROLE` and mint unbacked inventory. Splitting the roles and timelocking upgrades is open work
  (R1-M9).
- **The dApp still grants blanket allowances** for bucket mint/redeem. Settlement deposits approve only
  the exact amount needed; the mint/redeem paths do not yet (R1-M10).
- **Storage layout changed** in the R1 remediation. These are UUPS proxies, but `NettingSession` moved
  to session-keyed mappings, so an in-place upgrade over an older deployment would corrupt state.
  Deploy fresh.

## Reference

```text
nicofx/
  foundry.toml
  src/           USD, ProtocolHub, Oracle, SettlementToken, CurrencyBucket, NettingSession, Currency
  script/        Deploy.s.sol
  test/          CurrencyBucket, NettingSession, PricingAndReserves, Walkthrough
  app/           Vite + React dApp (FX Net)
  scripts/       oracle-feeder.mjs, sync-abis.sh
  reviews/       R<n>-<commit>.md critical reviews + README (citation convention)
```

| Document | What it covers |
|---|---|
| [walkthrough.md](./walkthrough.md) | Guided tour of the dApp: setup, happy path, failure paths |
| [reviews/](./reviews/) | Critical reviews and the `R1-<id>` citation convention |
| [devaluation-risk.md](./devaluation-risk.md) | FX shortfall policy: the race, and the options not taken |
| [ideation.md](./ideation.md) | Backlog, locked decisions, and what is still worth challenging |

**Tests** — `forge test` (100 tests). `forge test --list` is the authoritative index; broadly:

| File | Covers |
|---|---|
| `NettingSession.t.sol` | Consent, references, DVP lifecycle, failure and recovery, net caps, quarantine, escrow reporting, invariants, O(1) scaling |
| `CurrencyBucket.t.sol` | Allowlist/MRW/pause gating, mint headroom and the 110% floor, redeem fees, the shortfall race, cross-bucket isolation |
| `PricingAndReserves.t.sol` | Two-way pricing, one rate per window, the deviation bound, rate staleness, the reserve-withdrawal timelock and 115% floor |
| `Walkthrough.t.sol` | Every figure quoted in walkthrough.md, so the doc cannot drift |
