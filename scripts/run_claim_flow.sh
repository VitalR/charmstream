#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_claim_flow.sh [--help]
Environment overrides:
  BTC_CMD   bitcoin-cli command (default "bitcoin-cli -testnet4")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

BTC_CMD=${BTC_CMD:-"bitcoin-cli -testnet4"}
read -r -a BTC <<<"$BTC_CMD"

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

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local input=""
  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

write_context() {
  local file="$1"
  shift
  {
    echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '%s\n' "$@"
  } >"$file"
}

validate_prev_tx() {
  local expected_txid="$1"
  local expected_vout="$2"
  local hex="$3"
  local label="$4"

  local decoded
  if ! decoded=$("${BTC[@]}" decoderawtransaction "$hex"); then
    echo "ERROR: Could not decode $label prev tx for $expected_txid" >&2
    exit 1
  fi
  local actual_txid
  actual_txid=$(jq -r '.txid' <<<"$decoded")
  if [ "$actual_txid" != "$expected_txid" ]; then
    echo "ERROR: Prev tx ($label) txid mismatch: expected $expected_txid got $actual_txid" >&2
    exit 1
  fi
  if ! jq -e --argjson v "$expected_vout" '.vout[] | select(.n == $v)' <<<"$decoded" >/dev/null; then
    echo "ERROR: Prev tx ($label) missing vout $expected_vout" >&2
    exit 1
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
if [ -z "${stream_dest_hex:-}" ]; then
  stream_dest_hex=$("${BTC[@]}" getaddressinfo "$addr_0" | jq -r '.scriptPubKey')
fi
export stream_dest_hex
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
stream_info=$("${BTC[@]}" gettxout "$stream_txid" "$stream_vout")
if [ -z "$stream_info" ] || [ "$stream_info" = "null" ]; then
  echo "ERROR: Stream UTXO not found or already spent!"
  exit 1
fi
stream_value_btc=$(echo "$stream_info" | jq -r '.value')
stream_value_sats=$(python3 -c "print(int(float('$stream_value_btc') * 1e8))")
export stream_value_sats
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
"${BTC[@]}" listunspent | jq -r '.[] | select(.txid != "'$stream_txid'") | "\(.txid):\(.vout) -> \(.amount) BTC"'
echo ""
read -p "Enter fee funding UTXO (format: txid:vout): " fee_utxo
if [ "$fee_utxo" = "$stream_utxo_0" ]; then
  echo "ERROR: Fee UTXO must differ from stream UTXO."
  exit 1
fi
ensure_utxo_unused "$fee_utxo"

fee_txid=$(echo "$fee_utxo" | cut -d: -f1)
fee_vout=$(echo "$fee_utxo" | cut -d: -f2)
fee_info=$("${BTC[@]}" gettxout "$fee_txid" "$fee_vout")
fee_value_btc=$(echo "$fee_info" | jq -r '.value')
fee_value_sats=$(python3 -c "print(int(float('$fee_value_btc') * 1e8))")
echo "  Fee UTXO value: $fee_value_sats sats"
if [ "$fee_value_sats" -lt 20000 ]; then
  echo "ERROR: Fee funding UTXO must be at least 20000 sats"
  exit 1
fi

export funding_utxo="$fee_utxo"
export funding_value_sats="$fee_value_sats"
change_addr_input=$(prompt_with_default "Enter change address (default: stream address)" "$addr_0")
change_addr="$change_addr_input"
echo "  Change address: $change_addr"
if ! "${BTC[@]}" getaddressinfo "$change_addr" >/dev/null; then
  echo "ERROR: Invalid change address $change_addr"
  exit 1
fi

# 5. Fetch prev txs (deduplicate if same parent)
echo ""
echo "[5/6] Fetching previous transactions..."
"${BTC[@]}" getrawtransaction "$stream_txid" > /tmp/prev_stream.hex
stream_prev_hex=$(tr -d '\n' < /tmp/prev_stream.hex)
validate_prev_tx "$stream_txid" "$stream_vout" "$stream_prev_hex" "stream"

if [ "$stream_txid" = "$fee_txid" ]; then
  export PREV_TXS="$stream_prev_hex"
  echo "  Prev tx fetched (shared parent)"
else
  "${BTC[@]}" getrawtransaction "$fee_txid" > /tmp/prev_fee.hex
  fee_prev_hex=$(tr -d '\n' < /tmp/prev_fee.hex)
  validate_prev_tx "$fee_txid" "$fee_vout" "$fee_prev_hex" "funding"
  export PREV_TXS="$stream_prev_hex,$fee_prev_hex"
  echo "  Prev txs fetched (stream + fee)"
fi

# 6. Prove spell (skip check since our contract needs coin_outs which check doesn't populate)
echo ""
echo "[6/6] Proving claim spell..."

claim_rendered="$BUILD_DIR/claim.rendered.yaml"
envsubst < spells/claim-stream.yaml > "$claim_rendered"
claim_spell_hash=$(shasum -a 256 "$claim_rendered" | awk '{print $1}')
echo "  Rendered spell: $claim_rendered"
echo "  Spell SHA256: $claim_spell_hash"

write_context "$BUILD_DIR/claim.context.txt" \
  "spell_hash=$claim_spell_hash" \
  "stream_utxo=$stream_utxo_0" \
  "funding_utxo=$funding_utxo" \
  "funding_value_sats=$funding_value_sats" \
  "claimed_before=$claimed_before" \
  "claimed_after=$claimed_after" \
  "payout_sats=$payout_sats" \
  "remaining_sats=$remaining_sats" \
  "stream_value_sats=$stream_value_sats" \
  "change_addr=$change_addr" \
  "prev_stream_txid=$stream_txid" \
  "prev_fund_txid=$fee_txid"

echo "$PREV_TXS" > "$BUILD_DIR/claim.prevtxs.txt"
claim_prove_cmd=(
  charms spell prove
  --funding-utxo="$funding_utxo"
  --funding-utxo-value="$funding_value_sats"
  --change-address="$change_addr"
  --prev-txs="$PREV_TXS"
  --app-bins="$app_bin"
)
claim_cmd_pretty=$(printf "%q " "${claim_prove_cmd[@]}")
printf "%s < %s\n" "$claim_cmd_pretty" "$claim_rendered" > "$BUILD_DIR/claim.command.txt"
echo "  Prover command: $claim_cmd_pretty < $claim_rendered"

echo "  Running spell prove (this may take a minute)..."
record_utxo "$stream_utxo_0"
record_utxo "$funding_utxo"
if ! "${claim_prove_cmd[@]}" < "$claim_rendered" > "$BUILD_DIR/claim.raw" 2>&1; then
  echo ""
  echo "ERROR: Proof generation failed!"
  echo "Common causes:"
  echo "  - Fee UTXO already used"
  echo "  - Stream UTXO already claimed/spent"
  echo "  - Contract validation failed"
  cat "$BUILD_DIR/claim.raw"
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
claim_decoded=$("${BTC[@]}" decoderawtransaction "$(cat .build/claim.hex)")
claim_stream_index=$(
  jq -r --arg spk "$stream_dest_hex" --argjson sats "$remaining_sats" '
    .vout[]
    | select(.scriptPubKey.hex == $spk)
    | select(((.value * 100000000) | round) == $sats)
    | .n
  ' <<<"$claim_decoded" | head -n 1
)
if [ -z "$claim_stream_index" ]; then
  echo "ERROR: Could not determine updated stream output index"
  exit 1
fi
echo "  Updated stream vout index: $claim_stream_index"

check_vin() {
  local txid="$1"
  local vout="$2"
  local label="$3"
  if ! jq -e --arg tx "$txid" --argjson v "$vout" '.vin[] | select(.txid == $tx and .vout == $v)' <<<"$claim_decoded" >/dev/null; then
    echo "ERROR: Built claim transaction missing $label input ($txid:$vout)" >&2
    exit 1
  fi
}
check_vin "$stream_txid" "$stream_vout" "stream"
check_vin "$fee_txid" "$fee_vout" "funding"

if ! jq -e --arg spk "$beneficiary_dest_hex" --argjson sats "$payout_sats" '
      .vout[] | select(.scriptPubKey.hex == $spk) | select(((.value * 100000000) | round) == $sats)
    ' <<<"$claim_decoded" >/dev/null; then
  echo "ERROR: Could not find payout output matching beneficiary + amount" >&2
  exit 1
fi

echo "Broadcasting claim transaction..."
claim_hex=$(cat .build/claim.hex)
if CLAIM_TXID=$("${BTC[@]}" sendrawtransaction "$claim_hex" 2>&1); then
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
  echo "You can decode the tx via: ${BTC_CMD} decoderawtransaction \"\$(cat .build/claim.hex)\""
  exit 1
fi
