import type { Abi, Address } from 'viem'
import usdAbiJson from './USD.abi.json'
import tokenAbiJson from './SettlementToken.abi.json'
import oracleAbiJson from './Oracle.abi.json'
import hubAbiJson from './ProtocolHub.abi.json'
import bucketAbiJson from './CurrencyBucket.abi.json'
import settlementAbiJson from './NettingSession.abi.json'
import deploymentsJson from './deployments.json'

export const usdAbi = usdAbiJson as Abi
export const tokenAbi = tokenAbiJson as Abi
export const oracleAbi = oracleAbiJson as Abi
export const hubAbi = hubAbiJson as Abi
export const bucketAbi = bucketAbiJson as Abi
export const settlementAbi = settlementAbiJson as Abi

export type BucketId = 'clp' | 'ars'
export type SettlementCurrency = 'clp' | 'ars' | 'usd'

export const BUCKET_IDS: BucketId[] = ['clp', 'ars']
export const SETTLEMENT_CURRENCIES: SettlementCurrency[] = ['clp', 'ars', 'usd']

export const CURRENCY = {
  clp: 0,
  ars: 1,
  usd: 2,
} as const

export const PHASE_LABELS = ['Idle', 'Open', 'Locked', 'Settled', 'Cancelled'] as const

export type BucketAddresses = {
  token: Address
  engine: Address
}

export type Deployments = {
  chainId: number
  usd: Address
  hub: Address
  oracle: Address
  settlement: Address
  admin: Address
  oracleOperator: Address
  allowlistedUsers: Address[]
  buckets: Record<BucketId, BucketAddresses>
}

export const deployments = deploymentsJson as Deployments

export function isDeployed(): boolean {
  return (
    deployments.hub !== '0x0000000000000000000000000000000000000000' &&
    deployments.buckets.clp.engine !== '0x0000000000000000000000000000000000000000'
  )
}

export function hasSettlement(): boolean {
  return (
    !!deployments.settlement &&
    deployments.settlement !== '0x0000000000000000000000000000000000000000'
  )
}

export function bucketLabel(id: BucketId | SettlementCurrency): string {
  return id.toUpperCase()
}

export function tokenAddress(currency: SettlementCurrency): Address {
  if (currency === 'usd') return deployments.usd
  return deployments.buckets[currency].token
}
