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
- List your available UTXOs (both confirmed and unconfirmed)
- Let you pick a funding UTXO
- Ask for stream parameters (amount, duration, addresses)
- Derive all required values (scriptPubKey, app_id, etc.)
- Generate a zk proof via Charms server
- **Automatically broadcast the transaction immediately**
- Display the transaction ID and mempool.space link

**Important Notes:**

**WARNING: Use CONFIRMED UTXOs only** (at least 1 confirmation). Unconfirmed UTXOs will fail when broadcasting.

**WARNING: Use FRESH UTXOs** that haven't been used in previous `charms spell prove` attempts. The Charms server caches proof attempts and will reject reused UTXOs with "duplicate funding UTXO" error.

**WARNING: Minimum amount**: Set stream amount to at least 5000 sats to avoid dust errors after fees.

**After successful broadcast:**

The script outputs the stream TXID and UTXO. Export these for the claim flow:

```bash
export STREAM_TXID="<txid_from_output>"
export stream_utxo_0="$STREAM_TXID:0"
```

**To verify on-chain:**

```bash
# Check if transaction is in mempool
bitcoin-cli getmempoolentry $STREAM_TXID

# View transaction details
bitcoin-cli getrawtransaction $STREAM_TXID 1 | jq

# View on block explorer
https://mempool.space/testnet4/tx/$STREAM_TXID
```

### Step 2: Claim from Stream

Run the automated claim flow script:

```bash
./scripts/run_claim_flow.sh
```

This script will:

- Verify all required env vars from create flow
- Let you specify the stream UTXO
- Calculate vested amount automatically based on current time
- Validate your claim amount doesn't exceed vested
- Ask for a fee funding UTXO (must be FRESH and CONFIRMED)
- Generate a zk proof for the claim
- **Automatically broadcast the claim transaction**
- Display the claim TXID and updated stream UTXO

**Important Notes:**

**WARNING: Wait for stream UTXO to confirm** before claiming (at least 1 confirmation).

**WARNING: Use FRESH fee funding UTXO** that hasn't been used in previous proof attempts.

**WARNING: Claim amount must be less than or equal to vested amount**. The script calculates this for you using:

```
vested = total_amount × (now - start_time) / (end_time - start_time)
```

**After successful broadcast:**

The script outputs:

- Claim TXID
- Updated stream UTXO (for next claim)
- Amount claimed and remaining

**To verify the claim:**

```bash
# View claim transaction
bitcoin-cli getrawtransaction $CLAIM_TXID 1 | jq '.vout'

# Verify outputs:
# [0] = Payout to beneficiary (your claimed sats)
# [1] = Updated stream (remaining unvested sats)
# [2+] = Change outputs

# Check on explorer
https://mempool.space/testnet4/tx/$CLAIM_TXID
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

### CRITICAL: "duplicate funding UTXO spend with different spell"

**Problem**: The Charms proof server caches proof attempts. Once you use a UTXO in `charms spell prove`, it's marked as "used" even if you never broadcast the transaction. If you change any parameter (amount, duration, app code, etc.) and try to prove again with the same UTXO, you'll get this error.

**Solution**:

1. **Use a completely fresh UTXO** that has NEVER been used in any prove attempt
2. Generate a new address: `bitcoin-cli getnewaddress "" "bech32m"`
3. Send funds to it: `bitcoin-cli sendtoaddress <new_addr> 0.0005`
4. Wait for 1 confirmation
5. Use this new UTXO in your next prove attempt

**Prevention**: Only run `prove` when you're ready to broadcast immediately. Don't experiment with different parameters on the same UTXO.

### "bad-txns-inputs-missingorspent"

**Problem**: The transaction references UTXOs that don't exist on the network or are already spent.

**Common causes**:

1. **Unconfirmed parent UTXO**: You're trying to spend a UTXO that hasn't confirmed yet
2. **Stale Charms funding UTXO**: The Charms server provided a funding UTXO for your proof, but another user spent it before you broadcast
3. **Already spent your UTXO**: You used the same UTXO in a previous transaction

**Solution**:

- **Always use confirmed UTXOs** (at least 1 confirmation)
- **Broadcast immediately after proof generation** (our scripts do this automatically now)
- Check UTXO status: `bitcoin-cli gettxout <txid> <vout>`

### "dust" error code -26

**Problem**: One of your transaction outputs is below Bitcoin's dust threshold (~546 sats for witness outputs).

**Solution**:

- Set stream amount to at least **5000 sats** to ensure outputs remain above dust after fees
- The automated scripts enforce this minimum

### "unexpected number of stream states: in=0, out=0"

**Problem**: You're running `charms spell check` on our spells. Our contract validates native BTC amounts via `tx.coin_outs`, which is only populated during `spell prove` (when funding and coin info is available).

**Solution**: Skip `charms spell check` and go straight to `charms spell prove`. The automated scripts do this correctly.

### "TX decode failed. Make sure the tx has at least one input."

**Problem**: The `charms spell prove` output is JSON format, but you're trying to broadcast the raw JSON instead of extracting the hex.

**Solution**: Extract the Bitcoin transaction hex from the JSON output:

```bash
tail -1 .build/create.raw | jq -r '.[1].bitcoin' > .build/create.hex
bitcoin-cli sendrawtransaction $(cat .build/create.hex)
```

The automated scripts handle this correctly.

### "Invalid combination of chain flags" (bitcoin-cli error)

**Problem**: Your `bitcoin.conf` already sets `testnet4=1`, and you're passing `-chain=testnet4` to `bitcoin-cli`, creating a conflict.

**Solution**: Use `bitcoin-cli` without any chain flag:

```bash
bitcoin-cli getaddressinfo <address>  # NOT: bitcoin-cli -chain=testnet4 ...
```

### "sha256sum: command not found" (macOS)

**Problem**: macOS doesn't have `sha256sum`, it uses `shasum` instead.

**Solution**:

```bash
export app_id=$(printf "%s" "$in_utxo_0" | shasum -a 256 | cut -d' ' -f1)
```

### Testnet4 blocks taking too long

**Problem**: Testnet4 can have irregular block times, sometimes 30+ minutes between blocks.

**Solution**:

- Check recent blocks: `bitcoin-cli getblockcount` and `bitcoin-cli getblock <hash>`
- Verify your tx is in mempool: `bitcoin-cli getmempoolentry <txid>`
- Wait patiently, or try mining yourself if you have testnet mining setup
- Use block explorer: https://mempool.space/testnet4/

### Claim amount exceeds vested

**Problem**: You're trying to claim more than has vested according to the schedule.

**Solution**:

- Wait longer for more to vest, or
- Reduce claim amount
- Vested calculation (linear):
  ```
  vested = total_amount × (now - start_time) / (end_time - start_time)
  ```

### How to get fresh UTXOs without waiting for faucet

**Problem**: All your UTXOs are "tainted" by previous prove attempts.

**Solution**: Send from your existing wallet to a new address:

```bash
# Generate new address
NEW_ADDR=$(bitcoin-cli getnewaddress "" "bech32m")

# Send 50k sats to it
bitcoin-cli sendtoaddress "$NEW_ADDR" 0.0005

# Wait for 1 confirmation (~10-20 min on testnet4)
bitcoin-cli listunspent 1 | grep "$NEW_ADDR"
```

This reuses your existing testnet BTC instead of requesting more from faucets.

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
