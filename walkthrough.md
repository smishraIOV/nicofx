# FX Net — self-guided walkthrough

A hands-on tour of the local dApp: set up inventory in **both** currencies, settle a multilateral
session delivery-versus-payment, then deliberately break things to see the safety rails.

This assumes you have already set up the local environment as described in the
[main readme](./readme.md#quick-start).

Numbers here are asserted by `test/Walkthrough.t.sol`, so they cannot drift from what the contracts do.

- [Setup — three terminals](#setup--three-terminals)
- [Happy path](#happy-path) (~10 min)
- [Failure paths](#failure-paths) (~10 min)
- [Utilities](#utilities)

---

## Setup — three terminals

### Terminal 1 — chain

```bash
anvil
```

Leave the default (no `--block-time`). Blocks then advance only when you transact, so the mint/redeem
window will not expire while you read. See [Utilities](#utilities) for mining blocks on demand.

### Terminal 2 — deploy

```bash
cd nicofx
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Writes `app/src/contracts/deployments.json`. Keep this terminal for `cast`.

The script sets: **mint fee 25 bps**, **redeem fee 50 bps** on both buckets, **settlement fee 50 bps**,
oracle **deviation bound 500 bps**, and allowlists accounts #2–#4.

### Terminal 3 — dApp

```bash
cd app && npm install && npm run dev
```

Open the printed URL. Switch identity with the **Anvil account** dropdown, top right.

> ### One trap worth knowing first
>
> The account labels are **off by one** from their numbers: `User1` is account **#2**, `User2` is
> account **#3**, `User3` is account **#4**.
>
> | Label | Account | Address |
> |---|---|---|
> | admin | #0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
> | oracle | #1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
> | User1 | #2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
> | User2 | #3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
> | User3 | #4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` |
>
> When minting USD, check the recipient shown **on the Mint button** before pressing it.

---

## Happy path

### 1. Open the window and post **both** rates

| Account | Tab | Action |
|---|---|---|
| **#0** | Admin | **Open MRW** |
| **#1** | Oracle | Post `clpPerUsd` = `950`, then post `arsPerUsd` = `1000` |

The Oracle tab has **two separate forms with two Post buttons** — one per currency. A currency with no
rate for the current window cannot be minted or redeemed, so post both now.

### 2. Fund **both** buckets

Each currency has its **own isolated USD vault**: depositing reserve into CLP does nothing for ARS.
The **Active bucket** switcher at the top of the page decides which bucket every Admin and User action
applies to.

| Account | Tab | Action |
|---|---|---|
| **#0** | Admin | Mint USD `1000000` to **yourself** (#0) |
| **#0** | Admin | Bucket = **CLP** → **Approve + deposit** reserve `100` |
| **#0** | Admin | Bucket = **ARS** → **Approve + deposit** reserve `100` |
| **#0** | Admin | Mint USD `10` to **User1 (#2)**, then `10` to **User2 (#3)** |

Use the allowlist picker's **`→ USD mint recipient`** button to fill the recipient, and confirm the
Mint button reads `Mint USD → 0x3C44…93BC` before sending.

### 3. Mint inventory in each currency

| Account | Tab | Action | Expect |
|---|---|---|---|
| **#2** | User | Bucket = **CLP** → **Approve + mint** `1` | **947.625 CLP** |
| **#3** | User | Bucket = **ARS** → **Approve + mint** `1` | **997.5 ARS** |

`1 × (1 − 0.0025) × 950 = 947.625`. The 25 bps mint fee is taken from the USD **before** conversion, so
the bucket books `0.0025 USD` of fee income and only the remainder becomes collateral.

### 4. Build the obligation book

A row is posted by one side and must be **acknowledged by the other** before it nets. Posting as a
party counts as your own consent. Work down this table — it is ordered to minimise account switching.

| # | Account | Tab | Action |
|---|---|---|---|
| 1 | **#0** | Settle | **Open session** |
| 2 | **#2** | Settle | Post `#2 → #3`, **CLP**, `100`, ref `clp-001` |
| 3 | **#3** | Settle | Post `#3 → #4`, **CLP**, `40`, ref `clp-002`<br>Post `#3 → #4`, **ARS**, `50`, ref `ars-001`<br>**Acknowledge** row `#0` |
| 4 | **#4** | Settle | Post `#4 → #2`, **CLP**, `10`, ref `clp-003`<br>**Acknowledge** rows `#1` and `#2` |
| 5 | **#2** | Settle | **Acknowledge** row `#3` |

Watch the header counter go **`Consented / pending 0 / 4` → `4 / 0`** as the acknowledgements land, and
each row's status flip from `awaiting creditor` to `netted`.

### 5. Freeze and read the matrix

**#0 → Freeze & net.** Phase becomes **Frozen**: nets are final, posting stops, and nothing is
discharged yet.

```
#2  −90 CLP   (dep 0/90.45)
#3  +60 CLP   −50 ARS  (dep 0/50.25)
#4  +30 CLP   +50 ARS

Escrow — CLP 0 of 90.45 required · short 90.45 · ARS 0 of 50.25 required · short 50.25
Eliminated — CLP 60 of 150 · ARS 0 of 50
Pairs 3
```

Two things to notice. The CLP triangle nets 150 gross down to 90 actually moving — that 60 is the
`eliminated` figure. And debtors owe **net + fee** (`90.45`, `50.25`), because the fee is charged to
the debtor so creditors are paid in full.

### 6. Fund — and watch the atomic lock

| Account | Action | Expect |
|---|---|---|
| **#2** | **Deposit 90.45 CLP** | CLP shows `(funded)`, **phase still Frozen** |
| **#3** | **Deposit 50.25 ARS** | phase flips to **Locked** by itself |

The gap between those two rows is the point of the design. After #2 funds, CLP is fully funded — but
claims stay shut because the ARS leg is short. If #3 tried to claim its 60 CLP there it would revert
`InvalidPhase`. Settlement is atomic across every currency in the session: **nothing is discharged
until everything is deliverable.** No admin action locks the session; the deposit that completes
funding does it in the same transaction.

Each deposit is **two transactions** — an exact-amount approve, then the deposit.

### 7. Claim at face value

| Account | Action | Expect |
|---|---|---|
| **#3** | Claim CLP | **60.0000 CLP** |
| **#4** | Claim CLP, then claim ARS | **30.0000 CLP**, **50.0000 ARS** |

Face value — not 59.7 and 29.85. The fees (`0.45 CLP`, `0.25 ARS`) came out of the debtors' deposits.
The session flips to **Settled** on the last claim, with no admin action.

---

## Failure paths

Each one is a rail, not a bug. Expected error in the right column.

### F1 — Close the MRW too early

**#0 → Admin → Close MRW**, straight after opening it.

```
MinWindowNotElapsed(58)
no hash — rejected before broadcast   [Copy error]
```

A window must stay open `minWindowBlocks` (50) before it can be closed early, so the operator cannot
manufacture a reserve-withdrawal window on demand. The argument is the block you can close from.

Note there is **no transaction hash**: the node rejected the call during gas estimation, so nothing was
ever broadcast. That is why the tx log says so explicitly and offers **Copy error** instead of Copy
hash. To proceed, mine the blocks (see [Utilities](#utilities)) — or just wait, since the window
auto-expires at `windowEndBlock` anyway, which opens the withdrawal window all the same.

### F2 — Post a rate twice in one window

**#1 → Oracle →** post `clpPerUsd` again.

```
RateAlreadySetForWindow
```

One rate per currency per window: the price you mint at is the price you redeem at inside that window.
Without it, an allowlisted party could mint at one rate, have the rate moved, and redeem at another for
a risk-free profit out of the operator's buffer. To re-rate: mine 50 blocks, Close MRW, Open MRW, post.

### F3 — Reuse an invoice reference

**#0 → Open session**, then **#2 →** post a row using ref `clp-001` again.

```
RefAlreadySettled
```

An invoice discharged by a session that locked can never be posted again. Reusing a ref **within** one
session gives `DuplicateRef`, and an empty ref gives `ZeroRef`. A ref *is* reusable if its session was
Cancelled or Failed, if the row was never acknowledged, or if you **Void** it — voiding frees the id so
a corrected row can take it.

### F4 — Freeze a book nobody agreed to

In a fresh session, post one row and **do not acknowledge it**. Then **#0 → Freeze & net**.

```
NoIncludedObligations
```

Unacknowledged rows count toward neither the nets nor `grossPosted`. An obligation asserted by one side
binds nobody.

### F5 — Take a deposit back (the DVP property)

In a session that is **Frozen** and still short, deposit, then press **Withdraw** on the same row.

The tokens come straight back and the phase stays Frozen. Nothing was discharged, so nothing is owed.
This is the difference between "funds are in escrow" and "the netting is binding".

### F6 — A debtor who cannot deliver

| # | Account | Action |
|---|---|---|
| 1 | **#0** | Open session |
| 2 | **#2** | Post `#2 → #3`, CLP, `10`, ref `f-001` |
| 3 | **#3** | Acknowledge row `#0`; post `#3 → #4`, CLP, `999999`, ref `f-002` |
| 4 | **#4** | Acknowledge row `#1` |
| 5 | **#0** | **Freeze & net** |
| 6 | **#2** | **Deposit 10.05 CLP** — funds its own leg |
| 7 | **#0** | **Declare failure** |
| 8 | **#2** | **Withdraw 10.05 CLP** — recovered in full |
| 9 | **#0** | **Open session** — works immediately |

#3 owes ~999,989 CLP and cannot pay. Before this was fixed, #2's deposit was trapped forever and the
contract could never open another session. Now: the session fails, every depositor pulls their tokens
back whole, no fee is charged on a failed session, and the next cycle starts normally.

Admin declared failure early here. Anyone at all can call it once the funding deadline (shown in the
Settle header) has passed — recovery never depends on the operator being available, and it works even
while the hub is paused.

### F7 — A de-listed creditor

During step 7 of the happy path, before #4 claims: **#0 → Admin → Allowlist →** remove **#4**. Then
**#4 → Claim**.

```
NotAllowlisted
```

The entitlement is not lost — re-list #4 and the claim goes through. Depositing is deliberately *not*
gated this way, because a party must always be able to meet what it owes.

### F8 — Reserve withdrawal is timelocked

Mine 50 blocks, **Close MRW**, then **Admin → Request withdrawal** and press **Execute** immediately.

```
WithdrawalNotExecutable(<block>)
```

Requests mature after 25 blocks, must still be inside the withdrawal window, need a fresh rate, and
must leave 115% coverage — stricter than the 110% mint floor. The panel shows the executable-from
block. Mine 25 and Execute.

---

## Utilities

**Mine blocks** (default Anvil only advances on transactions):

```bash
cast rpc --rpc-url http://127.0.0.1:8545 anvil_mine 0x32   # 50 blocks
```

**Five admin setters have no UI form yet** — use `cast` (key below is Anvil #0):

```bash
D=app/src/contracts/deployments.json
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
R=http://127.0.0.1:8545
send() { cast send --rpc-url $R --private-key $K0 "$@"; }

# shorten the minimum MRW length for local poking (1..windowDurationBlocks)
send $(jq -r .hub $D) 'setMinWindowBlocks(uint256)' 1

# stop rates going stale during a long session (default 1 hour)
send $(jq -r .buckets.clp.engine $D) 'setMaxRateAge(uint256)' 604800
send $(jq -r .buckets.ars.engine $D) 'setMaxRateAge(uint256)' 604800

# cap a party's absolute net per currency (0 = unlimited); 0 = CLP, 1 = ARS, 2 = USD
send $(jq -r .settlement $D) 'setMaxNet(address,uint8,uint256)' \
  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0 50000000000000000000

# quarantine destination, and sweeping a de-listed party's claim to it
send $(jq -r .settlement $D) 'setQuarantineAddress(address)' 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
send $(jq -r .settlement $D) 'sweepQuarantined(uint256,address,uint8)' 1 \
  0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0
```

**Inspect state** without the UI:

```bash
S=$(jq -r .settlement app/src/contracts/deployments.json)
cast call --rpc-url $R $S 'phase()(uint8)'                       # 0 Idle 1 Open 2 Frozen 3 Locked 4 Settled 5 Cancelled 6 Failed
cast call --rpc-url $R $S 'netOf(uint256,address,uint8)(int256)' 1 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0
cast call --rpc-url $R $S 'fundingShortfall(uint256,uint8)(uint256)' 1 0
```

**Start over:** restart Anvil and re-run the deploy script. Refresh the dApp afterwards.

---

Design rationale for the rails above is in [reviews/R1-cb95b96.md](./reviews/R1-cb95b96.md) — F1 is
R1-M1, F2 is R1-C2, F3 is R1-H1, F4 is R1-H2, F5/F6 are R1-C1, F7 is R1-M2, F8 is R1-M1 and R1-H5. The
face-value claims in step 7 are R1-M4.
