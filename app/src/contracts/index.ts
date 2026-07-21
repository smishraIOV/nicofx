import type { Abi, Address } from 'viem'
import usdAbiJson from './USD.abi.json'
import mxpAbiJson from './MXP.abi.json'
import oracleAbiJson from './Oracle.abi.json'
import engineAbiJson from './MXPEngine.abi.json'
import deploymentsJson from './deployments.json'

export const usdAbi = usdAbiJson as Abi
export const mxpAbi = mxpAbiJson as Abi
export const oracleAbi = oracleAbiJson as Abi
export const engineAbi = engineAbiJson as Abi

export type Deployments = {
  chainId: number
  usd: Address
  mxp: Address
  oracle: Address
  engine: Address
  admin: Address
  oracleOperator: Address
}

export const deployments = deploymentsJson as Deployments

export function isDeployed(): boolean {
  return deployments.engine !== '0x0000000000000000000000000000000000000000'
}
