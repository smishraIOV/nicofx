import { useState, type FormEvent, type ReactNode } from 'react'
import { type Address, formatEther, isAddress } from 'viem'
import { bucketLabel, deployments, PHASE, PHASE_LABELS, type SettlementCurrency } from './contracts'
import { bytes32ToRef, useProtocol, type TransferToken } from './useProtocol'
import { ANVIL_ACCOUNTS } from './wagmi'
import { useWallet } from './wallet'

function short(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    // ignore clipboard failures in non-secure contexts
  }
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
    </label>
  )
}

function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="panel">
      <h2>{title}</h2>
      <div className="panel-body">{children}</div>
    </section>
  )
}

function BucketSwitcher() {
  const { activeBucket, setActiveBucket, bucketIds } = useProtocol()
  return (
    <div className="bucket-switcher" role="group" aria-label="Currency bucket">
      {bucketIds.map((id) => (
        <button
          key={id}
          type="button"
          className={activeBucket === id ? 'active' : ''}
          onClick={() => setActiveBucket(id)}
        >
          {bucketLabel(id)}
        </button>
      ))}
    </div>
  )
}

function StatusBar() {
  const { state, activeBucket, active, formatEth, rateValid } = useProtocol()
  const rate =
    active.ratePerUsd === 0n ? '—' : Number(formatEther(active.ratePerUsd)).toFixed(4)

  const rateCell = (id: 'clp' | 'ars') => {
    const b = state.buckets[id]
    if (b.ratePerUsd === 0n) return 'unset'
    return `${Number(formatEther(b.ratePerUsd)).toFixed(2)}${rateValid(id) ? '' : ' (stale)'}`
  }

  return (
    <div className="status-bar">
      <div className={`pill ${state.windowOpen ? 'on' : 'off'}`}>
        MRW {state.windowOpen ? 'open' : 'closed'}
      </div>
      <div className={`pill ${state.paused ? 'warn' : 'ok'}`}>
        {state.paused ? 'paused' : 'running'}
      </div>
      <div className="stat">
        <span>MRW left</span>
        <strong>
          {state.windowOpen ? `${state.windowBlocksRemaining.toString()} blk` : '—'}
        </strong>
      </div>
      <div className="stat">
        <span>CLP rate</span>
        <strong className={rateValid('clp') ? '' : 'stale'}>{rateCell('clp')}</strong>
      </div>
      <div className="stat">
        <span>ARS rate</span>
        <strong className={rateValid('ars') ? '' : 'stale'}>{rateCell('ars')}</strong>
      </div>
      <div className="stat">
        <span>{bucketLabel(activeBucket)} headroom</span>
        <strong>{formatEth(active.mintHeadroomUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>{bucketLabel(activeBucket)} collateral</span>
        <strong>{formatEth(active.collateralUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>{bucketLabel(activeBucket)} liability</span>
        <strong>{formatEth(active.liabilityUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>{bucketLabel(activeBucket)} fees</span>
        <strong>{formatEth(active.accruedFees)} USD</strong>
      </div>
      <div className="stat">
        <span>Active rate</span>
        <strong>
          {rate} {bucketLabel(activeBucket)}/USD
        </strong>
      </div>
      <div className="stat">
        <span>Withdraw win</span>
        <strong>
          {state.withdrawalWindowActive
            ? `${state.withdrawalBlocksRemaining.toString()} blk left`
            : 'inactive'}
        </strong>
      </div>
    </div>
  )
}

function TxStrip() {
  const { txs, clearTxs, busy } = useProtocol()

  return (
    <section className="tx-strip">
      <div className="tx-strip-head">
        <h2>Transactions</h2>
        <div className="tx-strip-actions">
          {busy && <span className="busy-inline">sending…</span>}
          <button type="button" className="ghost-sm" onClick={clearTxs} disabled={txs.length === 0}>
            Clear
          </button>
        </div>
      </div>
      {txs.length === 0 ? (
        <p className="hint">No transactions yet. Successes and reverts show up here.</p>
      ) : (
        <ul className="tx-list">
          {txs.map((tx) => (
            <li key={tx.id} className={`tx-item ${tx.status}`}>
              <div className="tx-main">
                <span className="tx-status">{tx.status}</span>
                <strong>{tx.label}</strong>
                <span className="tx-time">{new Date(tx.at).toLocaleTimeString()}</span>
              </div>
              <div className="tx-detail">{tx.detail}</div>
              {tx.hash ? (
                <div className="tx-hash-row">
                  <code className="tx-hash" title={tx.hash}>
                    {tx.hash.slice(0, 10)}…{tx.hash.slice(-8)}
                  </code>
                  <button
                    type="button"
                    className="ghost-sm"
                    onClick={() => void copyText(tx.hash!)}
                  >
                    Copy hash
                  </button>
                  {tx.status === 'fail' && (
                    <button
                      type="button"
                      className="ghost-sm"
                      onClick={() => void copyText(`${tx.label}: ${tx.detail}`)}
                    >
                      Copy error
                    </button>
                  )}
                </div>
              ) : (
                tx.status === 'fail' && (
                  <div className="tx-hash-row">
                    {/* No hash exists: the call reverted in pre-flight simulation, so nothing was
                        broadcast. Say so rather than leaving a blank where the hash would be. */}
                    <code className="tx-hash" title="Rejected before broadcast — no transaction was submitted, so there is no hash to inspect">
                      no hash — rejected before broadcast
                    </code>
                    <button
                      type="button"
                      className="ghost-sm"
                      onClick={() => void copyText(`${tx.label}: ${tx.detail}`)}
                    >
                      Copy error
                    </button>
                  </div>
                )
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function AllowlistList({
  onPick,
}: {
  onPick?: (addr: Address) => void
}) {
  const { state } = useProtocol()
  const accounts = state.allowlistedAccounts

  if (accounts.length === 0) {
    return <p className="hint">No allowlisted accounts yet.</p>
  }

  return (
    <ul className="allowlist">
      {accounts.map((addr) => {
        const meta = ANVIL_ACCOUNTS.find(
          (a) => a.address.toLowerCase() === addr.toLowerCase(),
        )
        return (
          <li key={addr}>
            <span>
              {meta ? `#${meta.index} ${meta.label}` : 'allowlisted'}
            </span>
            <code title={addr}>{short(addr)}</code>
            <div className="allowlist-actions">
              <button type="button" className="ghost-sm" onClick={() => void copyText(addr)}>
                Copy
              </button>
              {onPick && (
                <button type="button" className="ghost-sm" onClick={() => onPick(addr)}>
                  Use
                </button>
              )}
            </div>
          </li>
        )
      })}
    </ul>
  )
}

function ReserveWithdrawalStatus() {
  const p = useProtocol()
  const b = p.active
  if (b.pendingWithdrawalAmount === 0n) {
    return (
      <p className="hint">
        Reserve withdrawals are announced, then executable after{' '}
        {b.withdrawalDelayBlocks.toString()} blocks, and only while the post-MRW window is active.
        Withdrawable now: {formatEther(b.withdrawableReserveUsd)} USD (floor is 115%, above the 110%
        mint floor).
      </p>
    )
  }
  const executableFrom = b.pendingWithdrawalBlock + b.withdrawalDelayBlocks
  const ready = p.state.blockNumber >= executableFrom
  return (
    <div className="allowlist-box">
      <h3>Pending reserve withdrawal</h3>
      <p className="hint">
        {formatEther(b.pendingWithdrawalAmount)} USD · executable from block{' '}
        {executableFrom.toString()} (now {p.state.blockNumber.toString()}){ready ? ' — ready' : ''}
      </p>
      <div className="actions">
        <button
          type="button"
          disabled={p.busy || !ready}
          onClick={() => void p.executeReserveWithdrawal()}
        >
          Execute
        </button>
        <button type="button" disabled={p.busy} onClick={() => void p.cancelReserveWithdrawal()}>
          Cancel
        </button>
      </div>
    </div>
  )
}

function AdminPanel() {
  const p = useProtocol()
  const { address } = useWallet()
  const [mintTo, setMintTo] = useState<string>(address)
  const [mintAmt, setMintAmt] = useState('1000')
  const [reserveAmt, setReserveAmt] = useState('100')
  const [mintFeeBps, setMintFeeBps] = useState(String(p.active.mintFeeBps || 25))
  const [redeemFeeBps, setRedeemFeeBps] = useState(String(p.active.redeemFeeBps || 50))
  const [allowAddr, setAllowAddr] = useState<string>(ANVIL_ACCOUNTS[2].address)
  // Which field the allowlist picker writes to. `mintTo` is seeded from the connected account and
  // does not follow account switches, so without a visible target it silently mints to whoever
  // was connected when this panel mounted.
  const [adminPicking, setAdminPicking] = useState<'mintTo' | 'allowlist'>('allowlist')
  const [feeWithdraw, setFeeWithdraw] = useState('1')
  const [settlementFeeBps, setSettlementFeeBps] = useState(String(p.state.settlement.nextFeeBps || 50))
  const [fundingWindow, setFundingWindow] = useState(String(p.state.settlement.fundingWindowBlocks || 200n))
  const [settlementFeeCcy, setSettlementFeeCcy] = useState<SettlementCurrency>('clp')
  const [settlementFeeWithdraw, setSettlementFeeWithdraw] = useState('1')

  return (
    <Panel title="Admin">
      <BucketSwitcher />

      <div className="actions">
        <button type="button" disabled={p.busy} onClick={() => void p.openWindow()}>
          Open MRW
        </button>
        <button type="button" disabled={p.busy} onClick={() => void p.closeWindow()}>
          Close MRW
        </button>
        <button type="button" disabled={p.busy} onClick={() => void p.pause()}>
          Pause
        </button>
        <button type="button" disabled={p.busy} onClick={() => void p.unpause()}>
          Unpause
        </button>
      </div>
      <p className="hint">MRW and pause are shared across CLP and ARS. Reserves and fees are per bucket.</p>

      <div className="allowlist-box">
        <h3>
          Allowlist{' '}
          <button
            type="button"
            className="ghost-sm"
            onClick={() => setAdminPicking('allowlist')}
          >
            → allowlist target
          </button>{' '}
          <button type="button" className="ghost-sm" onClick={() => setAdminPicking('mintTo')}>
            → USD mint recipient
          </button>
          <span className="hint"> (Use writes to: {adminPicking === 'mintTo' ? 'mint recipient' : 'allowlist target'})</span>
        </h3>
        <AllowlistList
          onPick={(addr) => (adminPicking === 'mintTo' ? setMintTo(addr) : setAllowAddr(addr))}
        />
      </div>

      <form
        className="form-row"
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          if (!isAddress(mintTo)) return
          void p.mintUsd(mintTo as Address, mintAmt)
        }}
      >
        <Field
          label={`Mint USD to${
            mintTo.toLowerCase() === address.toLowerCase() ? ' (this is YOUR own account)' : ''
          }`}
        >
          <input value={mintTo} onChange={(e) => setMintTo(e.target.value)} />
        </Field>
        <Field label="Amount">
          <input value={mintAmt} onChange={(e) => setMintAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy || !isAddress(mintTo)}>
          Mint USD → {isAddress(mintTo) ? short(mintTo) : 'invalid address'}
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.approveUsdMax().then(() => p.depositReserve(reserveAmt))
        }}
      >
        <Field label={`Deposit ${bucketLabel(p.activeBucket)} reserve (USD)`}>
          <input value={reserveAmt} onChange={(e) => setReserveAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Approve + deposit
        </button>
        <button
          type="button"
          disabled={p.busy}
          onClick={() => void p.requestReserveWithdrawal(reserveAmt)}
        >
          Request withdrawal
        </button>
      </form>
      <ReserveWithdrawalStatus />

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setMintFeeBps(Number(mintFeeBps))
        }}
      >
        <Field label={`${bucketLabel(p.activeBucket)} mint fee (bps)`}>
          <input value={mintFeeBps} onChange={(e) => setMintFeeBps(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Set mint fee
        </button>
      </form>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setRedeemFeeBps(Number(redeemFeeBps))
        }}
      >
        <Field label={`${bucketLabel(p.activeBucket)} redeem fee (bps)`}>
          <input value={redeemFeeBps} onChange={(e) => setRedeemFeeBps(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Set redeem fee
        </button>
      </form>
      <p className="hint">
        Charging both directions is what stops a mint/redeem round trip from being free against the
        operator&apos;s buffer. A round trip costs mint + redeem fee.
      </p>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setSettlementFundingWindow(fundingWindow)
        }}
      >
        <Field label="Settlement funding window (blocks)">
          <input value={fundingWindow} onChange={(e) => setFundingWindow(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Set funding window
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.withdrawFees(feeWithdraw)
        }}
      >
        <Field label={`Withdraw ${bucketLabel(p.activeBucket)} fees (USD)`}>
          <input value={feeWithdraw} onChange={(e) => setFeeWithdraw(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Withdraw fees
        </button>
      </form>

      <p className="hint">
        Settlement receipt fee haircuts net claims (not funds). Accrued in the session contract, not
        bucket collateral. Equal cycles with nothing to claim are free.
      </p>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setSettlementFeeBps(Number(settlementFeeBps))
        }}
      >
        <Field label="Settlement receipt fee (bps)">
          <input
            value={settlementFeeBps}
            onChange={(e) => setSettlementFeeBps(e.target.value)}
          />
        </Field>
        <button type="submit" disabled={p.busy}>
          Set settlement fee
        </button>
      </form>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.withdrawSettlementFees(settlementFeeCcy, settlementFeeWithdraw)
        }}
      >
        <Field label="Withdraw settlement fees">
          <select
            value={settlementFeeCcy}
            onChange={(e) => setSettlementFeeCcy(e.target.value as SettlementCurrency)}
          >
            <option value="clp">CLP</option>
            <option value="ars">ARS</option>
            <option value="usd">USD</option>
          </select>
        </Field>
        <Field label={`Amount (${formatEther(p.state.settlement.accruedFees[settlementFeeCcy])} accrued)`}>
          <input
            value={settlementFeeWithdraw}
            onChange={(e) => setSettlementFeeWithdraw(e.target.value)}
          />
        </Field>
        <button type="submit" disabled={p.busy}>
          Withdraw
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          if (!isAddress(allowAddr)) return
          void p.setAllowlist(allowAddr as Address, true)
        }}
      >
        <Field label="Allowlist address">
          <input value={allowAddr} onChange={(e) => setAllowAddr(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Allow
        </button>
        <button
          type="button"
          disabled={p.busy}
          onClick={() => {
            if (!isAddress(allowAddr)) return
            void p.setAllowlist(allowAddr as Address, false)
          }}
        >
          Remove
        </button>
        <button
          type="button"
          className="ghost-sm"
          onClick={() => void copyText(allowAddr)}
          disabled={!isAddress(allowAddr)}
        >
          Copy
        </button>
      </form>
    </Panel>
  )
}

function OraclePanel() {
  const p = useProtocol()
  const [clpRate, setClpRate] = useState('950')
  const [arsRate, setArsRate] = useState('1500')
  const [deviationBps, setDeviationBps] = useState(String(p.state.oracleMaxDeviationBps || 500))
  const { address } = useWallet()
  const canPost = p.state.windowOpen && !p.state.paused
  const isOwner = p.state.oracleOwner.toLowerCase() === address.toLowerCase()
  const bound = p.state.oracleMaxDeviationBps

  return (
    <Panel title="Oracle">
      <p className="hint">
        Shared oracle. CLP:{' '}
        <strong>
          {p.state.buckets.clp.ratePerUsd === 0n
            ? 'unset'
            : `${formatEther(p.state.buckets.clp.ratePerUsd)}`}
        </strong>
        {' · '}
        ARS:{' '}
        <strong>
          {p.state.buckets.ars.ratePerUsd === 0n
            ? 'unset'
            : `${formatEther(p.state.buckets.ars.ratePerUsd)}`}
        </strong>
        . Hub window nonce {p.state.windowNonce.toString()}.
      </p>
      <p className="hint">
        Valid for this window — CLP:{' '}
        <strong className={p.rateValid('clp') ? '' : 'stale'}>
          {p.rateValid('clp') ? 'yes' : 'no'}
        </strong>
        {' · '}
        ARS:{' '}
        <strong className={p.rateValid('ars') ? '' : 'stale'}>
          {p.rateValid('ars') ? 'yes' : 'no'}
        </strong>
        . Each new window requires fresh rates before mint/redeem.
      </p>
      <p className="hint">
        Deviation bound:{' '}
        <strong>{bound === 0 ? 'disabled' : `${bound} bps (±${bound / 100}%)`}</strong> from the previous
        rate, both currencies. The first post per currency is unbounded.
      </p>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setRate('clp', clpRate)
        }}
      >
        <Field label="clpPerUsd">
          <input value={clpRate} onChange={(e) => setClpRate(e.target.value)} disabled={!canPost} />
        </Field>
        <button type="submit" disabled={p.busy || !canPost}>
          Post CLP rate
        </button>
        {isOwner && (
          <button
            type="button"
            disabled={p.busy || !canPost}
            onClick={() => void p.forceSetRate('clp', clpRate)}
          >
            Force
          </button>
        )}
      </form>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setRate('ars', arsRate)
        }}
      >
        <Field label="arsPerUsd">
          <input value={arsRate} onChange={(e) => setArsRate(e.target.value)} disabled={!canPost} />
        </Field>
        <button type="submit" disabled={p.busy || !canPost}>
          Post ARS rate
        </button>
        {isOwner && (
          <button
            type="button"
            disabled={p.busy || !canPost}
            onClick={() => void p.forceSetRate('ars', arsRate)}
          >
            Force
          </button>
        )}
      </form>
      {!canPost && (
        <p className="hint warn-text">Posting requires MRW open and hub not paused.</p>
      )}
      {isOwner && (
        <>
          <form
            className="form-row"
            onSubmit={(e) => {
              e.preventDefault()
              void p.setMaxDeviationBps(Number(deviationBps))
            }}
          >
            <Field label="maxDeviationBps">
              <input value={deviationBps} onChange={(e) => setDeviationBps(e.target.value)} />
            </Field>
            <button type="submit" disabled={p.busy}>
              Set bound
            </button>
          </form>
          <p className="hint">
            Owner only. The bound applies to CLP and ARS; max 5000 (50%), 0 disables it. Force posts a
            rate past the bound (still one post per window) and emits RateForced.
          </p>
        </>
      )}
    </Panel>
  )
}

function UserPanel() {
  const p = useProtocol()
  const [mintAmt, setMintAmt] = useState('100')
  const [redeemAmt, setRedeemAmt] = useState('100')
  const [transferToken, setTransferToken] = useState<TransferToken>('usd')
  const [transferTo, setTransferTo] = useState('')
  const [transferAmt, setTransferAmt] = useState('10')
  const symbol = bucketLabel(p.activeBucket)
  const canTrade = p.state.allowlisted && p.state.windowOpen && p.activeRateValid

  return (
    <Panel title="User">
      <BucketSwitcher />

      <div className="balances">
        <div>
          <span>USD</span>
          <strong>{formatEther(p.state.usdBalance)}</strong>
        </div>
        <div>
          <span>CLP</span>
          <strong>{formatEther(p.state.buckets.clp.tokenBalance)}</strong>
        </div>
        <div>
          <span>ARS</span>
          <strong>{formatEther(p.state.buckets.ars.tokenBalance)}</strong>
        </div>
        <div>
          <span>Allowlisted</span>
          <strong>{p.state.allowlisted ? 'yes' : 'no'}</strong>
        </div>
      </div>

      <p className="hint">
        USD / CLP / ARS balances are <strong>settlement inventory</strong>. Mint/redeem funds
        inventory; multilateral netting lives on the <strong>Settle</strong> tab.
      </p>

      {!p.state.allowlisted && (
        <p className="hint warn-text">This account is not allowlisted — mint/redeem will revert.</p>
      )}
      {!p.state.windowOpen && (
        <p className="hint warn-text">MRW is closed — Admin must open a window.</p>
      )}
      {p.state.windowOpen && !p.activeRateValid && (
        <p className="hint warn-text">
          No {symbol} rate posted for the current window. Switch to <strong>#1 Oracle</strong> and
          post a {symbol} rate, or run the feeder.
        </p>
      )}

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.approveUsdMax().then(() => p.mint(mintAmt))
        }}
      >
        <Field label={`Mint ${symbol} (USD in)`}>
          <input value={mintAmt} onChange={(e) => setMintAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy || !canTrade}>
          Approve + mint
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.approveTokenMax().then(() => p.redeem(redeemAmt))
        }}
      >
        <Field label={`Redeem ${symbol}`}>
          <input value={redeemAmt} onChange={(e) => setRedeemAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy || !canTrade}>
          Approve + redeem
        </button>
      </form>

      <div className="transfer-box">
        <h3>Transfer</h3>
        <p className="hint">Send USD, CLP, or ARS to any address. Allowlist is not required.</p>
        <form
          className="form-row"
          onSubmit={(e) => {
            e.preventDefault()
            if (!isAddress(transferTo)) return
            void p.transfer(transferToken, transferTo as Address, transferAmt)
          }}
        >
          <Field label="Token">
            <select
              value={transferToken}
              onChange={(e) => setTransferToken(e.target.value as TransferToken)}
            >
              <option value="usd">USD</option>
              <option value="clp">CLP</option>
              <option value="ars">ARS</option>
            </select>
          </Field>
          <Field label="To">
            <input value={transferTo} onChange={(e) => setTransferTo(e.target.value)} />
          </Field>
          <Field label="Amount">
            <input value={transferAmt} onChange={(e) => setTransferAmt(e.target.value)} />
          </Field>
          <button type="submit" disabled={p.busy || !isAddress(transferTo)}>
            Transfer
          </button>
        </form>
        <div className="allowlist-box">
          <h3>Pick from allowlist</h3>
          <AllowlistList onPick={(addr) => setTransferTo(addr)} />
        </div>
      </div>
    </Panel>
  )
}

function currencyName(id: number): string {
  if (id === 0) return 'CLP'
  if (id === 1) return 'ARS'
  if (id === 2) return 'USD'
  return `cur${id}`
}

function bpsFee(amount: bigint, bps: number): bigint {
  return (amount * BigInt(bps)) / 10_000n
}

function formatSigned(n: bigint): string {
  const abs = n < 0n ? -n : n
  const s = formatEther(abs)
  if (n < 0n) return `−${s}`
  if (n > 0n) return `+${s}`
  return '0'
}

function SettlePanel() {
  const p = useProtocol()
  const { address } = useWallet()
  const s = p.state.settlement
  const phaseLabel = PHASE_LABELS[s.phase] ?? String(s.phase)

  const [debtor, setDebtor] = useState<string>(address)
  const [creditor, setCreditor] = useState<string>(ANVIL_ACCOUNTS[3]?.address ?? '')
  const [currency, setCurrency] = useState<SettlementCurrency>('clp')
  const [amount, setAmount] = useState('10')
  const [ref, setRef] = useState('inv-001')
  const [picking, setPicking] = useState<'debtor' | 'creditor' | null>(null)

  const myNets = s.partyNets.find((row) => row.party.toLowerCase() === address.toLowerCase())

  if (!p.hasSettlement) {
    return (
      <Panel title="Settle">
        <p className="hint warn-text">
          NettingSession not in deployments — redeploy with the latest script.
        </p>
      </Panel>
    )
  }

  return (
    <Panel title="Settle">
      <p className="hint">
        Multilateral obligation book, settled delivery-versus-payment. Post an obligation → the
        counterparty acknowledges it → admin freezes the book → debtors deposit → the session locks
        automatically once every currency is fully funded, and only then are obligations discharged
        and claims opened.
      </p>
      <p className="hint">
        While <strong>Frozen</strong> nothing is discharged, so a deposit can be withdrawn at any
        time. If the funding deadline passes while a currency is short, anyone may declare failure
        and every depositor pulls their tokens back. Debtors fund <em>net + fee</em> so creditors are
        paid their net at face value. Sessions are kept forever, so past claims and refunds stay
        available after a new session opens.
      </p>

      <div className="balances">
        <div>
          <span>Session</span>
          <strong>#{s.sessionId.toString()}</strong>
        </div>
        <div>
          <span>Phase</span>
          <strong>{phaseLabel}</strong>
        </div>
        <div>
          <span>Obligations</span>
          <strong>{s.obligations.length}</strong>
        </div>
        <div>
          <span>Parties</span>
          <strong>{s.participants.length}</strong>
        </div>
        <div>
          <span>Consented / pending</span>
          <strong>
            {s.includedCount.toString()} / {s.pendingAckCount.toString()}
          </strong>
        </div>
        <div>
          <span>Pairs</span>
          <strong>{s.counterpartyPairs.toString()}</strong>
        </div>
        <div>
          <span>Receipt fee</span>
          <strong>{s.sessionFeeBps} bps</strong>
        </div>
        {s.fundingDeadline > 0n && (
          <div>
            <span>Funding deadline</span>
            <strong>
              block {s.fundingDeadline.toString()}
              {p.state.blockNumber > s.fundingDeadline ? ' (passed)' : ''}
            </strong>
          </div>
        )}
      </div>

      <div className="actions">
        <button
          type="button"
          disabled={p.busy || p.state.paused}
          onClick={() => void p.openSettlementSession()}
        >
          Open session
        </button>
        <button
          type="button"
          disabled={p.busy || p.state.paused || s.phase !== PHASE.Open}
          onClick={() => void p.freezeSettlementSession()}
        >
          Freeze &amp; net
        </button>
        <button
          type="button"
          disabled={p.busy || (s.phase !== PHASE.Open && s.phase !== PHASE.Frozen)}
          onClick={() => void p.cancelSettlementSession()}
        >
          Cancel
        </button>
        <button
          type="button"
          disabled={p.busy || s.phase !== PHASE.Frozen}
          onClick={() => void p.declareSettlementFailure(s.sessionId)}
        >
          Declare failure
        </button>
      </div>

      {s.phase === PHASE.Open && (
        <>
          <form
            className="form-row"
            onSubmit={(e) => {
              e.preventDefault()
              if (!isAddress(debtor) || !isAddress(creditor)) return
              void p.postObligation(debtor as Address, creditor as Address, currency, amount, ref)
            }}
          >
            <Field label="Debtor">
              <input value={debtor} onChange={(e) => setDebtor(e.target.value)} />
            </Field>
            <Field label="Creditor">
              <input value={creditor} onChange={(e) => setCreditor(e.target.value)} />
            </Field>
            <Field label="Currency">
              <select
                value={currency}
                onChange={(e) => setCurrency(e.target.value as SettlementCurrency)}
              >
                <option value="clp">CLP</option>
                <option value="ars">ARS</option>
                <option value="usd">USD</option>
              </select>
            </Field>
            <Field label="Amount">
              <input value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
            <Field label="Reference (invoice id)">
              <input value={ref} onChange={(e) => setRef(e.target.value)} />
            </Field>
            <button
              type="submit"
              disabled={
                p.busy || p.state.paused || !isAddress(debtor) || !isAddress(creditor) || !ref
              }
            >
              Post obligation
            </button>
          </form>
          <p className="hint">
            The reference must be unique within the session, and an invoice already discharged by a
            locked session cannot be posted again. Posting as a party counts as your consent; the
            counterparty still has to acknowledge before the row nets.
          </p>
          <div className="allowlist-box">
            <h3>
              Pick from allowlist{' '}
              <button type="button" className="ghost-sm" onClick={() => setPicking('debtor')}>
                → debtor
              </button>{' '}
              <button type="button" className="ghost-sm" onClick={() => setPicking('creditor')}>
                → creditor
              </button>
              {picking && <span className="hint"> (click Use for {picking})</span>}
            </h3>
            <AllowlistList
              onPick={(addr) => {
                if (picking === 'creditor') setCreditor(addr)
                else setDebtor(addr)
                setPicking(null)
              }}
            />
          </div>
        </>
      )}

      <div className="allowlist-box">
        <h3>Obligation book</h3>
        {s.obligations.length === 0 ? (
          <p className="hint">No obligations in this session.</p>
        ) : (
          <ul className="allowlist obligation-list">
            {s.obligations.map((o) => {
              const me = address.toLowerCase()
              const iAmDebtor = o.debtor.toLowerCase() === me
              const iAmCreditor = o.creditor.toLowerCase() === me
              const myAckMissing =
                (iAmDebtor && !o.debtorAck) || (iAmCreditor && !o.creditorAck)
              const status = o.voided
                ? 'voided'
                : o.included
                  ? 'netted'
                  : `awaiting ${!o.debtorAck ? 'debtor' : ''}${!o.debtorAck && !o.creditorAck ? ' + ' : ''}${!o.creditorAck ? 'creditor' : ''}`
              return (
                <li key={`${o.index}-${o.ref}`}>
                  <span>#{o.index}</span>
                  <code>
                    {short(o.debtor)} → {short(o.creditor)} · {formatEther(o.amount)}{' '}
                    {currencyName(o.currency)} · {bytes32ToRef(o.ref)} · {status}
                  </code>
                  {s.phase === PHASE.Open && !o.voided && (
                    <span>
                      {myAckMissing && (
                        <button
                          type="button"
                          className="ghost-sm"
                          disabled={p.busy || p.state.paused}
                          onClick={() => void p.acknowledgeObligations([o.index])}
                        >
                          Acknowledge
                        </button>
                      )}{' '}
                      {(iAmDebtor || iAmCreditor) && (
                        <button
                          type="button"
                          className="ghost-sm"
                          disabled={p.busy || p.state.paused}
                          onClick={() => void p.voidObligation(o.index)}
                        >
                          Void
                        </button>
                      )}
                    </span>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </div>

      {s.phase >= PHASE.Frozen && s.phase !== PHASE.Cancelled && (
        <>
          <div className="allowlist-box">
            <h3>Net matrix (nets are final once frozen)</h3>
            <div className="net-table-wrap">
              <table className="net-table">
                <thead>
                  <tr>
                    <th>Party</th>
                    <th>CLP</th>
                    <th>ARS</th>
                    <th>USD</th>
                  </tr>
                </thead>
                <tbody>
                  {s.partyNets.map((row) => (
                    <tr
                      key={row.party}
                      className={
                        row.party.toLowerCase() === address.toLowerCase() ? 'me' : undefined
                      }
                    >
                      <td>
                        <code title={row.party}>{short(row.party)}</code>
                      </td>
                      {(['clp', 'ars', 'usd'] as SettlementCurrency[]).map((c) => (
                        <td key={c} className={row.nets[c] < 0n ? 'debt' : row.nets[c] > 0n ? 'credit' : ''}>
                          {formatSigned(row.nets[c])}
                          {row.required[c] > 0n
                            ? ` (dep ${formatEther(row.deposited[c])}/${formatEther(row.required[c])})`
                            : ''}
                          {row.claimed[c] ? ' ✓c' : ''}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="hint">
              Escrow (owed to creditors, excludes fee income) —{' '}
              {(['clp', 'ars', 'usd'] as SettlementCurrency[])
                .map(
                  (c) =>
                    `${bucketLabel(c)} ${formatEther(s.escrow[c])} of ${formatEther(
                      s.totalRequired[c],
                    )} required${s.fullyFunded[c] ? ' (funded)' : ` · short ${formatEther(s.shortfall[c])}`}`,
                )
                .join(' · ')}
            </p>
            <p className="hint">
              Eliminated (gross − residual, not billed) — CLP {formatEther(s.eliminated.clp)} of{' '}
              {formatEther(s.grossPosted.clp)} · ARS {formatEther(s.eliminated.ars)} of{' '}
              {formatEther(s.grossPosted.ars)} · USD {formatEther(s.eliminated.usd)} of{' '}
              {formatEther(s.grossPosted.usd)}. Read this next to {s.participants.length} parties
              and {s.counterpartyPairs.toString()} distinct pairs — consenting parties can post
              offsetting rows, so it is an operator-attested metric, not a trustless one.
            </p>
          </div>

          {myNets && (
            <div className="actions">
              {(['clp', 'ars', 'usd'] as SettlementCurrency[]).map((c) => {
                const net = myNets.nets[c]
                const out = []

                // Deposit toward your requirement while the book is frozen
                if (s.phase === PHASE.Frozen && myNets.outstanding[c] > 0n) {
                  const owed = myNets.outstanding[c]
                  out.push(
                    <button
                      key={`deposit-${c}`}
                      type="button"
                      disabled={p.busy || p.state.paused}
                      onClick={() => void p.depositSettlement(c, formatEther(owed))}
                    >
                      Deposit {formatEther(owed)} {bucketLabel(c)}
                      {bpsFee(net < 0n ? -net : 0n, s.sessionFeeBps) > 0n
                        ? ` (incl. ${formatEther(bpsFee(-net, s.sessionFeeBps))} fee)`
                        : ''}
                    </button>,
                  )
                }

                // Pull a deposit back: free while Frozen, and the recovery path once failed
                if (
                  (s.phase === PHASE.Frozen ||
                    s.phase === PHASE.Cancelled ||
                    s.phase === PHASE.Failed) &&
                  myNets.deposited[c] > 0n
                ) {
                  out.push(
                    <button
                      key={`withdraw-${c}`}
                      type="button"
                      disabled={p.busy}
                      onClick={() => void p.withdrawSettlementDeposit(s.sessionId, c)}
                    >
                      Withdraw {formatEther(myNets.deposited[c])} {bucketLabel(c)}
                    </button>,
                  )
                }

                // Claim your net at face value once the session has locked
                if (
                  (s.phase === PHASE.Locked || s.phase === PHASE.Settled) &&
                  net > 0n &&
                  !myNets.claimed[c]
                ) {
                  out.push(
                    <button
                      key={`claim-${c}`}
                      type="button"
                      disabled={p.busy || p.state.paused}
                      onClick={() => void p.claimSettlement(s.sessionId, c)}
                    >
                      Claim {formatEther(net)} {bucketLabel(c)} (face value)
                    </button>,
                  )
                }
                return out
              })}
            </div>
          )}
        </>
      )}
    </Panel>
  )
}

export default function App() {
  const { accountIndex, accountMeta, address, setAccountIndex } = useWallet()
  const p = useProtocol()
  const [tab, setTab] = useState<'settle' | 'admin' | 'oracle' | 'user'>('settle')

  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="eyebrow">Permissioned FX settlement network</p>
          <h1>FX Net</h1>
          <p className="lede">
            Local Anvil console for multilateral obligation netting (CLP / ARS / USD inventory),
            shared mint/redeem windows, and a trusted oracle.
          </p>
        </div>
        <div className="account-card">
          <label>
            Anvil account
            <select
              value={accountIndex}
              onChange={(e) => setAccountIndex(Number(e.target.value))}
            >
              {ANVIL_ACCOUNTS.map((a) => (
                <option key={a.index} value={a.index}>
                  #{a.index} {a.label}
                </option>
              ))}
            </select>
          </label>
          <p>
            <span>{accountMeta.label}</span>
            <code>{short(address)}</code>
            <button type="button" className="ghost-sm" onClick={() => void copyText(address)}>
              Copy
            </button>
          </p>
        </div>
      </header>

      {!p.deployed ? (
        <div className="banner">
          Contracts not deployed. Start Anvil, then run:
          <pre>
            forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
          </pre>
          That writes <code>app/src/contracts/deployments.json</code> — refresh this page after.
        </div>
      ) : (
        <>
          <div className="bucket-row">
            <span className="bucket-label">Active bucket</span>
            <BucketSwitcher />
          </div>
          <StatusBar />
          <p className="contracts">
            Hub <code>{short(deployments.hub)}</code> · Settle{' '}
            <code>{short(deployments.settlement)}</code> · USD <code>{short(deployments.usd)}</code>{' '}
            · CLP <code>{short(deployments.buckets.clp.token)}</code> · ARS{' '}
            <code>{short(deployments.buckets.ars.token)}</code> · Oracle{' '}
            <code>{short(deployments.oracle)}</code>
          </p>

          <nav className="tabs">
            {(['settle', 'admin', 'oracle', 'user'] as const).map((t) => (
              <button
                key={t}
                type="button"
                className={tab === t ? 'active' : ''}
                onClick={() => setTab(t)}
              >
                {t}
              </button>
            ))}
            <button type="button" className="ghost" disabled={p.busy} onClick={() => void p.refresh()}>
              Refresh
            </button>
          </nav>

          <TxStrip />
          {p.readError && <div className="error">Read error: {p.readError}</div>}

          {tab === 'settle' && <SettlePanel />}
          {tab === 'admin' && <AdminPanel />}
          {tab === 'oracle' && <OraclePanel />}
          {tab === 'user' && <UserPanel />}
        </>
      )}
    </div>
  )
}
