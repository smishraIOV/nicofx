#!/usr/bin/env node
/**
 * Oracle feeder — pulls USD→CLP and USD→ARS from a free FX API and posts rates on-chain.
 *
 * Prerequisites:
 *   - anvil running
 *   - contracts deployed (app/src/contracts/deployments.json)
 *   - MRW open and hub not paused
 *
 * Usage:
 *   node scripts/oracle-feeder.mjs
 *   node scripts/oracle-feeder.mjs --once
 *   node scripts/oracle-feeder.mjs --currency clp
 *   node scripts/oracle-feeder.mjs --currency ars
 *   node scripts/oracle-feeder.mjs --currency both
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

const CURRENCY = { clp: 0, ars: 1 }

function parseCurrencyArg() {
  const idx = process.argv.indexOf('--currency')
  if (idx === -1) return 'both'
  const value = (process.argv[idx + 1] || 'both').toLowerCase()
  if (value === 'clp' || value === 'ars' || value === 'both') return value
  throw new Error(`Invalid --currency ${value} (use clp|ars|both)`)
}

const currencyMode = parseCurrencyArg()

function loadDeployments() {
  const raw = readFileSync(deploymentsPath, 'utf8')
  const d = JSON.parse(raw)
  if (!d.oracle || d.oracle === '0x0000000000000000000000000000000000000000') {
    throw new Error('deployments.json has zero oracle address — deploy first')
  }
  if (!d.hub) throw new Error('deployments.json missing hub — redeploy with multicurrency script')
  return d
}

async function fetchRates() {
  const url = 'https://open.er-api.com/v6/latest/USD'
  const res = await fetch(url)
  if (!res.ok) throw new Error(`FX API HTTP ${res.status}`)
  const data = await res.json()
  const clp = data?.rates?.CLP
  const ars = data?.rates?.ARS
  if (typeof clp !== 'number' || !(clp > 0)) {
    throw new Error(`Unexpected CLP rate: ${JSON.stringify(data?.rates?.CLP)}`)
  }
  if (typeof ars !== 'number' || !(ars > 0)) {
    throw new Error(`Unexpected ARS rate: ${JSON.stringify(data?.rates?.ARS)}`)
  }
  return { clp, ars }
}

function toWei18(rate) {
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

function postRate(deployments, currencyId, rateWei) {
  const hub = deployments.hub
  const windowOpen = readBool(hub, 'windowOpen()(bool)')
  const paused = readBool(hub, 'paused()(bool)')
  if (!windowOpen) throw new Error('MRW is closed — open window before posting')
  if (paused) throw new Error('Hub is paused — unpause before posting')

  return cast([
    'send',
    deployments.oracle,
    'setRate(uint8,uint256)',
    String(currencyId),
    rateWei.toString(),
    '--private-key',
    ORACLE_KEY,
    '--rpc-url',
    RPC_URL,
    '--legacy',
  ])
}

async function tick() {
  const deployments = loadDeployments()
  const rates = await fetchRates()

  const jobs = []
  if (currencyMode === 'clp' || currencyMode === 'both') {
    jobs.push({ id: 'clp', currencyId: CURRENCY.clp, rate: rates.clp })
  }
  if (currencyMode === 'ars' || currencyMode === 'both') {
    jobs.push({ id: 'ars', currencyId: CURRENCY.ars, rate: rates.ars })
  }

  for (const job of jobs) {
    const rateWei = toWei18(job.rate)
    console.log(`[feeder] USD/${job.id.toUpperCase()}=${job.rate} → ratePerUsd=${rateWei}`)
    const tx = postRate(deployments, job.currencyId, rateWei)
    console.log(`[feeder] posted ${job.id} ok\n${tx}`)
  }
}

async function main() {
  console.log(
    `[feeder] rpc=${RPC_URL} interval=${INTERVAL_MS}ms once=${once} currency=${currencyMode}`,
  )
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
