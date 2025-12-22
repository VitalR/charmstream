#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=".build"
mkdir -p "$BUILD_DIR"
USED_UTXO_LOG="$BUILD_DIR/used_utxos.txt"
touch "$USED_UTXO_LOG"

ensure_utxo_unused() {
  local utxo="$1"
  if grep -Fxq "$utxo" "$USED_UTXO_LOG"; then
    echo "ERROR: UTXO $utxo was already used in a prior spell prove. Choose a different UTXO."
    exit 1
  fi
}

record_utxo() {
  local utxo="$1"
  if ! grep -Fxq "$utxo" "$USED_UTXO_LOG"; then
    echo "$utxo" >> "$USED_UTXO_LOG"
  fi
}

ENV_FILE="$BUILD_DIR/env.sh"
if [ -f "$ENV_FILE" ]; then
  echo "Loading $ENV_FILE..."
  # shellcheck disable=SC1091
  source "$ENV_FILE"
fi

echo "=== CharmStream CLAIM Flow (testnet4) ==="
echo ""

# Check required env vars from create flow
required_vars=(app_bin app_vk app_id addr_0 beneficiary_addr beneficiary_dest_hex total_amount start_time end_time)
missing_vars=()
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing_vars+=("$var")
  fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
  echo "ERROR: Missing required environment variables from create flow:"
  for var in "${missing_vars[@]}"; do
    echo "  - $var"
  done
  echo ""
  echo "Please run the create flow first or set these manually."
  exit 1
fi

echo "Using existing environment:"
echo "  app_vk: $app_vk"
echo "  app_id: $app_id"
echo "  total_amount: $total_amount sats"
echo "  stream period: $start_time -> $end_time"
echo ""
export stream_dest_hex=${stream_dest_hex:-$(bitcoin-cli getaddressinfo "$addr_0" | jq -r '.scriptPubKey')}
if [ -z "$stream_dest_hex" ] || [ "$stream_dest_hex" = "null" ]; then
  echo "ERROR: Could not resolve scriptPubKey for $addr_0"
  exit 1
fi

export claimed_amount=${claimed_amount:-0}

# 1. Get stream UTXO
echo "[1/6] Identifying stream UTXO..."
default_stream="${stream_utxo_0:-}"
prompt_suffix=""
if [ -n "$default_stream" ]; then
  prompt_suffix=" [default: $default_stream]"
fi
read -p "Enter stream UTXO (format: txid:vout, from create tx)$prompt_suffix: " stream_input
if [ -z "$stream_input" ]; then
  if [ -z "$default_stream" ]; then
    echo "ERROR: Stream UTXO is required"
    exit 1
  fi
  stream_utxo_0="$default_stream"
else
  stream_utxo_0="$stream_input"
fi
ensure_utxo_unused "$stream_utxo_0"
export stream_utxo_0

stream_txid=$(echo "$stream_utxo_0" | cut -d: -f1)
stream_vout=$(echo "$stream_utxo_0" | cut -d: -f2)

# 2. Verify stream UTXO exists
echo ""
echo "[2/6] Verifying stream UTXO..."
stream_info=$(bitcoin-cli gettxout "$stream_txid" "$stream_vout")
if [ -z "$stream_info" ] || [ "$stream_info" = "null" ]; then
  echo "ERROR: Stream UTXO not found or already spent!"
  exit 1
fi
stream_value_btc=$(echo "$stream_info" | jq -r '.value')
stream_value_sats=$(python3 -c "print(int(float('$stream_value_btc') * 1e8))")
echo "  Stream UTXO value: $stream_value_sats sats"

# 3. Set claim parameters
echo ""
echo "[3/6] Setting claim parameters..."
export claimed_before=$claimed_amount
echo "  Current time: $(date -u)"
export now=$(date -u +%s)

if [ $now -lt $start_time ]; then
  echo "  WARNING: Current time is before stream start!"
fi

vested_pct=$(python3 -c "
import sys
now, start, end, total = $now, $start_time, $end_time, $total_amount
if now <= start:
    vested = 0
elif now >= end:
    vested = total
else:
    elapsed = now - start
    duration = end - start
    vested = int((total * elapsed) / duration)
print(f'{vested}')
")

echo "  Vested amount: $vested_pct sats (max claimable)"
read -p "Enter amount to claim (sats, max $vested_pct): " claimed_after
export claimed_after

if [ "$claimed_after" -gt "$vested_pct" ]; then
  echo "ERROR: Claiming more than vested amount!"
  exit 1
fi
if [ "$claimed_after" -lt "$claimed_before" ]; then
  echo "ERROR: claimed_after must be >= claimed_before ($claimed_before)"
  exit 1
fi

export payout_sats=$((claimed_after - claimed_before))
export remaining_sats=$((total_amount - claimed_after))

echo "  claimed_before: $claimed_before"
echo "  claimed_after: $claimed_after"
echo "  payout_sats: $payout_sats"
echo "  remaining_sats: $remaining_sats"

# Need funding for fee
echo ""
echo "[4/6] Select fee funding UTXO..."
bitcoin-cli listunspent | jq -r '.[] | select(.txid != "'$stream_txid'") | "\(.txid):\(.vout) -> \(.amount) BTC"'
echo ""
read -p "Enter fee funding UTXO (format: txid:vout): " fee_utxo
if [ "$fee_utxo" = "$stream_utxo_0" ]; then
  echo "ERROR: Fee UTXO must differ from stream UTXO."
  exit 1
fi
ensure_utxo_unused "$fee_utxo"

fee_txid=$(echo "$fee_utxo" | cut -d: -f1)
fee_vout=$(echo "$fee_utxo" | cut -d: -f2)
fee_info=$(bitcoin-cli gettxout "$fee_txid" "$fee_vout")
fee_value_btc=$(echo "$fee_info" | jq -r '.value')
fee_value_sats=$(python3 -c "print(int(float('$fee_value_btc') * 1e8))")
echo "  Fee UTXO value: $fee_value_sats sats"

export funding_utxo="$fee_utxo"
export funding_value_sats="$fee_value_sats"
export change_addr=$(bitcoin-cli getnewaddress "charmstream-claim-change" bech32)
echo "  Change address: $change_addr"

# 5. Fetch prev txs (deduplicate if same parent)
echo ""
echo "[5/6] Fetching previous transactions..."
bitcoin-cli getrawtransaction "$stream_txid" > /tmp/prev_stream.hex

if [ "$stream_txid" = "$fee_txid" ]; then
  # Same parent tx, only include once
  export PREV_TXS="$(tr -d '\n' < /tmp/prev_stream.hex)"
  echo "  Prev tx fetched (shared parent)"
else
  # Different parent txs, include both comma-separated
  bitcoin-cli getrawtransaction "$fee_txid" > /tmp/prev_fee.hex
  export PREV_TXS="$(tr -d '\n' < /tmp/prev_stream.hex),$(tr -d '\n' < /tmp/prev_fee.hex)"
  echo "  Prev txs fetched (stream + fee)"
fi

# 6. Prove spell (skip check since our contract needs coin_outs which check doesn't populate)
echo ""
echo "[6/6] Proving claim spell..."

echo "  Running spell prove (this may take a minute)..."
record_utxo "$stream_utxo_0"
record_utxo "$funding_utxo"
if ! envsubst < spells/claim-stream.yaml | charms spell prove \
  --funding-utxo="$funding_utxo" \
  --funding-utxo-value="$funding_value_sats" \
  --change-address="$change_addr" \
  --prev-txs="$PREV_TXS" \
  --app-bins="$app_bin" > .build/claim.raw 2>&1; then
  echo ""
  echo "ERROR: Proof generation failed!"
  echo "Common causes:"
  echo "  - Fee UTXO already used"
  echo "  - Stream UTXO already claimed/spent"
  echo "  - Contract validation failed"
  cat .build/claim.raw
  exit 1
fi

echo ""
echo "=== Proof generated successfully! ==="
echo ""
echo "Extracting hex from JSON output..."
if ! jq -r '.[1].bitcoin' .build/claim.raw > .build/claim.hex 2>/dev/null; then
  echo "ERROR: Could not extract hex from prove output"
  cat .build/claim.raw
  exit 1
fi
echo "Raw transaction saved to: .build/claim.hex"
echo ""

echo "Locating updated stream output index..."
claim_stream_index=$(
  bitcoin-cli decoderawtransaction "$(cat .build/claim.hex)" |
    jq -r --arg spk "$stream_dest_hex" --argjson sats "$remaining_sats" '
      .vout[]
      | select(.scriptPubKey.hex == $spk)
      | select(((.value * 100000000) | round) == $sats)
      | .n
    ' | head -n 1
)
if [ -z "$claim_stream_index" ]; then
  echo "ERROR: Could not determine updated stream output index"
  exit 1
fi
echo "  Updated stream vout index: $claim_stream_index"

echo "Broadcasting claim transaction..."
claim_hex=$(cat .build/claim.hex)
if CLAIM_TXID=$(bitcoin-cli sendrawtransaction "$claim_hex" 2>&1); then
  echo ""
  echo "=== CLAIM SUCCESS ==="
  echo ""
  export stream_utxo_0="$CLAIM_TXID:$claim_stream_index"
  export claimed_amount="$claimed_after"
  echo "Claim TXID: $CLAIM_TXID"
  echo "Updated Stream UTXO: $stream_utxo_0"
  echo ""
  echo "View on explorer:"
  echo "https://mempool.space/testnet4/tx/$CLAIM_TXID"
  echo ""

  cat > "$ENV_FILE" <<EOF
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
export claimed_amount=$claimed_amount
EOF
  echo "Saved updated environment to $ENV_FILE"
  echo ""
  echo "Updated environment variables:"
  echo "export stream_utxo_0=\"$stream_utxo_0\""
  echo "export claimed_amount=$claimed_amount"
else
  echo ""
  echo "ERROR: Broadcast failed: $CLAIM_TXID"
  echo "You can decode the tx via: bitcoin-cli decoderawtransaction \"\$(cat .build/claim.hex)\""
  exit 1
fi
