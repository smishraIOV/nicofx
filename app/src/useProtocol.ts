import {
  createContext,
  createElement,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'
import {
  BaseError,
  ContractFunctionRevertedError,
  formatEther,
  parseEther,
  type Address,
  type Hash,
} from 'viem'
import {
  BUCKET_IDS,
  CURRENCY,
  SETTLEMENT_CURRENCIES,
  bucketAbi,
  deployments,
  hasSettlement,
  hubAbi,
  isDeployed,
  oracleAbi,
  settlementAbi,
  tokenAbi,
  usdAbi,
  type BucketId,
  type SettlementCurrency,
} from './contracts'
import { useWallet } from './wallet'

export type BucketState = {
  mintFeeBps: number
  redeemFeeBps: number
  accruedFees: bigint
  vaultBalance: bigint
  collateralUsd: bigint
  liabilityUsd: bigint
  reserveUsd: bigint
  mintHeadroomUsd: bigint
  coverageRatioBps: bigint
  withdrawableReserveUsd: bigint
  tokenBalance: bigint
  tokenAllowance: bigint
  ratePerUsd: bigint
  rateWindowNonce: bigint
  rateIsFresh: boolean
  maxRateAge: bigint
  /// Pending timelocked reserve withdrawal (R1-M1); amount 0 = none
  pendingWithdrawalAmount: bigint
  pendingWithdrawalBlock: bigint
  withdrawalDelayBlocks: bigint
  /// liabilityUsd reverts when a rate is missing while supply is outstanding (R1-H5)
  liabilityUnavailable: boolean
}

export type ObligationRow = {
  index: number
  debtor: Address
  creditor: Address
  currency: number
  amount: bigint
  ref: string
  debtorAck: boolean
  creditorAck: boolean
  included: boolean
  voided: boolean
}

export type PartyNetRow = {
  party: Address
  nets: Record<SettlementCurrency, bigint> // signed (negative = debtor)
  /// |net| + receipt fee — debtors now carry the fee so creditors are paid at face value (R1-M4)
  required: Record<SettlementCurrency, bigint>
  deposited: Record<SettlementCurrency, bigint>
  outstanding: Record<SettlementCurrency, bigint>
  claimed: Record<SettlementCurrency, boolean>
}

export type SettlementState = {
  phase: number
  sessionId: bigint
  /// Fee this session was opened with; cannot be re-priced mid-session (R1-H3)
  sessionFeeBps: number
  /// Fee that will apply to the next session opened
  nextFeeBps: number
  fundingDeadline: bigint
  fundingWindowBlocks: bigint
  obligations: ObligationRow[]
  participants: Address[]
  partyNets: PartyNetRow[]
  includedCount: bigint
  pendingAckCount: bigint
  counterpartyPairs: bigint
  escrow: Record<SettlementCurrency, bigint>
  totalNets: Record<SettlementCurrency, bigint>
  totalRequired: Record<SettlementCurrency, bigint>
  shortfall: Record<SettlementCurrency, bigint>
  fullyFunded: Record<SettlementCurrency, boolean>
  accruedFees: Record<SettlementCurrency, bigint>
  grossPosted: Record<SettlementCurrency, bigint>
  eliminated: Record<SettlementCurrency, bigint>
  quarantineAddress: Address
}

export type ProtocolState = {
  windowOpen: boolean
  paused: boolean
  windowNonce: bigint
  windowEndBlock: bigint
  windowDurationBlocks: bigint
  windowBlocksRemaining: bigint
  withdrawalWindowActive: boolean
  withdrawalWindowStart: bigint
  withdrawalBlocksRemaining: bigint
  allowlisted: boolean
  allowlistedAccounts: Address[]
  usdBalance: bigint
  usdAllowanceClp: bigint
  usdAllowanceArs: bigint
  blockNumber: bigint
  buckets: Record<BucketId, BucketState>
  settlement: SettlementState
}

export type TxStatus = 'pending' | 'ok' | 'fail'

export type TxEntry = {
  id: string
  at: number
  label: string
  status: TxStatus
  detail: string
  hash?: Hash
}

export type TransferToken = 'usd' | 'clp' | 'ars'

const emptyBucket: BucketState = {
  mintFeeBps: 0,
  redeemFeeBps: 0,
  accruedFees: 0n,
  vaultBalance: 0n,
  collateralUsd: 0n,
  liabilityUsd: 0n,
  reserveUsd: 0n,
  mintHeadroomUsd: 0n,
  coverageRatioBps: 0n,
  withdrawableReserveUsd: 0n,
  tokenBalance: 0n,
  tokenAllowance: 0n,
  ratePerUsd: 0n,
  rateWindowNonce: 0n,
  rateIsFresh: false,
  maxRateAge: 0n,
  pendingWithdrawalAmount: 0n,
  pendingWithdrawalBlock: 0n,
  withdrawalDelayBlocks: 0n,
  liabilityUnavailable: false,
}

const emptyCurrencyRecord = <T,>(v: T): Record<SettlementCurrency, T> => ({
  clp: v,
  ars: v,
  usd: v,
})

const emptySettlement: SettlementState = {
  phase: 0,
  sessionId: 0n,
  sessionFeeBps: 0,
  nextFeeBps: 0,
  fundingDeadline: 0n,
  fundingWindowBlocks: 0n,
  obligations: [],
  participants: [],
  partyNets: [],
  includedCount: 0n,
  pendingAckCount: 0n,
  counterpartyPairs: 0n,
  escrow: emptyCurrencyRecord(0n),
  totalNets: emptyCurrencyRecord(0n),
  totalRequired: emptyCurrencyRecord(0n),
  shortfall: emptyCurrencyRecord(0n),
  fullyFunded: emptyCurrencyRecord(false),
  accruedFees: emptyCurrencyRecord(0n),
  grossPosted: emptyCurrencyRecord(0n),
  eliminated: emptyCurrencyRecord(0n),
  quarantineAddress: '0x0000000000000000000000000000000000000000',
}

const empty: ProtocolState = {
  windowOpen: false,
  paused: false,
  windowNonce: 0n,
  windowEndBlock: 0n,
  windowDurationBlocks: 200n,
  windowBlocksRemaining: 0n,
  withdrawalWindowActive: false,
  withdrawalWindowStart: 0n,
  withdrawalBlocksRemaining: 0n,
  allowlisted: false,
  allowlistedAccounts: [],
  usdBalance: 0n,
  usdAllowanceClp: 0n,
  usdAllowanceArs: 0n,
  blockNumber: 0n,
  buckets: { clp: emptyBucket, ars: emptyBucket },
  settlement: emptySettlement,
}

/// Views that can revert (see H5) are read through this so one bad rate cannot blank the whole UI.
async function safeRead<T>(p: Promise<unknown>, fallback: T): Promise<T> {
  try {
    return (await p) as T
  } catch {
    return fallback
  }
}

/// Obligations carry an external reference (invoice / trade id), unique per session (R1-H1).
export function refToBytes32(ref: string): `0x${string}` {
  const bytes = new TextEncoder().encode(ref)
  if (bytes.length > 32) throw new Error('reference must be 32 bytes or fewer')
  let hex = ''
  for (const b of bytes) hex += b.toString(16).padStart(2, '0')
  return `0x${hex.padEnd(64, '0')}`
}

export function bytes32ToRef(value: string): string {
  const hex = value.replace(/^0x/, '').replace(/(00)+$/, '')
  if (hex.length === 0) return ''
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return new TextDecoder().decode(bytes)
}

function formatTxError(e: unknown): string {
  if (e instanceof BaseError) {
    const reverted = e.walk((err) => err instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName
      if (name) {
        const args = reverted.data?.args
        return args && args.length > 0 ? `${name}(${args.join(', ')})` : name
      }
      if (reverted.reason) return reverted.reason
    }
    return e.shortMessage || e.message
  }
  if (e instanceof Error) return e.message
  return String(e)
}

async function readBucket(
  publicClient: ReturnType<typeof useWallet>['publicClient'],
  id: BucketId,
  address: Address,
): Promise<BucketState> {
  const engine = deployments.buckets[id].engine
  const token = deployments.buckets[id].token
  const currency = CURRENCY[id]

  const [
    mintFeeBps,
    redeemFeeBps,
    accruedFees,
    vaultBalance,
    collateralUsd,
    tokenBalance,
    tokenAllowance,
    ratePerUsd,
    rateWindowNonce,
    rateIsFresh,
    maxRateAge,
    pending,
    withdrawalDelayBlocks,
    liability,
  ] = await Promise.all([
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'mintFeeBps' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'redeemFeeBps' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'accruedFees' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'vaultBalance' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'collateralUsd' }),
    publicClient.readContract({
      address: token,
      abi: tokenAbi,
      functionName: 'balanceOf',
      args: [address],
    }),
    publicClient.readContract({
      address: token,
      abi: tokenAbi,
      functionName: 'allowance',
      args: [address, engine],
    }),
    publicClient.readContract({
      address: deployments.oracle,
      abi: oracleAbi,
      functionName: 'ratePerUsd',
      args: [currency],
    }),
    publicClient.readContract({
      address: deployments.oracle,
      abi: oracleAbi,
      functionName: 'rateWindowNonce',
      args: [currency],
    }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'rateIsFresh' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'maxRateAge' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'pendingWithdrawal' }),
    publicClient.readContract({
      address: engine,
      abi: bucketAbi,
      functionName: 'RESERVE_WITHDRAWAL_DELAY_BLOCKS',
    }),
    // liabilityUsd now reverts on a missing rate with supply outstanding (R1-H5), and every
    // liability-derived view reverts with it, so read them defensively.
    safeRead<bigint | null>(
      publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'liabilityUsd' }),
      null,
    ),
  ])

  const liabilityUnavailable = liability === null
  const [reserveUsd, mintHeadroomUsd, coverageRatioBps, withdrawableReserveUsd] = liabilityUnavailable
    ? [0n, 0n, 0n, 0n]
    : await Promise.all([
        safeRead<bigint>(
          publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'reserveUsd' }),
          0n,
        ),
        safeRead<bigint>(
          publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'mintHeadroomUsd' }),
          0n,
        ),
        safeRead<bigint>(
          publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'coverageRatioBps' }),
          0n,
        ),
        safeRead<bigint>(
          publicClient.readContract({
            address: engine,
            abi: bucketAbi,
            functionName: 'withdrawableReserveUsd',
          }),
          0n,
        ),
      ])

  const [pendingWithdrawalAmount, pendingWithdrawalBlock] = pending as readonly [bigint, bigint]

  return {
    mintFeeBps: Number(mintFeeBps),
    redeemFeeBps: Number(redeemFeeBps),
    accruedFees: accruedFees as bigint,
    vaultBalance: vaultBalance as bigint,
    collateralUsd: collateralUsd as bigint,
    liabilityUsd: liability ?? 0n,
    reserveUsd,
    mintHeadroomUsd,
    coverageRatioBps,
    withdrawableReserveUsd,
    tokenBalance: tokenBalance as bigint,
    tokenAllowance: tokenAllowance as bigint,
    ratePerUsd: ratePerUsd as bigint,
    rateWindowNonce: rateWindowNonce as bigint,
    rateIsFresh: rateIsFresh as boolean,
    maxRateAge: maxRateAge as bigint,
    pendingWithdrawalAmount,
    pendingWithdrawalBlock,
    withdrawalDelayBlocks: withdrawalDelayBlocks as bigint,
    liabilityUnavailable,
  }
}

async function readSettlement(
  publicClient: ReturnType<typeof useWallet>['publicClient'],
): Promise<SettlementState> {
  if (!hasSettlement()) return emptySettlement

  const settlement = deployments.settlement
  const read = (functionName: string, args: readonly unknown[] = []) =>
    publicClient.readContract({ address: settlement, abi: settlementAbi, functionName, args })

  const [phase, sessionIdRaw, nextFeeBps, fundingWindowBlocks, quarantineAddress] = await Promise.all([
    read('phase'),
    read('sessionId'),
    read('feeBps'),
    read('fundingWindowBlocks'),
    read('quarantineAddress'),
  ])

  const sid = sessionIdRaw as bigint

  const [
    sessionFeeBps,
    fundingDeadline,
    obligationsRaw,
    participantsRaw,
    includedCount,
    pendingAckCount,
    counterpartyPairs,
  ] = await Promise.all([
    read('sessionFeeBps', [sid]),
    read('fundingDeadline', [sid]),
    read('getObligations', [sid]),
    read('participants', [sid]),
    read('includedCount', [sid]),
    read('pendingAckCount', [sid]),
    read('counterpartyPairs', [sid]),
  ])

  const participants = participantsRaw as Address[]
  const obligations = (
    obligationsRaw as {
      debtor: Address
      creditor: Address
      currency: number
      amount: bigint
      ref: string
      debtorAck: boolean
      creditorAck: boolean
      included: boolean
      voided: boolean
    }[]
  ).map((o, index) => ({
    index,
    debtor: o.debtor,
    creditor: o.creditor,
    currency: Number(o.currency),
    amount: o.amount,
    ref: o.ref,
    debtorAck: o.debtorAck,
    creditorAck: o.creditorAck,
    included: o.included,
    voided: o.voided,
  }))

  const escrow = emptyCurrencyRecord(0n)
  const totalNets = emptyCurrencyRecord(0n)
  const totalRequired = emptyCurrencyRecord(0n)
  const shortfall = emptyCurrencyRecord(0n)
  const fullyFunded = emptyCurrencyRecord(false)
  const accruedFees = emptyCurrencyRecord(0n)
  const grossPosted = emptyCurrencyRecord(0n)
  const eliminated = emptyCurrencyRecord(0n)

  await Promise.all(
    SETTLEMENT_CURRENCIES.map(async (id) => {
      const c = CURRENCY[id]
      const [esc, nets, required, short, funded, fees, gross, elim] = await Promise.all([
        read('escrowBalance', [sid, c]),
        read('totalCreditorNets', [sid, c]),
        read('totalRequired', [sid, c]),
        read('fundingShortfall', [sid, c]),
        read('currencyFullyFunded', [sid, c]),
        read('accruedFees', [c]),
        read('grossPosted', [sid, c]),
        read('eliminated', [sid, c]),
      ])
      escrow[id] = esc as bigint
      totalNets[id] = nets as bigint
      totalRequired[id] = required as bigint
      shortfall[id] = short as bigint
      fullyFunded[id] = funded as boolean
      accruedFees[id] = fees as bigint
      grossPosted[id] = gross as bigint
      eliminated[id] = elim as bigint
    }),
  )

  const partyNets: PartyNetRow[] = await Promise.all(
    participants.map(async (party) => {
      const nets = emptyCurrencyRecord(0n)
      const required = emptyCurrencyRecord(0n)
      const deposited = emptyCurrencyRecord(0n)
      const outstanding = emptyCurrencyRecord(0n)
      const claimed = emptyCurrencyRecord(false)
      await Promise.all(
        SETTLEMENT_CURRENCIES.map(async (id) => {
          const c = CURRENCY[id]
          const [n, req, dep, cl] = await Promise.all([
            read('netOf', [sid, party, c]),
            read('requiredDeposit', [sid, party, c]),
            read('depositedOf', [sid, party, c]),
            read('claimedOf', [sid, party, c]),
          ])
          nets[id] = n as bigint
          required[id] = req as bigint
          deposited[id] = dep as bigint
          const gap = (req as bigint) - (dep as bigint)
          outstanding[id] = gap > 0n ? gap : 0n
          claimed[id] = cl as boolean
        }),
      )
      return { party, nets, required, deposited, outstanding, claimed }
    }),
  )

  return {
    phase: Number(phase),
    sessionId: sid,
    sessionFeeBps: Number(sessionFeeBps),
    nextFeeBps: Number(nextFeeBps),
    fundingDeadline: fundingDeadline as bigint,
    fundingWindowBlocks: fundingWindowBlocks as bigint,
    obligations,
    participants,
    partyNets,
    includedCount: includedCount as bigint,
    pendingAckCount: pendingAckCount as bigint,
    counterpartyPairs: counterpartyPairs as bigint,
    escrow,
    totalNets,
    totalRequired,
    shortfall,
    fullyFunded,
    accruedFees,
    grossPosted,
    eliminated,
    quarantineAddress: quarantineAddress as Address,
  }
}

export function useProtocolController() {
  const { address, publicClient, walletClient } = useWallet()
  const [state, setState] = useState<ProtocolState>(empty)
  const [activeBucket, setActiveBucket] = useState<BucketId>('clp')
  const [readError, setReadError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [txs, setTxs] = useState<TxEntry[]>([])
  const deployed = isDeployed()

  const pushTx = useCallback((entry: Omit<TxEntry, 'id' | 'at'> & { id?: string }) => {
    const full: TxEntry = {
      id: entry.id ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      at: Date.now(),
      label: entry.label,
      status: entry.status,
      detail: entry.detail,
      hash: entry.hash,
    }
    setTxs((prev) => [full, ...prev].slice(0, 20))
    return full.id
  }, [])

  const patchTx = useCallback((id: string, patch: Partial<TxEntry>) => {
    setTxs((prev) => prev.map((t) => (t.id === id ? { ...t, ...patch } : t)))
  }, [])

  const clearTxs = useCallback(() => setTxs([]), [])

  const refresh = useCallback(async () => {
    if (!deployed) return
    try {
      const hub = deployments.hub
      const [
        windowOpen,
        paused,
        windowNonce,
        windowEndBlock,
        windowDurationBlocks,
        windowBlocksRemaining,
        withdrawalWindowActive,
        withdrawalWindowStart,
        withdrawalBlocksRemaining,
        allowlisted,
        allowlistedAccounts,
        usdBalance,
        usdAllowanceClp,
        usdAllowanceArs,
        blockNumber,
        clpBucket,
        arsBucket,
        settlement,
      ] = await Promise.all([
        publicClient.readContract({ address: hub, abi: hubAbi, functionName: 'windowOpen' }),
        publicClient.readContract({ address: hub, abi: hubAbi, functionName: 'paused' }),
        publicClient.readContract({ address: hub, abi: hubAbi, functionName: 'windowNonce' }),
        publicClient.readContract({ address: hub, abi: hubAbi, functionName: 'windowEndBlock' }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'windowDurationBlocks',
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'windowBlocksRemaining',
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'withdrawalWindowActive',
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'withdrawalWindowStart',
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'withdrawalBlocksRemaining',
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'isAllowlisted',
          args: [address],
        }),
        publicClient.readContract({
          address: hub,
          abi: hubAbi,
          functionName: 'allowlistedAccounts',
        }),
        publicClient.readContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName: 'balanceOf',
          args: [address],
        }),
        publicClient.readContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName: 'allowance',
          args: [address, deployments.buckets.clp.engine],
        }),
        publicClient.readContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName: 'allowance',
          args: [address, deployments.buckets.ars.engine],
        }),
        publicClient.getBlockNumber(),
        readBucket(publicClient, 'clp', address),
        readBucket(publicClient, 'ars', address),
        readSettlement(publicClient),
      ])

      setState({
        windowOpen: windowOpen as boolean,
        paused: paused as boolean,
        windowNonce: windowNonce as bigint,
        windowEndBlock: windowEndBlock as bigint,
        windowDurationBlocks: windowDurationBlocks as bigint,
        windowBlocksRemaining: windowBlocksRemaining as bigint,
        withdrawalWindowActive: withdrawalWindowActive as boolean,
        withdrawalWindowStart: withdrawalWindowStart as bigint,
        withdrawalBlocksRemaining: withdrawalBlocksRemaining as bigint,
        allowlisted: allowlisted as boolean,
        allowlistedAccounts: allowlistedAccounts as Address[],
        usdBalance: usdBalance as bigint,
        usdAllowanceClp: usdAllowanceClp as bigint,
        usdAllowanceArs: usdAllowanceArs as bigint,
        blockNumber: blockNumber as bigint,
        buckets: { clp: clpBucket, ars: arsBucket },
        settlement,
      })
      setReadError(null)
    } catch (e) {
      setReadError(formatTxError(e))
    }
  }, [address, deployed, publicClient])

  useEffect(() => {
    void refresh()
    const id = setInterval(() => void refresh(), 4000)
    return () => clearInterval(id)
  }, [refresh])

  const run = useCallback(
    async (label: string, fn: () => Promise<Hash>) => {
      setBusy(true)
      const id = pushTx({ label, status: 'pending', detail: 'sending…' })
      try {
        // viem simulates before broadcasting, so a failing call usually throws here and no
        // transaction is ever submitted — there is no hash to show for those. A hash only exists
        // once the node has accepted the transaction.
        const hash = await fn()
        patchTx(id, { hash, detail: 'waiting for receipt…' })
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        if (receipt.status === 'reverted') {
          patchTx(id, {
            status: 'fail',
            detail: `reverted on-chain · block ${receipt.blockNumber}`,
          })
        } else {
          patchTx(id, { status: 'ok', detail: `confirmed · block ${receipt.blockNumber}` })
        }
        await refresh()
      } catch (e) {
        // Keep whatever hash the entry already has: a receipt-stage failure is still inspectable.
        patchTx(id, { status: 'fail', detail: formatTxError(e) })
      } finally {
        setBusy(false)
      }
    },
    [pushTx, patchTx, publicClient, refresh],
  )

  const writeHub = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`hub.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.hub,
          abi: hubAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  const writeBucket = useCallback(
    (bucket: BucketId, functionName: string, args: readonly unknown[] = []) =>
      run(`${bucket}.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.buckets[bucket].engine,
          abi: bucketAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  const writeUsd = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`usd.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  const writeOracle = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`oracle.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.oracle,
          abi: oracleAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  const writeToken = useCallback(
    (bucket: BucketId, functionName: string, args: readonly unknown[] = []) =>
      run(`${bucket}Token.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.buckets[bucket].token,
          abi: tokenAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  const writeSettlement = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`settlement.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.settlement,
          abi: settlementAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  /// Approve only what this action needs, rather than a blanket allowance to upgradeable code.
  const ensureSettlementAllowance = useCallback(
    async (currency: SettlementCurrency, amount: bigint) => {
      const isUsd = currency === 'usd'
      const tokenAddress = isUsd ? deployments.usd : deployments.buckets[currency].token
      const abi = isUsd ? usdAbi : tokenAbi
      const current = (await publicClient.readContract({
        address: tokenAddress,
        abi,
        functionName: 'allowance',
        args: [address, deployments.settlement],
      })) as bigint
      if (current >= amount) return
      if (isUsd) {
        await writeUsd('approve', [deployments.settlement, amount])
      } else {
        await writeToken(currency, 'approve', [deployments.settlement, amount])
      }
    },
    [address, publicClient, writeUsd, writeToken],
  )

  const active = state.buckets[activeBucket]

  /// Mint/redeem require a non-zero rate stamped with the current hub window nonce, and now also
  /// a rate no older than the bucket's maxRateAge (R1-H5).
  const rateValid = useCallback(
    (bucket: BucketId) => state.buckets[bucket].rateIsFresh,
    [state],
  )

  return {
    deployed,
    hasSettlement: hasSettlement(),
    state,
    activeBucket,
    setActiveBucket,
    active,
    rateValid,
    activeRateValid: rateValid(activeBucket),
    bucketIds: BUCKET_IDS,
    readError,
    busy,
    txs,
    clearTxs,
    refresh,
    formatEth: formatEther,
    parseEth: parseEther,

    // --- USD / hub admin ---
    mintUsd: (to: Address, amount: string) => writeUsd('mint', [to, parseEther(amount)]),
    openWindow: () => writeHub('openWindow'),
    closeWindow: () => writeHub('closeWindow'),
    pause: () => writeHub('pause'),
    unpause: () => writeHub('unpause'),
    setAllowlist: (account: Address, allowed: boolean) =>
      writeHub('setAllowlist', [account, allowed]),
    setMinWindowBlocks: (blocks: string) => writeHub('setMinWindowBlocks', [BigInt(blocks)]),

    // --- bucket admin ---
    setMintFeeBps: (bps: number, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'setMintFeeBps', [bps]),
    setRedeemFeeBps: (bps: number, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'setRedeemFeeBps', [bps]),
    setMaxRateAge: (seconds: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'setMaxRateAge', [BigInt(seconds)]),
    depositReserve: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'depositReserve', [parseEther(amount)]),
    requestReserveWithdrawal: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'requestReserveWithdrawal', [parseEther(amount)]),
    executeReserveWithdrawal: (bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'executeReserveWithdrawal'),
    cancelReserveWithdrawal: (bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'cancelReserveWithdrawal'),
    withdrawFees: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'withdrawFees', [parseEther(amount)]),

    // --- inventory ---
    mint: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'mint', [parseEther(amount)]),
    redeem: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'redeem', [parseEther(amount)]),
    setRate: (currency: BucketId, rate: string) =>
      writeOracle('setRate', [CURRENCY[currency], parseEther(rate)]),
    approveUsdMax: (bucket: BucketId = activeBucket) =>
      writeUsd('approve', [deployments.buckets[bucket].engine, parseEther('1000000000')]),
    approveTokenMax: (bucket: BucketId = activeBucket) =>
      writeToken(bucket, 'approve', [
        deployments.buckets[bucket].engine,
        parseEther('1000000000'),
      ]),
    transfer: (token: TransferToken, to: Address, amount: string) => {
      const value = parseEther(amount)
      if (token === 'usd') return writeUsd('transfer', [to, value])
      return writeToken(token, 'transfer', [to, value])
    },

    // --- settlement lifecycle ---
    openSettlementSession: () => writeSettlement('openSession'),
    freezeSettlementSession: () => writeSettlement('freezeSession'),
    cancelSettlementSession: () => writeSettlement('cancelSession'),
    declareSettlementFailure: (sessionId: bigint) => writeSettlement('declareFailure', [sessionId]),

    // --- obligation book ---
    postObligation: (
      debtor: Address,
      creditor: Address,
      currency: SettlementCurrency,
      amount: string,
      ref: string,
    ) =>
      writeSettlement('postObligation', [
        debtor,
        creditor,
        CURRENCY[currency],
        parseEther(amount),
        refToBytes32(ref),
      ]),
    acknowledgeObligations: (indices: number[]) =>
      writeSettlement('acknowledge', [indices.map((i) => BigInt(i))]),
    voidObligation: (index: number) => writeSettlement('voidObligation', [BigInt(index)]),

    // --- settlement funding ---
    depositSettlement: async (currency: SettlementCurrency, amount: string) => {
      const value = parseEther(amount)
      await ensureSettlementAllowance(currency, value)
      return writeSettlement('deposit', [CURRENCY[currency], value])
    },
    withdrawSettlementDeposit: (sessionId: bigint, currency: SettlementCurrency) =>
      writeSettlement('withdrawDeposit', [sessionId, CURRENCY[currency]]),
    claimSettlement: (sessionId: bigint, currency: SettlementCurrency) =>
      writeSettlement('claim', [sessionId, CURRENCY[currency]]),

    // --- settlement admin ---
    setSettlementFeeBps: (bps: number) => writeSettlement('setFeeBps', [bps]),
    setSettlementFundingWindow: (blocks: string) =>
      writeSettlement('setFundingWindowBlocks', [BigInt(blocks)]),
    setSettlementMaxNet: (party: Address, currency: SettlementCurrency, max: string) =>
      writeSettlement('setMaxNet', [party, CURRENCY[currency], parseEther(max)]),
    setQuarantineAddress: (account: Address) => writeSettlement('setQuarantineAddress', [account]),
    sweepQuarantined: (sessionId: bigint, party: Address, currency: SettlementCurrency) =>
      writeSettlement('sweepQuarantined', [sessionId, party, CURRENCY[currency]]),
    withdrawSettlementFees: (currency: SettlementCurrency, amount: string) =>
      writeSettlement('withdrawFees', [CURRENCY[currency], parseEther(amount)]),
  }
}

export type ProtocolApi = ReturnType<typeof useProtocolController>

const ProtocolContext = createContext<ProtocolApi | null>(null)

export function ProtocolProvider({ children }: { children: ReactNode }) {
  const api = useProtocolController()
  return createElement(ProtocolContext.Provider, { value: api }, children)
}

export function useProtocol(): ProtocolApi {
  const ctx = useContext(ProtocolContext)
  if (!ctx) throw new Error('useProtocol must be used within ProtocolProvider')
  return ctx
}
