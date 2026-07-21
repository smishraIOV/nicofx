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
  deployments,
  engineAbi,
  isDeployed,
  mxpAbi,
  oracleAbi,
  usdAbi,
} from './contracts'
import { useWallet } from './wallet'

export type ProtocolState = {
  windowOpen: boolean
  paused: boolean
  windowNonce: bigint
  windowEndBlock: bigint
  windowDurationBlocks: bigint
  windowBlocksRemaining: bigint
  feeBps: number
  accruedFees: bigint
  vaultBalance: bigint
  collateralUsd: bigint
  liabilityUsd: bigint
  reserveUsd: bigint
  mintHeadroomUsd: bigint
  withdrawalWindowActive: boolean
  withdrawalWindowStart: bigint
  withdrawalBlocksRemaining: bigint
  mxpPerUsd: bigint
  rateWindowNonce: bigint
  allowlisted: boolean
  usdBalance: bigint
  mxpBalance: bigint
  usdAllowance: bigint
  mxpAllowance: bigint
  blockNumber: bigint
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

const empty: ProtocolState = {
  windowOpen: false,
  paused: false,
  windowNonce: 0n,
  windowEndBlock: 0n,
  windowDurationBlocks: 200n,
  windowBlocksRemaining: 0n,
  feeBps: 0,
  accruedFees: 0n,
  vaultBalance: 0n,
  collateralUsd: 0n,
  liabilityUsd: 0n,
  reserveUsd: 0n,
  mintHeadroomUsd: 0n,
  withdrawalWindowActive: false,
  withdrawalWindowStart: 0n,
  withdrawalBlocksRemaining: 0n,
  mxpPerUsd: 0n,
  rateWindowNonce: 0n,
  allowlisted: false,
  usdBalance: 0n,
  mxpBalance: 0n,
  usdAllowance: 0n,
  mxpAllowance: 0n,
  blockNumber: 0n,
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

export function useProtocolController() {
  const { address, publicClient, walletClient } = useWallet()
  const [state, setState] = useState<ProtocolState>(empty)
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
      const engine = deployments.engine
      const [
        windowOpen,
        paused,
        windowNonce,
        windowEndBlock,
        windowDurationBlocks,
        windowBlocksRemaining,
        feeBps,
        accruedFees,
        vaultBalance,
        collateralUsd,
        liabilityUsd,
        reserveUsd,
        mintHeadroomUsd,
        withdrawalWindowActive,
        withdrawalWindowStart,
        withdrawalBlocksRemaining,
        mxpPerUsd,
        rateWindowNonce,
        allowlisted,
        usdBalance,
        mxpBalance,
        usdAllowance,
        mxpAllowance,
        blockNumber,
      ] = await Promise.all([
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'windowOpen' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'paused' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'windowNonce' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'windowEndBlock' }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'windowDurationBlocks',
        }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'windowBlocksRemaining',
        }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'feeBps' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'accruedFees' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'vaultBalance' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'collateralUsd' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'liabilityUsd' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'reserveUsd' }),
        publicClient.readContract({ address: engine, abi: engineAbi, functionName: 'mintHeadroomUsd' }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'withdrawalWindowActive',
        }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'withdrawalWindowStart',
        }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'withdrawalBlocksRemaining',
        }),
        publicClient.readContract({
          address: deployments.oracle,
          abi: oracleAbi,
          functionName: 'mxpPerUsd',
        }),
        publicClient.readContract({
          address: deployments.oracle,
          abi: oracleAbi,
          functionName: 'rateWindowNonce',
        }),
        publicClient.readContract({
          address: engine,
          abi: engineAbi,
          functionName: 'allowlist',
          args: [address],
        }),
        publicClient.readContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName: 'balanceOf',
          args: [address],
        }),
        publicClient.readContract({
          address: deployments.mxp,
          abi: mxpAbi,
          functionName: 'balanceOf',
          args: [address],
        }),
        publicClient.readContract({
          address: deployments.usd,
          abi: usdAbi,
          functionName: 'allowance',
          args: [address, engine],
        }),
        publicClient.readContract({
          address: deployments.mxp,
          abi: mxpAbi,
          functionName: 'allowance',
          args: [address, engine],
        }),
        publicClient.getBlockNumber(),
      ])

      setState({
        windowOpen: windowOpen as boolean,
        paused: paused as boolean,
        windowNonce: windowNonce as bigint,
        windowEndBlock: windowEndBlock as bigint,
        windowDurationBlocks: windowDurationBlocks as bigint,
        windowBlocksRemaining: windowBlocksRemaining as bigint,
        feeBps: Number(feeBps),
        accruedFees: accruedFees as bigint,
        vaultBalance: vaultBalance as bigint,
        collateralUsd: collateralUsd as bigint,
        liabilityUsd: liabilityUsd as bigint,
        reserveUsd: reserveUsd as bigint,
        mintHeadroomUsd: mintHeadroomUsd as bigint,
        withdrawalWindowActive: withdrawalWindowActive as boolean,
        withdrawalWindowStart: withdrawalWindowStart as bigint,
        withdrawalBlocksRemaining: withdrawalBlocksRemaining as bigint,
        mxpPerUsd: mxpPerUsd as bigint,
        rateWindowNonce: rateWindowNonce as bigint,
        allowlisted: allowlisted as boolean,
        usdBalance: usdBalance as bigint,
        mxpBalance: mxpBalance as bigint,
        usdAllowance: usdAllowance as bigint,
        mxpAllowance: mxpAllowance as bigint,
        blockNumber: blockNumber as bigint,
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

  const writeEngine = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`engine.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.engine,
          abi: engineAbi,
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

  const writeMxp = useCallback(
    (functionName: string, args: readonly unknown[] = []) =>
      run(`mxp.${functionName}`, async () =>
        walletClient.writeContract({
          address: deployments.mxp,
          abi: mxpAbi,
          functionName,
          args,
          chain: walletClient.chain,
          account: walletClient.account!,
        }),
      ),
    [run, walletClient],
  )

  return {
    deployed,
    state,
    readError,
    busy,
    txs,
    clearTxs,
    refresh,
    formatEth: formatEther,
    parseEth: parseEther,
    mintUsd: (to: Address, amount: string) => writeUsd('mint', [to, parseEther(amount)]),
    openWindow: () => writeEngine('openWindow'),
    closeWindow: () => writeEngine('closeWindow'),
    pause: () => writeEngine('pause'),
    unpause: () => writeEngine('unpause'),
    setFeeBps: (bps: number) => writeEngine('setFeeBps', [bps]),
    setAllowlist: (account: Address, allowed: boolean) =>
      writeEngine('setAllowlist', [account, allowed]),
    depositReserve: (amount: string) => writeEngine('depositReserve', [parseEther(amount)]),
    withdrawReserve: (amount: string) => writeEngine('withdrawReserve', [parseEther(amount)]),
    withdrawFees: (amount: string) => writeEngine('withdrawFees', [parseEther(amount)]),
    mint: (amount: string) => writeEngine('mint', [parseEther(amount)]),
    redeem: (amount: string) => writeEngine('redeem', [parseEther(amount)]),
    setRate: (mxpPerUsd: string) => writeOracle('setRate', [parseEther(mxpPerUsd)]),
    approveUsd: (amount: string) =>
      writeUsd('approve', [deployments.engine, parseEther(amount)]),
    approveMxp: (amount: string) =>
      writeMxp('approve', [deployments.engine, parseEther(amount)]),
    approveUsdMax: () => writeUsd('approve', [deployments.engine, parseEther('1000000000')]),
    approveMxpMax: () => writeMxp('approve', [deployments.engine, parseEther('1000000000')]),
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
