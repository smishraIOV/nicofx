import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import {
  createPublicClient,
  createWalletClient,
  http,
  type Account,
  type PublicClient,
  type WalletClient,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import { ANVIL_ACCOUNTS, ANVIL_RPC } from './wagmi'

type AnvilAccount = (typeof ANVIL_ACCOUNTS)[number]

type WalletContextValue = {
  accountIndex: number
  accountMeta: AnvilAccount
  address: `0x${string}`
  account: Account
  publicClient: PublicClient
  walletClient: WalletClient
  setAccountIndex: (index: number) => void
}

const WalletContext = createContext<WalletContextValue | null>(null)

const publicClient = createPublicClient({
  chain: foundry,
  transport: http(ANVIL_RPC),
})

export function WalletProvider({ children }: { children: ReactNode }) {
  const [accountIndex, setAccountIndex] = useState(0)

  const accountMeta = ANVIL_ACCOUNTS[accountIndex] ?? ANVIL_ACCOUNTS[0]
  const account = useMemo(() => privateKeyToAccount(accountMeta.key), [accountMeta.key])

  const walletClient = useMemo(
    () =>
      createWalletClient({
        account,
        chain: foundry,
        transport: http(ANVIL_RPC),
      }),
    [account],
  )

  const select = useCallback((index: number) => {
    if (index >= 0 && index < ANVIL_ACCOUNTS.length) setAccountIndex(index)
  }, [])

  const value = useMemo(
    () => ({
      accountIndex,
      accountMeta,
      address: account.address,
      account,
      publicClient,
      walletClient,
      setAccountIndex: select,
    }),
    [accountIndex, accountMeta, account, walletClient, select],
  )

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>
}

export function useWallet() {
  const ctx = useContext(WalletContext)
  if (!ctx) throw new Error('useWallet must be used within WalletProvider')
  return ctx
}
