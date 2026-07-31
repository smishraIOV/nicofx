import type { Abi, Address } from 'viem'
import usdAbiJson from './USD.abi.json'
import tokenAbiJson from './SettlementToken.abi.json'
import oracleAbiJson from './Oracle.abi.json'
import hubAbiJson from './ProtocolHub.abi.json'
import bucketAbiJson from './CurrencyBucket.abi.json'
import deploymentsJson from './deployments.json'

export const usdAbi = usdAbiJson as Abi
export const tokenAbi = tokenAbiJson as Abi
export const oracleAbi = oracleAbiJson as Abi
export const hubAbi = hubAbiJson as Abi
export const bucketAbi = bucketAbiJson as Abi

export type BucketId = 'clp' | 'ars'

export const BUCKET_IDS: BucketId[] = ['clp', 'ars']

export const CURRENCY = {
  clp: 0,
  ars: 1,
} as const

export type BucketAddresses = {
  token: Address
  engine: Address
}

export type Deployments = {
  chainId: number
  usd: Address
  hub: Address
  oracle: Address
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

export function bucketLabel(id: BucketId): string {
  return id.toUpperCase()
}
