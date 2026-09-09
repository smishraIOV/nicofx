#!/usr/bin/env bash
# Regenerate the dApp's ABI files from the latest forge build output.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build --skip test >/dev/null 2>&1
for name in USD SettlementToken Oracle ProtocolHub CurrencyBucket NettingSession; do
  jq '.abi' "out/${name}.sol/${name}.json" > "app/src/contracts/${name}.abi.json"
  echo "synced ${name}.abi.json"
done
