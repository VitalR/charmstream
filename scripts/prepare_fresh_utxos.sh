#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/prepare_fresh_utxos.sh

Purpose:
  Create (or reuse) two wallet-controlled addresses and produce two fresh confirmed UTXOs:
    - STREAM outpoint: used as stream_utxo_0 in run_create_flow.sh
    - FEE outpoint:    used as funding_utxo in run_create_flow.sh

Defaults assume testnet4. This script does NOT modify create/claim logic; it only helps
generate fresh outpoints to avoid prover reservation/caching issues.

Environment overrides:
  BTC_CMD           bitcoin-cli command (default: "bitcoin-cli -testnet4")
  STREAM_ADDR       if set, use this address instead of creating a new one
  FEE_ADDR          if set, use this address instead of creating a new one
  STREAM_AMOUNT_BTC default stream send amount (default: 0.001)
  FEE_AMOUNT_BTC    default fee send amount (default: 0.0015)
  FEE_RATE_SATVB    fee_rate for sendtoaddress (default: 5)
  MIN_CONFIRMATIONS confirmations to wait for (default: 1)

Output:
  Prints STREAM_UTXO and FUNDING_UTXO as txid:vout, ready to paste into:
    ./scripts/run_create_flow.sh --repro
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

BTC_CMD=${BTC_CMD:-"bitcoin-cli -testnet4"}
read -r -a BTC <<<"$BTC_CMD"

BUILD_DIR=".build"
USED_UTXO_LOG="$BUILD_DIR/used_utxos.txt"
mkdir -p "$BUILD_DIR"
touch "$USED_UTXO_LOG"

STREAM_AMOUNT_BTC=${STREAM_AMOUNT_BTC:-0.001}
FEE_AMOUNT_BTC=${FEE_AMOUNT_BTC:-0.0015}
FEE_RATE_SATVB=${FEE_RATE_SATVB:-5}
MIN_CONFIRMATIONS=${MIN_CONFIRMATIONS:-1}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local input=""
  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

is_number() {
  # Accept integers or decimals (e.g. 0.001, 1, 10.5)
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

prompt_number_with_default() {
  local prompt="$1"
  local default="$2"
  local input=""
  while true; do
    read -p "$prompt [$default]: " input
    input="${input:-$default}"
    if is_number "$input"; then
      echo "$input"
      return 0
    fi
    echo "ERROR: Please enter a numeric value (example: $default)" >&2
  done
}

prompt_int_with_default() {
  local prompt="$1"
  local default="$2"
  local input=""
  while true; do
    read -p "$prompt [$default]: " input
    input="${input:-$default}"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      echo "$input"
      return 0
    fi
    echo "ERROR: Please enter an integer value (example: $default)" >&2
  done
}

require_address() {
  local addr="$1"
  if [ -z "$addr" ]; then
    echo "ERROR: address is empty" >&2
    exit 1
  fi
  if ! "${BTC[@]}" getaddressinfo "$addr" >/dev/null 2>&1; then
    echo "ERROR: Invalid address: $addr" >&2
    exit 1
  fi
}

print_used_hint() {
  if [ -s "$USED_UTXO_LOG" ]; then
    echo "Note: existing used outpoints recorded in $USED_UTXO_LOG"
  else
    echo "Note: $USED_UTXO_LOG is empty"
  fi
}

find_outpoint_by_txid() {
  local txid="$1"
  local minconf="$2"

  "${BTC[@]}" listunspent "$minconf" 9999999 | jq -r --arg txid "$txid" '
    .[] | select(.txid == $txid) | "\(.txid):\(.vout)"
  ' | head -n 1
}

ensure_not_used() {
  local outpoint="$1"
  if grep -Fxq "$outpoint" "$USED_UTXO_LOG"; then
    echo "WARNING: $outpoint is already listed in $USED_UTXO_LOG"
    echo "         Pick a different outpoint (or create another fresh send)."
  fi
}

echo "=== Prepare fresh UTXOs (testnet4) ==="
echo ""
print_used_hint
echo ""

echo "Using BTC_CMD: $BTC_CMD"
echo ""

stream_addr=${STREAM_ADDR:-$("${BTC[@]}" getnewaddress "charmstream-stream" "bech32")}
fee_addr=${FEE_ADDR:-$("${BTC[@]}" getnewaddress "charmstream-fee" "bech32")}

require_address "$stream_addr"
require_address "$fee_addr"

echo "Stream address: $stream_addr"
echo "Fee address:    $fee_addr"
echo ""

stream_amount=$(prompt_number_with_default "Send amount to STREAM address (BTC)" "$STREAM_AMOUNT_BTC")
fee_amount=$(prompt_number_with_default "Send amount to FEE address (BTC)" "$FEE_AMOUNT_BTC")
fee_rate=$(prompt_int_with_default "Fee rate (sat/vB)" "$FEE_RATE_SATVB")
minconf=$(prompt_int_with_default "Wait for confirmations" "$MIN_CONFIRMATIONS")

echo ""
echo "Creating two new UTXOs by sending to yourself..."
echo "  STREAM send: $stream_amount BTC -> $stream_addr"
echo "  FEE send:    $fee_amount BTC -> $fee_addr"
echo ""

stream_txid=$("${BTC[@]}" -named sendtoaddress address="$stream_addr" amount="$stream_amount" fee_rate="$fee_rate")
fee_txid=$("${BTC[@]}" -named sendtoaddress address="$fee_addr" amount="$fee_amount" fee_rate="$fee_rate")

echo "Broadcasted:"
echo "  stream_txid: $stream_txid"
echo "  fee_txid:    $fee_txid"
echo ""

echo "Waiting for listunspent(minconf=$minconf) to show the new outputs..."
echo "If testnet4 is slow, this may take a while."
echo ""

STREAM_UTXO=""
FUNDING_UTXO=""
for _ in $(seq 1 300); do
  STREAM_UTXO=$(find_outpoint_by_txid "$stream_txid" "$minconf" || true)
  FUNDING_UTXO=$(find_outpoint_by_txid "$fee_txid" "$minconf" || true)

  if [ -n "$STREAM_UTXO" ] && [ -n "$FUNDING_UTXO" ]; then
    break
  fi
  sleep 5
done

if [ -z "$STREAM_UTXO" ] || [ -z "$FUNDING_UTXO" ]; then
  echo "ERROR: Could not find confirmed outpoints yet."
  echo "Try later:"
  echo "  ${BTC_CMD} listunspent $minconf 9999999 | jq -r '.[] | \"[\\(.confirmations) conf] \\(.txid):\\(.vout) -> \\(.amount) BTC\"' | sort -rn"
  exit 1
fi

ensure_not_used "$STREAM_UTXO"
ensure_not_used "$FUNDING_UTXO"

echo ""
echo "Ready to paste into create flow:"
echo "  STREAM_UTXO=$STREAM_UTXO"
echo "  FUNDING_UTXO=$FUNDING_UTXO"
echo ""
echo "Next:"
echo "  ./scripts/run_create_flow.sh --repro"
echo ""

