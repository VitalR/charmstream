# CharmStream Testnet4 Flow Guide

## Prerequisites

1. Bitcoin Core 28+ running on testnet4 with wallet funded
2. `charms` CLI installed
3. `jq` and `python3` available

## Quick Start (Automated Scripts)

### Step 1: Create Stream

Run the automated create flow script:

```bash
cd /Users/vital/workspace/hackathon/bitcoinos/charmstream
./scripts/run_create_flow.sh
```

This script will:
- Build the WASM app
- Let you pick a funding UTXO
- Ask for stream parameters (amount, duration, addresses)
- Derive all required values
- Check and prove the spell
- Save the raw transaction to `.build/create.raw`

**After the script completes:**

1. Inspect the transaction:
   ```bash
   bitcoin-cli decoderawtransaction $(cat .build/create.raw) | jq
   ```

2. Broadcast when ready:
   ```bash
   bitcoin-cli sendrawtransaction $(cat .build/create.raw)
   ```

3. Note the returned txid and find the stream output index (usually 0).

4. Export the stream UTXO for the claim flow:
   ```bash
   export stream_utxo_0="TXID:OUTPUT_INDEX"
   ```

### Step 2: Claim from Stream

Run the automated claim flow script:

```bash
./scripts/run_claim_flow.sh
```

This script will:
- Verify all required env vars from create flow
- Let you specify the stream UTXO and claim amount
- Calculate vested amount automatically
- Ask for a fee funding UTXO
- Check and prove the claim spell
- Save the raw transaction to `.build/claim.raw`

**After the script completes:**

1. Inspect the claim transaction:
   ```bash
   bitcoin-cli decoderawtransaction $(cat .build/claim.raw) | jq '.vout[] | {n,value,addr:.scriptPubKey.addresses}'
   ```

2. Verify outputs:
   - Output 0: Payout to beneficiary (should match `payout_sats`)
   - Output 1: Updated stream (should match `remaining_sats`)
   - Output 2+: Change outputs

3. Broadcast when ready:
   ```bash
   bitcoin-cli sendrawtransaction $(cat .build/claim.raw)
   ```

## Manual Flow (Step-by-Step)

If you prefer to run commands manually, follow these steps:

### Create Stream (Manual)

```bash
# 1. Build app
charms app build
export app_bin=target/wasm32-wasip1/release/charmstream.wasm
export app_vk=$(charms app vk $app_bin)

# 2. Pick UTXO
bitcoin-cli listunspent
export in_utxo_0="TXID:VOUT"  # replace with your chosen UTXO

# 3. Get UTXO value
txid=$(echo $in_utxo_0 | cut -d: -f1)
vout=$(echo $in_utxo_0 | cut -d: -f2)
utxo_value_btc=$(bitcoin-cli gettxout "$txid" "$vout" | jq -r '.value')
export funding_value_sats=$(python3 -c "print(int(float('$utxo_value_btc') * 1e8))")

# 4. Set stream parameters
export total_amount=20000        # sats to lock
export start_time=$(date -u +%s)
export end_time=$((start_time + 3600))  # 1 hour
export now=$start_time

# 5. Set addresses
export addr_0="tb1pq3p7sy9t6rycwyzp554s34arqqm367j0gw47hy5x7u6ch7fss3tsf972yx"
export beneficiary_addr="$addr_0"  # or different address

# 6. Derive beneficiary_dest
spk_hex=$(bitcoin-cli getaddressinfo "$beneficiary_addr" | jq -r '.scriptPubKey')
export beneficiary_dest=$(echo "$spk_hex" | xxd -r -p | base64)

# 7. Derive app_id
export app_id=$(printf "%s" "$in_utxo_0" | shasum -a 256 | cut -d' ' -f1)

# 8. Fetch prev tx
bitcoin-cli getrawtransaction "$txid" > /tmp/prev0.hex
export PREV_TXS=$(cat /tmp/prev0.hex)

# 9. Prove spell (skip check - our contract needs coin_outs which check doesn't populate)
mkdir -p .build
envsubst < spells/create-stream.yaml | charms spell prove \
  --funding-utxo="$in_utxo_0" \
  --funding-utxo-value="$funding_value_sats" \
  --change-address="$addr_0" \
  --prev-txs="$PREV_TXS" \
  --app-bins="$app_bin" > .build/create.raw

# 11. Broadcast
bitcoin-cli sendrawtransaction $(cat .build/create.raw)
```

### Claim Stream (Manual)

```bash
# Assumes all create env vars are still set

# 1. Set stream UTXO
export stream_utxo_0="CREATE_TXID:OUTPUT_INDEX"

# 2. Set claim parameters
export claimed_before=0
export now=$(date -u +%s)
export claimed_after=15000  # amount to claim (must be <= vested)
export payout_sats=$((claimed_after - claimed_before))
export remaining_sats=$((total_amount - claimed_after))

# 3. Pick fee funding UTXO
bitcoin-cli listunspent
export funding_utxo="FEE_TXID:VOUT"
fee_txid=$(echo $funding_utxo | cut -d: -f1)
fee_vout=$(echo $funding_utxo | cut -d: -f2)
fee_value_btc=$(bitcoin-cli gettxout "$fee_txid" "$fee_vout" | jq -r '.value')
export funding_value_sats=$(python3 -c "print(int(float('$fee_value_btc') * 1e8))")

# 4. Fetch prev txs
stream_txid=$(echo $stream_utxo_0 | cut -d: -f1)
bitcoin-cli getrawtransaction "$stream_txid" > /tmp/prev_stream.hex
bitcoin-cli getrawtransaction "$fee_txid" > /tmp/prev_fee.hex
{
  cat /tmp/prev_stream.hex
  echo ""
  cat /tmp/prev_fee.hex
} > /tmp/prev_all.hex
export PREV_TXS=$(cat /tmp/prev_all.hex)

# 5. Prove spell (skip check - our contract needs coin_outs which check doesn't populate)
envsubst < spells/claim-stream.yaml | charms spell prove \
  --funding-utxo="$funding_utxo" \
  --funding-utxo-value="$funding_value_sats" \
  --change-address="$addr_0" \
  --prev-txs="$PREV_TXS" \
  --app-bins="$app_bin" > .build/claim.raw

# 7. Broadcast
bitcoin-cli sendrawtransaction $(cat .build/claim.raw)
```

## Troubleshooting

### "unexpected number of stream states: in=0, out=0"

This happens if you run `charms spell check` on our spells. Our contract validates native BTC amounts via `tx.coin_outs`, which is only populated during `spell prove` (when funding info is available). **Solution**: Skip `spell check` and go straight to `spell prove`.

### "Invalid combination of chain flags"

Your bitcoin.conf has a chain set. Use `bitcoin-cli` without any `-chain` flag:
```bash
bitcoin-cli getaddressinfo ...
```

### "sha256sum: command not found" (macOS)

Use `shasum` instead:
```bash
export app_id=$(printf "%s" "$in_utxo_0" | shasum -a 256 | cut -d' ' -f1)
```

### "unexpected number of stream states: in=0, out=0"

You're missing funding flags. Make sure to include:
- `--funding-utxo`
- `--funding-utxo-value`
- `--change-address`

### "UTXO not found or already spent"

The UTXO was spent. Pick a different one from `bitcoin-cli listunspent`.

### Claim amount exceeds vested

Wait longer or reduce claim amount. Vested amount is linear:
```
vested = total_amount * (now - start_time) / (end_time - start_time)
```

## Verification

After broadcasting each transaction:

1. Check mempool:
   ```bash
   bitcoin-cli getmempoolentry TXID
   ```

2. View on explorer (if available for testnet4)

3. Decode outputs:
   ```bash
   bitcoin-cli decoderawtransaction $(cat .build/create.raw) | jq
   bitcoin-cli decoderawtransaction $(cat .build/claim.raw) | jq
   ```

4. Verify balances match expectations

## Notes

- Scripts save env vars so claim can reuse create values
- All amounts are in satoshis
- Time is Unix epoch (seconds)
- The contract enforces exact payout to beneficiary and exact remainder to stream
- Fees come from the funding UTXO (for prove) or additional inputs (for claim)

