# CharmStream Quick Reference

## One-Command Flow

### Create Stream

```bash
./scripts/run_create_flow.sh
```

When prompted:

- **UTXO**: Pick one with ≥5000 sats and ≥1 confirmation
- **Amount**: Minimum 5000 sats (e.g., `20000`)
- **Duration**: Seconds (e.g., `3600` for 1 hour)
- **Address**: Press Enter for default, or paste custom address

### Claim from Stream

```bash
./scripts/run_claim_flow.sh
```

When prompted:

- **Stream UTXO**: From create output (format: `txid:0`)
- **Claim amount**: Up to vested amount (script shows you)
- **Fee UTXO**: Fresh, confirmed UTXO for fees

---

## Common Commands

### Check Your UTXOs

```bash
bitcoin-cli listunspent 1  # Confirmed only
```

### Get New Address

```bash
bitcoin-cli getnewaddress "" "bech32m"
```

### Send to Address

```bash
bitcoin-cli sendtoaddress <address> 0.0005  # 50k sats
```

### Check Transaction

```bash
bitcoin-cli getmempoolentry <txid>
```

### View on Explorer

```
https://mempool.space/testnet4/tx/<txid>
```

---

## Environment Variables (for manual flows)

```bash
# From create flow
export app_bin="target/wasm32-wasip1/release/charmstream.wasm"
export app_vk="<from build output>"
export app_id="<derived from funding utxo>"
export addr_0="<stream address>"
export beneficiary_addr="<recipient address>"
export beneficiary_dest_hex="<scriptPubKey hex>"
export total_amount=20000
export start_time=<unix timestamp>
export end_time=<unix timestamp>

# For claim flow (additional)
export stream_utxo_0="<txid:vout>"
export claimed_before=0
export claimed_after=15000
export payout_sats=15000
export remaining_sats=5000
export now=<current unix timestamp>
```

---

## Troubleshooting Quick Fixes

| Error                            | Quick Fix                                               |
| -------------------------------- | ------------------------------------------------------- |
| `duplicate funding UTXO`         | Use a FRESH UTXO (never used before)                    |
| `bad-txns-inputs-missingorspent` | Use CONFIRMED UTXO (≥1 conf)                            |
| `dust`                           | Increase stream amount to ≥5000 sats                    |
| `TX decode failed`               | Script extracts hex automatically (if manual, use `jq`) |
| Slow confirmation                | Check: `bitcoin-cli getblockcount` (testnet4 varies)    |

---

## Vesting Calculation

Linear unlock:

```
vested = total × (now - start) / (end - start)
```

Example:

- Total: 20,000 sats
- Duration: 3600 seconds (1 hour)
- After 1800 seconds (30 min): 10,000 sats vested
- After 3600 seconds (1 hour): 20,000 sats vested (fully)

---

## File Locations

| File                                            | Purpose               |
| ----------------------------------------------- | --------------------- |
| `src/lib.rs`                                    | WASM contract         |
| `spells/create-stream.yaml`                     | Create spell template |
| `spells/claim-stream.yaml`                      | Claim spell template  |
| `scripts/run_create_flow.sh`                    | Automated create      |
| `scripts/run_claim_flow.sh`                     | Automated claim       |
| `.build/create.raw`                             | Proof output (JSON)   |
| `.build/create.hex`                             | Transaction hex       |
| `target/wasm32-wasip1/release/charmstream.wasm` | Compiled contract     |

---

## Testing Checklist

- [ ] Build succeeds: `make build`
- [ ] Have confirmed UTXOs: `bitcoin-cli listunspent 1`
- [ ] Run create flow: `./scripts/run_create_flow.sh`
- [ ] Verify on chain: `bitcoin-cli getmempoolentry <txid>`
- [ ] Wait for vesting: `sleep 300` (5 minutes for testing)
- [ ] Run claim flow: `./scripts/run_claim_flow.sh`
- [ ] Verify claim: Check outputs on explorer
- [ ] (Optional) Claim remaining: Run claim again

---

## Network Info

**Testnet4**

- Chain: testnet4
- Faucet: https://mempool.space/testnet4/faucet
- Explorer: https://mempool.space/testnet4
- Block time: ~10-20 minutes (varies)
- Min UTXO: ~546 sats (dust limit)

---

## Support

See full docs:

- `docs/TESTNET_FLOW.md` - Detailed flow guide
- `docs/ARCHITECTURE.md` - System design
- `README.md` - Project overview
- [Charms Docs](https://docs.charms.dev/)
