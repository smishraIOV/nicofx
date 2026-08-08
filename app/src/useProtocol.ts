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
  feeBps: number
  accruedFees: bigint
  vaultBalance: bigint
  collateralUsd: bigint
  liabilityUsd: bigint
  reserveUsd: bigint
  mintHeadroomUsd: bigint
  tokenBalance: bigint
  tokenAllowance: bigint
  ratePerUsd: bigint
  rateWindowNonce: bigint
}

export type ObligationRow = {
  debtor: Address
  creditor: Address
  currency: number
  amount: bigint
}

export type PartyNetRow = {
  party: Address
  nets: Record<SettlementCurrency, bigint> // signed as bigint (negative = debtor)
  funded: Record<SettlementCurrency, boolean>
  claimed: Record<SettlementCurrency, boolean>
}

export type SettlementState = {
  phase: number
  sessionId: bigint
  obligations: ObligationRow[]
  participants: Address[]
  partyNets: PartyNetRow[]
  escrow: Record<SettlementCurrency, bigint>
  totalCreditor: Record<SettlementCurrency, bigint>
  totalDebtor: Record<SettlementCurrency, bigint>
  fullyFunded: Record<SettlementCurrency, boolean>
  usdAllowanceSettlement: bigint
  clpAllowanceSettlement: bigint
  arsAllowanceSettlement: bigint
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
  feeBps: 0,
  accruedFees: 0n,
  vaultBalance: 0n,
  collateralUsd: 0n,
  liabilityUsd: 0n,
  reserveUsd: 0n,
  mintHeadroomUsd: 0n,
  tokenBalance: 0n,
  tokenAllowance: 0n,
  ratePerUsd: 0n,
  rateWindowNonce: 0n,
}

const emptyCurrencyRecord = <T,>(v: T): Record<SettlementCurrency, T> => ({
  clp: v,
  ars: v,
  usd: v,
})

const emptySettlement: SettlementState = {
  phase: 0,
  sessionId: 0n,
  obligations: [],
  participants: [],
  partyNets: [],
  escrow: emptyCurrencyRecord(0n),
  totalCreditor: emptyCurrencyRecord(0n),
  totalDebtor: emptyCurrencyRecord(0n),
  fullyFunded: emptyCurrencyRecord(false),
  usdAllowanceSettlement: 0n,
  clpAllowanceSettlement: 0n,
  arsAllowanceSettlement: 0n,
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
    feeBps,
    accruedFees,
    vaultBalance,
    collateralUsd,
    liabilityUsd,
    reserveUsd,
    mintHeadroomUsd,
    tokenBalance,
    tokenAllowance,
    ratePerUsd,
    rateWindowNonce,
  ] = await Promise.all([
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'feeBps' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'accruedFees' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'vaultBalance' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'collateralUsd' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'liabilityUsd' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'reserveUsd' }),
    publicClient.readContract({ address: engine, abi: bucketAbi, functionName: 'mintHeadroomUsd' }),
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
  ])

  return {
    feeBps: Number(feeBps),
    accruedFees: accruedFees as bigint,
    vaultBalance: vaultBalance as bigint,
    collateralUsd: collateralUsd as bigint,
    liabilityUsd: liabilityUsd as bigint,
    reserveUsd: reserveUsd as bigint,
    mintHeadroomUsd: mintHeadroomUsd as bigint,
    tokenBalance: tokenBalance as bigint,
    tokenAllowance: tokenAllowance as bigint,
    ratePerUsd: ratePerUsd as bigint,
    rateWindowNonce: rateWindowNonce as bigint,
  }
}

async function readSettlement(
  publicClient: ReturnType<typeof useWallet>['publicClient'],
  address: Address,
): Promise<SettlementState> {
  if (!hasSettlement()) return emptySettlement

  const settlement = deployments.settlement
  const [phase, sessionId, obligationsRaw, participantsRaw] = await Promise.all([
    publicClient.readContract({ address: settlement, abi: settlementAbi, functionName: 'phase' }),
    publicClient.readContract({ address: settlement, abi: settlementAbi, functionName: 'sessionId' }),
    publicClient.readContract({
      address: settlement,
      abi: settlementAbi,
      functionName: 'getObligations',
    }),
    publicClient.readContract({
      address: settlement,
      abi: settlementAbi,
      functionName: 'participants',
    }),
  ])

  const participants = participantsRaw as Address[]
  const obligations = (obligationsRaw as { debtor: Address; creditor: Address; currency: number; amount: bigint }[]).map(
    (o) => ({
      debtor: o.debtor,
      creditor: o.creditor,
      currency: Number(o.currency),
      amount: o.amount as bigint,
    }),
  )

  const escrow = emptyCurrencyRecord(0n)
  const totalCreditor = emptyCurrencyRecord(0n)
  const totalDebtor = emptyCurrencyRecord(0n)
  const fullyFunded = emptyCurrencyRecord(false)

  await Promise.all(
    SETTLEMENT_CURRENCIES.map(async (id) => {
      const c = CURRENCY[id]
      const [esc, cred, debt, funded] = await Promise.all([
        publicClient.readContract({
          address: settlement,
          abi: settlementAbi,
          functionName: 'escrowBalance',
          args: [c],
        }),
        publicClient.readContract({
          address: settlement,
          abi: settlementAbi,
          functionName: 'totalCreditorNets',
          args: [c],
        }),
        publicClient.readContract({
          address: settlement,
          abi: settlementAbi,
          functionName: 'totalDebtorNets',
          args: [c],
        }),
        publicClient.readContract({
          address: settlement,
          abi: settlementAbi,
          functionName: 'currencyFullyFunded',
          args: [c],
        }),
      ])
      escrow[id] = esc as bigint
      totalCreditor[id] = cred as bigint
      totalDebtor[id] = debt as bigint
      fullyFunded[id] = funded as boolean
    }),
  )

  const partyNets: PartyNetRow[] = await Promise.all(
    participants.map(async (party) => {
      const nets = emptyCurrencyRecord(0n)
      const funded = emptyCurrencyRecord(false)
      const claimed = emptyCurrencyRecord(false)
      await Promise.all(
        SETTLEMENT_CURRENCIES.map(async (id) => {
          const c = CURRENCY[id]
          const [n, f, cl] = await Promise.all([
            publicClient.readContract({
              address: settlement,
              abi: settlementAbi,
              functionName: 'netOf',
              args: [party, c],
            }),
            publicClient.readContract({
              address: settlement,
              abi: settlementAbi,
              functionName: 'fundedOf',
              args: [party, c],
            }),
            publicClient.readContract({
              address: settlement,
              abi: settlementAbi,
              functionName: 'claimedOf',
              args: [party, c],
            }),
          ])
          nets[id] = n as bigint
          funded[id] = f as boolean
          claimed[id] = cl as boolean
        }),
      )
      return { party, nets, funded, claimed }
    }),
  )

  const [usdAllowanceSettlement, clpAllowanceSettlement, arsAllowanceSettlement] = await Promise.all([
    publicClient.readContract({
      address: deployments.usd,
      abi: usdAbi,
      functionName: 'allowance',
      args: [address, settlement],
    }),
    publicClient.readContract({
      address: deployments.buckets.clp.token,
      abi: tokenAbi,
      functionName: 'allowance',
      args: [address, settlement],
    }),
    publicClient.readContract({
      address: deployments.buckets.ars.token,
      abi: tokenAbi,
      functionName: 'allowance',
      args: [address, settlement],
    }),
  ])

  return {
    phase: Number(phase),
    sessionId: sessionId as bigint,
    obligations,
    participants,
    partyNets,
    escrow,
    totalCreditor,
    totalDebtor,
    fullyFunded,
    usdAllowanceSettlement: usdAllowanceSettlement as bigint,
    clpAllowanceSettlement: clpAllowanceSettlement as bigint,
    arsAllowanceSettlement: arsAllowanceSettlement as bigint,
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
        readSettlement(publicClient, address),
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
        const hash = await fn()
        patchTx(id, { hash, detail: 'waiting for receipt…' })
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        if (receipt.status === 'reverted') {
          patchTx(id, { status: 'fail', detail: 'transaction reverted on-chain' })
        } else {
          patchTx(id, { status: 'ok', detail: `confirmed · block ${receipt.blockNumber}` })
        }
        await refresh()
      } catch (e) {
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

  const approveSettlementToken = useCallback(
    (currency: SettlementCurrency) => {
      const max = parseEther('1000000000')
      if (currency === 'usd') {
        return writeUsd('approve', [deployments.settlement, max])
      }
      return writeToken(currency, 'approve', [deployments.settlement, max])
    },
    [writeUsd, writeToken],
  )

  const active = state.buckets[activeBucket]

  /// Mint/redeem require a non-zero rate stamped with the current hub window nonce.
  const rateValid = useCallback(
    (bucket: BucketId) => {
      const b = state.buckets[bucket]
      return b.ratePerUsd !== 0n && b.rateWindowNonce === state.windowNonce
    },
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
    mintUsd: (to: Address, amount: string) => writeUsd('mint', [to, parseEther(amount)]),
    openWindow: () => writeHub('openWindow'),
    closeWindow: () => writeHub('closeWindow'),
    pause: () => writeHub('pause'),
    unpause: () => writeHub('unpause'),
    setAllowlist: (account: Address, allowed: boolean) =>
      writeHub('setAllowlist', [account, allowed]),
    setFeeBps: (bps: number, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'setFeeBps', [bps]),
    depositReserve: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'depositReserve', [parseEther(amount)]),
    withdrawReserve: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'withdrawReserve', [parseEther(amount)]),
    withdrawFees: (amount: string, bucket: BucketId = activeBucket) =>
      writeBucket(bucket, 'withdrawFees', [parseEther(amount)]),
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
    openSettlementSession: () => writeSettlement('openSession'),
    lockSettlementSession: () => writeSettlement('lockSession'),
    cancelSettlementSession: () => writeSettlement('cancelSession'),
    postObligation: (
      debtor: Address,
      creditor: Address,
      currency: SettlementCurrency,
      amount: string,
    ) =>
      writeSettlement('postObligation', [
        debtor,
        creditor,
        CURRENCY[currency],
        parseEther(amount),
      ]),
    fundSettlement: (currency: SettlementCurrency) =>
      approveSettlementToken(currency).then(() => writeSettlement('fund', [CURRENCY[currency]])),
    claimSettlement: (currency: SettlementCurrency) =>
      writeSettlement('claim', [CURRENCY[currency]]),
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
