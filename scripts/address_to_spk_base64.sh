#!/usr/bin/env bash
set -euo pipefail

# Usage: BITCOIN_CHAIN=testnet4 scripts/address_to_spk_base64.sh tb1q...

ADDR=${1:?pass bech32 address}
CHAIN=${BITCOIN_CHAIN:-testnet4}

INFO=$(bitcoin-cli -chain="$CHAIN" getaddressinfo "$ADDR")
HEX=$(echo "$INFO" | jq -r '.scriptPubKey')

if [ -z "$HEX" ] || [ "$HEX" = "null" ]; then
  echo "Could not resolve scriptPubKey for $ADDR" >&2
  exit 1
fi

echo "$HEX" | xxd -r -p | base64

