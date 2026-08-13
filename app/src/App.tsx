import { useState, type FormEvent, type ReactNode } from 'react'
import { type Address, formatEther, isAddress } from 'viem'
import { bucketLabel, deployments, PHASE_LABELS, type SettlementCurrency } from './contracts'
import { useProtocol, type TransferToken } from './useProtocol'
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
              {tx.hash && (
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
                </div>
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

function AdminPanel() {
  const p = useProtocol()
  const { address } = useWallet()
  const [mintTo, setMintTo] = useState<string>(address)
  const [mintAmt, setMintAmt] = useState('1000')
  const [reserveAmt, setReserveAmt] = useState('100')
  const [feeBps, setFeeBps] = useState(String(p.active.feeBps || 50))
  const [allowAddr, setAllowAddr] = useState<string>(ANVIL_ACCOUNTS[2].address)
  const [feeWithdraw, setFeeWithdraw] = useState('1')
  const [settlementFeeBps, setSettlementFeeBps] = useState(String(p.state.settlement.feeBps || 50))
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
        <h3>Allowlist</h3>
        <AllowlistList onPick={(addr) => setAllowAddr(addr)} />
      </div>

      <form
        className="form-row"
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          if (!isAddress(mintTo)) return
          void p.mintUsd(mintTo as Address, mintAmt)
        }}
      >
        <Field label="Mint USD to">
          <input value={mintTo} onChange={(e) => setMintTo(e.target.value)} />
        </Field>
        <Field label="Amount">
          <input value={mintAmt} onChange={(e) => setMintAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Mint USD
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
        <button type="button" disabled={p.busy} onClick={() => void p.withdrawReserve(reserveAmt)}>
          Withdraw reserve
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setFeeBps(Number(feeBps))
        }}
      >
        <Field label={`${bucketLabel(p.activeBucket)} redeem fee (bps)`}>
          <input value={feeBps} onChange={(e) => setFeeBps(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Set fee
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
  const [arsRate, setArsRate] = useState('1000')
  const canPost = p.state.windowOpen && !p.state.paused

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
      </form>
      {!canPost && (
        <p className="hint warn-text">Posting requires MRW open and hub not paused.</p>
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
        Multilateral obligation book. Post debts → admin locks (nets) → debtors fund escrow →
        creditors claim (receipt fee haircuts the claim). Mint/redeem is inventory only (not part of
        this session).
      </p>
      <p className="hint">
        Only the current session is kept in contract storage; opening a new one clears the book.
        Prior sessions can still be rebuilt from onchain events. Equal cycles (nothing to claim) pay
        no receipt fee; eliminated volume is shown after lock as a service metric, not a bill.
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
          <span>Receipt fee</span>
          <strong>{s.feeBps} bps</strong>
        </div>
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
          disabled={p.busy || p.state.paused || s.phase !== 1}
          onClick={() => void p.lockSettlementSession()}
        >
          Lock &amp; net
        </button>
        <button
          type="button"
          disabled={p.busy || (s.phase !== 1 && s.phase !== 2)}
          onClick={() => void p.cancelSettlementSession()}
        >
          Cancel
        </button>
      </div>

      {s.phase === 1 && (
        <>
          <form
            className="form-row"
            onSubmit={(e) => {
              e.preventDefault()
              if (!isAddress(debtor) || !isAddress(creditor)) return
              void p.postObligation(debtor as Address, creditor as Address, currency, amount)
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
            <button
              type="submit"
              disabled={p.busy || p.state.paused || !isAddress(debtor) || !isAddress(creditor)}
            >
              Post obligation
            </button>
          </form>
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
            {s.obligations.map((o, i) => (
              <li key={`${o.debtor}-${o.creditor}-${i}`}>
                <span>#{i}</span>
                <code>
                  {short(o.debtor)} → {short(o.creditor)} · {formatEther(o.amount)}{' '}
                  {currencyName(o.currency)}
                </code>
              </li>
            ))}
          </ul>
        )}
      </div>

      {(s.phase === 2 || s.phase === 3) && (
        <>
          <div className="allowlist-box">
            <h3>Net matrix (after lock)</h3>
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
                          {row.funded[c] ? ' ✓f' : ''}
                          {row.claimed[c] ? ' ✓c' : ''}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="hint">
              Escrow — CLP {formatEther(s.escrow.clp)} / need {formatEther(s.totalDebtor.clp)}
              {s.fullyFunded.clp ? ' (funded)' : ''} · ARS {formatEther(s.escrow.ars)} / need{' '}
              {formatEther(s.totalDebtor.ars)}
              {s.fullyFunded.ars ? ' (funded)' : ''} · USD {formatEther(s.escrow.usd)} / need{' '}
              {formatEther(s.totalDebtor.usd)}
              {s.fullyFunded.usd ? ' (funded)' : ''}
            </p>
            <p className="hint">
              Eliminated (gross − residual, not billed) — CLP {formatEther(s.eliminated.clp)} of{' '}
              {formatEther(s.grossPosted.clp)} · ARS {formatEther(s.eliminated.ars)} of{' '}
              {formatEther(s.grossPosted.ars)} · USD {formatEther(s.eliminated.usd)} of{' '}
              {formatEther(s.grossPosted.usd)}
            </p>
          </div>

          {s.phase === 2 && myNets && (
            <div className="actions">
              {(['clp', 'ars', 'usd'] as SettlementCurrency[]).map((c) => {
                const net = myNets.nets[c]
                if (net < 0n && !myNets.funded[c]) {
                  return (
                    <button
                      key={`fund-${c}`}
                      type="button"
                      disabled={p.busy || p.state.paused}
                      onClick={() => void p.fundSettlement(c)}
                    >
                      Fund {formatEther(-net)} {bucketLabel(c)}
                    </button>
                  )
                }
                if (net > 0n && !myNets.claimed[c]) {
                  const fee = bpsFee(net, s.feeBps)
                  const payout = net - fee
                  return (
                    <button
                      key={`claim-${c}`}
                      type="button"
                      disabled={p.busy || p.state.paused || !s.fullyFunded[c]}
                      onClick={() => void p.claimSettlement(c)}
                    >
                      Claim {formatEther(payout)} {bucketLabel(c)}
                      {fee > 0n ? ` (−${formatEther(fee)} fee)` : ''}
                      {!s.fullyFunded[c] ? ' (wait)' : ''}
                    </button>
                  )
                }
                return null
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
