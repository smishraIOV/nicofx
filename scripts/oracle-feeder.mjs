#!/usr/bin/env node
/**
 * Oracle feeder — pulls USD→MXN from a free FX API and posts mxpPerUsd on-chain.
 *
 * Prerequisites:
 *   - anvil running
 *   - contracts deployed (app/src/contracts/deployments.json)
 *   - MRW open and engine not paused
 *
 * Usage:
 *   node scripts/oracle-feeder.mjs
 *   node scripts/oracle-feeder.mjs --once
 *   RPC_URL=http://127.0.0.1:8545 INTERVAL_MS=30000 node scripts/oracle-feeder.mjs
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, '..')
const deploymentsPath = join(root, 'app/src/contracts/deployments.json')

const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8545'
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 60_000)
const ORACLE_KEY =
  process.env.ORACLE_PRIVATE_KEY ??
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const once = process.argv.includes('--once')

function loadDeployments() {
  const raw = readFileSync(deploymentsPath, 'utf8')
  const d = JSON.parse(raw)
  if (!d.oracle || d.oracle === '0x0000000000000000000000000000000000000000') {
    throw new Error('deployments.json has zero oracle address — deploy first')
  }
  return d
}

async function fetchMxpPerUsd() {
  // Frankfurter: ECB-sourced daily rates (free, no key)
  const url = 'https://api.frankfurter.app/latest?from=USD&to=MXN'
  const res = await fetch(url)
  if (!res.ok) throw new Error(`FX API HTTP ${res.status}`)
  const data = await res.json()
  const mxn = data?.rates?.MXN
  if (typeof mxn !== 'number' || !(mxn > 0)) {
    throw new Error(`Unexpected FX payload: ${JSON.stringify(data)}`)
  }
  return mxn
}

function toWei18(rate) {
  // Avoid float dust: use 8 decimal places then pad to 18
  const fixed = rate.toFixed(8)
  const [whole, frac = ''] = fixed.split('.')
  return BigInt(whole + frac.padEnd(18, '0').slice(0, 18))
}

function cast(args) {
  const result = spawnSync('cast', args, { encoding: 'utf8' })
  if (result.status !== 0) {
    const err = (result.stderr || result.stdout || 'cast failed').trim()
    throw new Error(err)
  }
  return (result.stdout || '').trim()
}

function readBool(address, sig) {
  const out = cast(['call', address, sig, '--rpc-url', RPC_URL])
  return out === 'true' || out.endsWith('1')
}

async function postRate(deployments, rateWei) {
  const engine = deployments.engine
  const windowOpen = readBool(engine, 'windowOpen()(bool)')
  const paused = readBool(engine, 'paused()(bool)')
  if (!windowOpen) throw new Error('MRW is closed — open window before posting')
  if (paused) throw new Error('Engine is paused — unpause before posting')

  const tx = cast([
    'send',
    deployments.oracle,
    'setRate(uint256)',
    rateWei.toString(),
    '--private-key',
    ORACLE_KEY,
    '--rpc-url',
    RPC_URL,
    '--legacy',
  ])
  return tx
}

async function tick() {
  const deployments = loadDeployments()
  const mxn = await fetchMxpPerUsd()
  const rateWei = toWei18(mxn)
  console.log(`[feeder] USD/MXN=${mxn} → mxpPerUsd=${rateWei}`)
  const tx = await postRate(deployments, rateWei)
  console.log(`[feeder] posted ok\n${tx}`)
}

async function main() {
  console.log(`[feeder] rpc=${RPC_URL} interval=${INTERVAL_MS}ms once=${once}`)
  if (once) {
    await tick()
    return
  }
  for (;;) {
    try {
      await tick()
    } catch (e) {
      console.error(`[feeder] ${e instanceof Error ? e.message : e}`)
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS))
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
