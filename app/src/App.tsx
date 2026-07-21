import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { type Address, formatEther, isAddress } from 'viem'
import { deployments, engineAbi } from './contracts'
import { useProtocol } from './useProtocol'
import { ANVIL_ACCOUNTS } from './wagmi'
import { useWallet } from './wallet'

function short(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function Field({
  label,
  children,
}: {
  label: string
  children: ReactNode
}) {
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

function StatusBar() {
  const { state, formatEth } = useProtocol()
  const rate =
    state.mxpPerUsd === 0n ? '—' : Number(formatEther(state.mxpPerUsd)).toFixed(4)

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
        <span>Rate</span>
        <strong>{rate} MXP/USD</strong>
      </div>
      <div className="stat">
        <span>Headroom</span>
        <strong>{formatEth(state.mintHeadroomUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>Collateral</span>
        <strong>{formatEth(state.collateralUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>Liability</span>
        <strong>{formatEth(state.liabilityUsd)} USD</strong>
      </div>
      <div className="stat">
        <span>Fees</span>
        <strong>{formatEth(state.accruedFees)} USD</strong>
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
                <code className="tx-hash">
                  {tx.hash.slice(0, 10)}…{tx.hash.slice(-8)}
                </code>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function AdminPanel() {
  const p = useProtocol()
  const { address, publicClient } = useWallet()
  const [mintTo, setMintTo] = useState<string>(address)
  const [mintAmt, setMintAmt] = useState('1000')
  const [reserveAmt, setReserveAmt] = useState('100')
  const [feeBps, setFeeBps] = useState(String(p.state.feeBps || 50))
  const [allowAddr, setAllowAddr] = useState<string>(ANVIL_ACCOUNTS[2].address)
  const [feeWithdraw, setFeeWithdraw] = useState('1')
  const [allowStatuses, setAllowStatuses] = useState<Record<string, boolean>>({})

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      const entries = await Promise.all(
        ANVIL_ACCOUNTS.map(async (a) => {
          const ok = (await publicClient.readContract({
            address: deployments.engine,
            abi: engineAbi,
            functionName: 'allowlist',
            args: [a.address],
          })) as boolean
          return [a.address.toLowerCase(), ok] as const
        }),
      )
      if (!cancelled) setAllowStatuses(Object.fromEntries(entries))
    })().catch(() => {})
    return () => {
      cancelled = true
    }
  }, [publicClient, p.txs, p.state.blockNumber])

  return (
    <Panel title="Admin">
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

      <div className="allowlist-box">
        <h3>Allowlist (Anvil accounts)</h3>
        <ul className="allowlist">
          {ANVIL_ACCOUNTS.map((a) => {
            const ok = allowStatuses[a.address.toLowerCase()]
            return (
              <li key={a.address}>
                <span>
                  #{a.index} {a.label}
                </span>
                <code>{short(a.address)}</code>
                <strong className={ok ? 'yes' : 'no'}>
                  {ok === undefined ? '…' : ok ? 'allowed' : 'blocked'}
                </strong>
              </li>
            )
          })}
        </ul>
        <p className="hint">
          Mapping is not fully enumerable on-chain; this checks the known local accounts. Admin (#0)
          is allowlisted at deploy.
        </p>
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
        <Field label="Deposit reserve (USD)">
          <input value={reserveAmt} onChange={(e) => setReserveAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Approve + deposit
        </button>
        <button
          type="button"
          disabled={p.busy}
          onClick={() => void p.withdrawReserve(reserveAmt)}
        >
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
        <Field label="Redeem fee (bps)">
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
        <Field label="Withdraw fees (USD)">
          <input value={feeWithdraw} onChange={(e) => setFeeWithdraw(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy}>
          Withdraw fees
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
      </form>
    </Panel>
  )
}

function OraclePanel() {
  const p = useProtocol()
  const [rate, setRate] = useState('17.2')
  const canPost = p.state.windowOpen && !p.state.paused

  return (
    <Panel title="Oracle">
      <p className="hint">
        Current on-chain rate:{' '}
        <strong>
          {p.state.mxpPerUsd === 0n ? 'unset' : `${formatEther(p.state.mxpPerUsd)} MXP per USD`}
        </strong>
        . Rate window nonce {p.state.rateWindowNonce.toString()} / engine{' '}
        {p.state.windowNonce.toString()}.
      </p>
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.setRate(rate)
        }}
      >
        <Field label="mxpPerUsd">
          <input value={rate} onChange={(e) => setRate(e.target.value)} disabled={!canPost} />
        </Field>
        <button type="submit" disabled={p.busy || !canPost}>
          Post rate
        </button>
      </form>
      {!canPost && (
        <p className="hint warn-text">Posting requires MRW open and engine not paused.</p>
      )}
    </Panel>
  )
}

function UserPanel() {
  const p = useProtocol()
  const { address } = useWallet()
  const [mintAmt, setMintAmt] = useState('100')
  const [redeemAmt, setRedeemAmt] = useState('100')

  return (
    <Panel title="User">
      <div className="balances">
        <div>
          <span>USD</span>
          <strong>{formatEther(p.state.usdBalance)}</strong>
        </div>
        <div>
          <span>MXP</span>
          <strong>{formatEther(p.state.mxpBalance)}</strong>
        </div>
        <div>
          <span>Allowlisted</span>
          <strong>{p.state.allowlisted ? 'yes' : 'no'}</strong>
        </div>
      </div>

      <p className="hint">
        USD comes from Admin: switch to <strong>#0 Admin</strong>, mint USD to{' '}
        <code>{short(address)}</code>, then switch back here to mint/redeem MXP.
      </p>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.approveUsdMax().then(() => p.mint(mintAmt))
        }}
      >
        <Field label="Mint MXP (USD in)">
          <input value={mintAmt} onChange={(e) => setMintAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy || !p.state.allowlisted || !p.state.windowOpen}>
          Approve + mint
        </button>
      </form>

      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          void p.approveMxpMax().then(() => p.redeem(redeemAmt))
        }}
      >
        <Field label="Redeem MXP">
          <input value={redeemAmt} onChange={(e) => setRedeemAmt(e.target.value)} />
        </Field>
        <button type="submit" disabled={p.busy || !p.state.allowlisted || !p.state.windowOpen}>
          Approve + redeem
        </button>
      </form>
    </Panel>
  )
}

export default function App() {
  const { accountIndex, accountMeta, address, setAccountIndex } = useWallet()
  const p = useProtocol()
  const [tab, setTab] = useState<'admin' | 'oracle' | 'user'>('admin')

  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="eyebrow">Permissioned FX stablecoin</p>
          <h1>NicoFX</h1>
          <p className="lede">
            Local Anvil console for USD collateral, MXP mint/redeem windows, and the trusted
            oracle.
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
          <StatusBar />
          <p className="contracts">
            Engine <code>{short(deployments.engine)}</code> · USD{' '}
            <code>{short(deployments.usd)}</code> · MXP <code>{short(deployments.mxp)}</code> ·
            Oracle <code>{short(deployments.oracle)}</code>
          </p>

          <nav className="tabs">
            {(['admin', 'oracle', 'user'] as const).map((t) => (
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

          {tab === 'admin' && <AdminPanel />}
          {tab === 'oracle' && <OraclePanel />}
          {tab === 'user' && <UserPanel />}
        </>
      )}
    </div>
  )
}
