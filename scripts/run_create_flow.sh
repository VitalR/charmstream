#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=".build"
mkdir -p "$BUILD_DIR"
USED_UTXO_LOG="$BUILD_DIR/used_utxos.txt"
touch "$USED_UTXO_LOG"

ensure_utxo_unused() {
  local utxo="$1"
  if grep -Fxq "$utxo" "$USED_UTXO_LOG"; then
    echo "ERROR: UTXO $utxo was already used in a prior spell prove. Pick a different UTXO."
    exit 1
  fi
}

record_utxo() {
  local utxo="$1"
  if ! grep -Fxq "$utxo" "$USED_UTXO_LOG"; then
    echo "$utxo" >> "$USED_UTXO_LOG"
  fi
}

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
echo "[2/9] Listing your UTXOs (including unconfirmed)..."
bitcoin-cli listunspent 0 9999999 | jq -r '.[] | "[\(.confirmations) conf] \(.txid):\(.vout) -> \(.amount) BTC"' | sort -rn
echo ""
echo "WARNING: Pick FRESH UTXOs that haven't been used in previous attempts!"
echo "   - One UTXO funds the stream (locked into StreamState)"
echo "   - A different UTXO funds fees/change (funding_utxo)"
echo ""
read -p "Enter STREAM UTXO (format: txid:vout): " stream_utxo_0
read -p "Enter FEE FUNDING UTXO (format: txid:vout, must differ): " funding_utxo
if [ "$stream_utxo_0" = "$funding_utxo" ]; then
  echo "ERROR: Stream UTXO and funding UTXO must be different."
  exit 1
fi
ensure_utxo_unused "$stream_utxo_0"
ensure_utxo_unused "$funding_utxo"
export stream_utxo_0
export funding_utxo
export in_utxo_0="$stream_utxo_0"

# 3. Get UTXO values
stream_txid=$(echo "$stream_utxo_0" | cut -d: -f1)
stream_vout=$(echo "$stream_utxo_0" | cut -d: -f2)
fund_txid=$(echo "$funding_utxo" | cut -d: -f1)
fund_vout=$(echo "$funding_utxo" | cut -d: -f2)
echo ""
echo "[3/9] Fetching UTXO details..."
stream_info=$(bitcoin-cli gettxout "$stream_txid" "$stream_vout")
fund_info=$(bitcoin-cli gettxout "$fund_txid" "$fund_vout")
if [ -z "$stream_info" ] || [ "$stream_info" = "null" ]; then
  echo "ERROR: Stream UTXO not found or already spent!"
  exit 1
fi
if [ -z "$fund_info" ] || [ "$fund_info" = "null" ]; then
  echo "ERROR: Funding UTXO not found or already spent!"
  exit 1
fi
stream_value_btc=$(echo "$stream_info" | jq -r '.value')
fund_value_btc=$(echo "$fund_info" | jq -r '.value')
export stream_value_sats=$(python3 -c "print(int(float('$stream_value_btc') * 1e8))")
export funding_value_sats=$(python3 -c "print(int(float('$fund_value_btc') * 1e8))")
echo "  Stream UTXO value:  $stream_value_sats sats"
echo "  Funding UTXO value: $funding_value_sats sats"

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
export change_addr=$(bitcoin-cli getnewaddress "charmstream-create-change" bech32)
echo "  Change address: $change_addr"

# 6. Derive scriptPubKeys
echo ""
echo "[6/9] Deriving scriptPubKeys..."
export stream_dest_hex=$(bitcoin-cli getaddressinfo "$addr_0" | jq -r '.scriptPubKey')
if [ -z "$stream_dest_hex" ] || [ "$stream_dest_hex" = "null" ]; then
  echo "ERROR: Could not resolve scriptPubKey for $addr_0"
  exit 1
fi
echo "  stream_dest_hex: ${stream_dest_hex}"

export beneficiary_dest_hex=$(bitcoin-cli getaddressinfo "$beneficiary_addr" | jq -r '.scriptPubKey')
if [ -z "$beneficiary_dest_hex" ] || [ "$beneficiary_dest_hex" = "null" ]; then
  echo "ERROR: Could not resolve scriptPubKey for $beneficiary_addr"
  exit 1
fi
echo "  beneficiary_dest_hex: ${beneficiary_dest_hex}"

# 7. Derive app_id
echo ""
echo "[7/9] Deriving app_id from stream UTXO..."
export app_id=$(printf "%s" "$stream_utxo_0" | shasum -a 256 | cut -d' ' -f1)
echo "  app_id: $app_id"

# 8. Fetch prev tx (deduplicate if same parent)
echo ""
echo "[8/9] Fetching previous transaction..."
bitcoin-cli getrawtransaction "$stream_txid" > /tmp/prev_stream.hex

if [ "$stream_txid" = "$fund_txid" ]; then
  # Same parent tx, only include once
  export PREV_TXS="$(tr -d '\n' < /tmp/prev_stream.hex)"
  echo "  Prev tx fetched (shared parent)"
else
  # Different parent txs, include both
  bitcoin-cli getrawtransaction "$fund_txid" > /tmp/prev_fund.hex
  export PREV_TXS="$(tr -d '\n' < /tmp/prev_stream.hex),$(tr -d '\n' < /tmp/prev_fund.hex)"
  echo "  Prev txs fetched (stream + funding)"
fi

# 9. Prove spell (skip check since our contract needs coin_outs which check doesn't populate)
echo ""
echo "[9/9] Proving spell..."
echo "  Running spell prove (this may take a minute)..."
record_utxo "$stream_utxo_0"
record_utxo "$funding_utxo"
if ! envsubst < spells/create-stream.yaml | charms spell prove \
  --funding-utxo="$funding_utxo" \
  --funding-utxo-value="$funding_value_sats" \
  --change-address="$change_addr" \
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
if ! tail -1 .build/create.raw | jq -r '.[1].bitcoin' > .build/create.hex 2>/dev/null; then
  echo "ERROR: Could not extract hex from prove output"
  cat .build/create.raw
  exit 1
fi
echo "Transaction hex extracted ($(wc -c < .build/create.hex | tr -d ' ') bytes)"
echo ""

echo "Locating stream output index..."
stream_vout_index=$(
  bitcoin-cli decoderawtransaction "$(cat .build/create.hex)" |
    jq -r --arg spk "$stream_dest_hex" --argjson sats "$total_amount" '
      .vout[]
      | select(.scriptPubKey.hex == $spk)
      | select(((.value * 100000000) | round) == $sats)
      | .n
    ' | head -n 1
)
if [ -z "$stream_vout_index" ]; then
  echo "ERROR: Could not determine stream output index"
  exit 1
fi
echo "  Stream output index: $stream_vout_index"

# Auto-broadcast
echo "Broadcasting transaction..."
create_hex=$(cat .build/create.hex)
if STREAM_TXID=$(bitcoin-cli sendrawtransaction "$create_hex" 2>&1); then
  echo ""
  echo "=== CREATE STREAM SUCCESS ==="
  echo ""
  echo "Stream TXID: $STREAM_TXID"
  export stream_utxo_0="$STREAM_TXID:$stream_vout_index"
  echo "Stream UTXO: $stream_utxo_0"
  echo ""
  echo "View on explorer:"
  echo "https://mempool.space/testnet4/tx/$STREAM_TXID"
  echo ""
  
  # Export for claim flow
  export STREAM_TXID
else
  echo ""
  echo "ERROR: Broadcast failed: $STREAM_TXID"
  echo ""
  echo "Common causes:"
  echo "  - Funding UTXO was spent by another user (race condition)"
  echo "  - Parent tx not in network mempool yet"
  echo "  - Try running the script again immediately"
  exit 1
fi
echo ""
echo "=== Environment variables for claim flow ==="
echo "export app_bin=\"$app_bin\""
echo "export app_vk=\"$app_vk\""
echo "export app_id=\"$app_id\""
echo "export addr_0=\"$addr_0\""
echo "export beneficiary_addr=\"$beneficiary_addr\""
echo "export beneficiary_dest_hex=\"$beneficiary_dest_hex\""
echo "export stream_dest_hex=\"$stream_dest_hex\""
echo "export total_amount=$total_amount"
echo "export start_time=$start_time"
echo "export end_time=$end_time"
echo "export stream_utxo_0=\"$stream_utxo_0\""
echo "export claimed_amount=0"

cat > "$BUILD_DIR/env.sh" <<EOF
export app_bin="$app_bin"
export app_vk="$app_vk"
export app_id="$app_id"
export addr_0="$addr_0"
export beneficiary_addr="$beneficiary_addr"
export beneficiary_dest_hex="$beneficiary_dest_hex"
export stream_dest_hex="$stream_dest_hex"
export total_amount=$total_amount
export start_time=$start_time
export end_time=$end_time
export stream_utxo_0="$stream_utxo_0"
export claimed_amount=0
EOF
echo ""
echo "Saved environment to $BUILD_DIR/env.sh (source this file before running claim flow)."

