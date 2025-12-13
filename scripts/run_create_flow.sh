#!/usr/bin/env bash
set -euo pipefail

echo "=== CharmStream CREATE Flow (testnet4) ==="
echo ""

# 1. Build app
echo "[1/9] Building WASM app..."
charms app build > /dev/null 2>&1 || { echo "Failed to build app. Run: charms app build"; exit 1; }
export app_bin="target/wasm32-wasip1/release/charmstream.wasm"
export app_vk=$(charms app vk "$app_bin")
echo "  app_vk: $app_vk"

# 2. Pick UTXO
echo ""
echo "[2/9] Listing your UTXOs..."
bitcoin-cli listunspent | jq -r '.[] | "\(.txid):\(.vout) -> \(.amount) BTC (\(.address))"'
echo ""
echo "⚠️  WARNING: Pick a FRESH UTXO that hasn't been used in previous attempts!"
echo "   (If you see 'duplicate funding UTXO' error, the UTXO was already tried)"
echo ""
read -p "Enter UTXO to spend (format: txid:vout): " in_utxo_0
export in_utxo_0

# 3. Get UTXO value
txid=$(echo "$in_utxo_0" | cut -d: -f1)
vout=$(echo "$in_utxo_0" | cut -d: -f2)
echo ""
echo "[3/9] Fetching UTXO details..."
utxo_info=$(bitcoin-cli gettxout "$txid" "$vout")
if [ -z "$utxo_info" ] || [ "$utxo_info" = "null" ]; then
  echo "ERROR: UTXO not found or already spent!"
  exit 1
fi
utxo_value_btc=$(echo "$utxo_info" | jq -r '.value')
export funding_value_sats=$(python3 -c "print(int(float('$utxo_value_btc') * 1e8))")
echo "  UTXO value: $funding_value_sats sats"

# 4. Set stream parameters
echo ""
echo "[4/9] Setting stream parameters..."
while true; do
  read -p "Enter stream amount in sats (min 5000 to avoid dust after fees, e.g., 20000): " total_amount
  if [ "$total_amount" -ge 5000 ]; then
    export total_amount
    break
  else
    echo "  ERROR: Amount must be at least 5000 sats (dust + fee threshold)"
  fi
done
export start_time=$(date -u +%s)
read -p "Enter stream duration in seconds (e.g., 3600 for 1 hour): " duration
export end_time=$((start_time + duration))
export now=$start_time

echo "  total_amount: $total_amount sats"
echo "  start_time: $start_time ($(date -u -r $start_time))"
echo "  end_time: $end_time ($(date -u -r $end_time))"

# 5. Set addresses
echo ""
echo "[5/9] Setting addresses..."
read -p "Enter stream address (addr_0) [default: tb1pq3p7sy9t6rycwyzp554s34arqqm367j0gw47hy5x7u6ch7fss3tsf972yx]: " addr_0_input
export addr_0="${addr_0_input:-tb1pq3p7sy9t6rycwyzp554s34arqqm367j0gw47hy5x7u6ch7fss3tsf972yx}"

read -p "Enter beneficiary address [default: same as stream]: " beneficiary_addr_input
export beneficiary_addr="${beneficiary_addr_input:-$addr_0}"

echo "  Stream address: $addr_0"
echo "  Beneficiary address: $beneficiary_addr"

# 6. Derive beneficiary_dest
echo ""
echo "[6/9] Deriving beneficiary scriptPubKey..."
export beneficiary_dest_hex=$(bitcoin-cli getaddressinfo "$beneficiary_addr" | jq -r '.scriptPubKey')
if [ -z "$beneficiary_dest_hex" ] || [ "$beneficiary_dest_hex" = "null" ]; then
  echo "ERROR: Could not resolve scriptPubKey for $beneficiary_addr"
  exit 1
fi
echo "  beneficiary_dest_hex: ${beneficiary_dest_hex}"

# 7. Derive app_id
echo ""
echo "[7/9] Deriving app_id from funding UTXO..."
export app_id=$(printf "%s" "$in_utxo_0" | shasum -a 256 | cut -d' ' -f1)
echo "  app_id: $app_id"

# 8. Fetch prev tx
echo ""
echo "[8/9] Fetching previous transaction..."
bitcoin-cli getrawtransaction "$txid" > /tmp/prev0.hex
export PREV_TXS=$(cat /tmp/prev0.hex)
echo "  Prev tx fetched ($(wc -c < /tmp/prev0.hex) bytes)"

# 9. Prove spell (skip check since our contract needs coin_outs which check doesn't populate)
echo ""
echo "[9/9] Proving spell..."
mkdir -p .build

echo "  Running spell prove (this may take a minute)..."
if ! envsubst < spells/create-stream.yaml | charms spell prove \
  --funding-utxo="$in_utxo_0" \
  --funding-utxo-value="$funding_value_sats" \
  --change-address="$addr_0" \
  --prev-txs="$PREV_TXS" \
  --app-bins="$app_bin" > .build/create.raw 2>&1; then
  echo ""
  echo "ERROR: Proof generation failed!"
  echo "Common causes:"
  echo "  - UTXO already used in another tx (pick different UTXO)"
  echo "  - Contract validation failed"
  cat .build/create.raw
  exit 1
fi

echo ""
echo "=== Proof generated successfully! ==="
echo ""
echo "Extracting hex from JSON output..."
if ! jq -r '.[1].bitcoin' .build/create.raw > .build/create.hex 2>/dev/null; then
  echo "ERROR: Could not extract hex from prove output"
  cat .build/create.raw
  exit 1
fi
echo "Raw transaction saved to: .build/create.hex"
echo ""
echo "To decode and inspect:"
echo "  bitcoin-cli decoderawtransaction \$(cat .build/create.hex) | jq"
echo ""
echo "To broadcast:"
echo "  bitcoin-cli sendrawtransaction \$(cat .build/create.hex)"
echo ""
echo "After broadcasting, note the txid and find the stream output index (usually 0)."
echo "Then set: export stream_utxo_0=\"TXID:INDEX\""
echo ""
echo "=== Environment variables for claim flow ==="
echo "export app_bin=\"$app_bin\""
echo "export app_vk=\"$app_vk\""
echo "export app_id=\"$app_id\""
echo "export addr_0=\"$addr_0\""
echo "export beneficiary_addr=\"$beneficiary_addr\""
echo "export beneficiary_dest_hex=\"$beneficiary_dest_hex\""
echo "export total_amount=$total_amount"
echo "export start_time=$start_time"
echo "export end_time=$end_time"

