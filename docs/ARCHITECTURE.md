# CharmStream Architecture & Design

## Overview

CharmStream is a Bitcoin-native streaming payments primitive that demonstrates **programmable Bitcoin UTXOs** using the Charms protocol from BitcoinOS. Unlike Ethereum smart contracts that execute arbitrary code, Bitcoin with Charms uses **zero-knowledge proofs to verify** that state transitions follow predetermined rules.

## Core Concepts

### The UTXO State Machine

Traditional Bitcoin UTXOs are simple: they hold value locked by a script. CharmStream UTXOs are **enchanted** — they carry structured state and enforce complex business logic through zk proofs.

```
┌─────────────────────────────────────┐
│     Stream UTXO (Enchanted)         │
├─────────────────────────────────────┤
│  Value: 20,000 sats                 │
│  State: StreamState {               │
│    total_amount: 20000              │
│    claimed_amount: 0                │
│    start_time: 1234567890           │
│    end_time: 1234571490             │
│    beneficiary_dest: 0x5120...      │
│  }                                  │
│  App: charmstream/6e5d3f62...       │
└─────────────────────────────────────┘
```

### State Transitions

Every transaction that spends a Stream UTXO must:

1. **Satisfy the Bitcoin script** (standard witness validation)
2. **Provide a zk-SNARK proof** that the WASM contract validated the transition
3. **Move the correct BTC amounts** to the specified outputs

```
Create:  ∅ → StreamState { total, claimed=0, times, beneficiary }

Claim:   StreamState { claimed: N } →
         StreamState { claimed: N+Δ } + BTC_payout(Δ, beneficiary)
```

## Component Architecture

### 1. WASM Contract (`src/lib.rs`)

The heart of CharmStream. Compiled to WebAssembly and executed in the Charms zkVM.

**Key Functions:**

```rust
// Calculate vested amount at time T
pub fn vested_at(state: &StreamState, now: u64) -> u64

// Entry point: validate any transaction
pub fn app_contract(app: &App, tx: &Transaction, witness: &Witness)

// Create validation: new stream
fn validate_create(out: IndexedStreamState, coins: &CoinOuts)

// Claim validation: existing stream → updated stream + payout
fn validate_claim(prev: IndexedStreamState, next: IndexedStreamState,
                   coins: &CoinOuts, now: u64)
```

**Critical Validations:**

- **Time-based vesting**: `claimed_after ≤ vested_at(state, now)`
- **Native BTC enforcement**: Actual output amounts match claimed delta
- **Beneficiary immutability**: Once set, cannot be changed
- **State consistency**: Stream can only move forward (claimed_amount increases)

### 2. Spell Definitions (`spells/*.yaml`)

Declarative transaction templates that get populated with runtime values and proven by Charms.

**`create-stream.yaml`:**

```yaml
inputs:
  - txid: ${in_utxo_txid_0}
    index: ${in_utxo_index_0}
    charms: {} # Plain BTC input

outputs:
  - address: ${addr_0}
    amount: ${total_amount} # Lock native BTC
    charms:
      - app: ${app_id}
        state:
          total_amount: ${total_amount}
          claimed_amount: 0
          start_time: ${start_time}
          end_time: ${end_time}
          beneficiary_dest: ${beneficiary_dest_hex}
```

**`claim-stream.yaml`:**

```yaml
inputs:
  - txid: ${stream_utxo_txid_0}
    index: ${stream_utxo_index_0}
    charms:
      - app: ${app_id}
        state: { ...previous StreamState... }

outputs:
  - address: ${beneficiary_addr} # PAYOUT
    amount: ${payout_sats} # claimed delta

  - address: ${addr_0} # UPDATED STREAM
    amount: ${remaining_sats} # unvested funds
    charms:
      - app: ${app_id}
        state: { ...updated StreamState with claimed_amount increased... }
```

### 3. Automated Scripts

**`scripts/run_create_flow.sh`:**

1. Builds WASM contract (`charms app build`)
2. Derives app verification key (VK) and app_id
3. Prompts for user inputs (UTXO, amount, duration, addresses)
4. Derives `beneficiary_dest` (scriptPubKey hex) from address
5. Substitutes all variables into `create-stream.yaml`
6. Generates zk proof (`charms spell prove`)
7. Extracts Bitcoin transaction hex from JSON output
8. **Broadcasts immediately** to avoid race conditions

**`scripts/run_claim_flow.sh`:**

1. Loads environment from create flow
2. Prompts for stream UTXO and claim amount
3. Calculates vested amount and validates claim
4. Generates proof with both stream and fee UTXOs
5. Broadcasts claim transaction
6. Outputs new stream UTXO for next claim

### 4. Helper Scripts

**`scripts/address_to_spk_base64.sh`:**

- Converts bech32/bech32m address to scriptPubKey hex
- Uses `bitcoin-cli getaddressinfo`
- Critical for `beneficiary_dest` field

## Data Flow

```
User Input
    ↓
Script (run_create_flow.sh)
    ↓
Environment Variables → envsubst → Spell YAML
    ↓
charms spell prove
    ↓
Charms Server:
  1. Parse spell
  2. Execute WASM in zkVM
  3. Validate contract logic
  4. Generate zk-SNARK proof
  5. Construct Bitcoin transaction
  6. Return JSON: [commitments, bitcoin_tx_hex]
    ↓
Script extracts hex: jq -r '.[1].bitcoin'
    ↓
bitcoin-cli sendrawtransaction
    ↓
Bitcoin Network (testnet4)
```

## Key Technical Decisions

### 1. Why `beneficiary_dest` as scriptPubKey bytes?

**Problem**: How do we enforce that BTC goes to the correct beneficiary?

**Solution**: Store the exact scriptPubKey (locking script) in the state, then verify the transaction output matches byte-for-byte.

```rust
// In validate_claim:
let payout = coins.get(0);  // First output must be payout
assert_eq!(payout.script_pubkey, prev.beneficiary_dest);
assert_eq!(payout.amount, claimed_delta);
```

This ensures the contract verifies **actual Bitcoin value movement**, not just state changes.

### 2. Why skip `charms spell check`?

**Problem**: `charms spell check` validates state transitions but doesn't have transaction output info.

**Solution**: Our contract needs `tx.coin_outs` to verify native BTC amounts. This is only available during `spell prove` when the full transaction is constructed. So we skip `check` and go straight to `prove`.

### 3. Why immediate broadcast after proof?

**Problem**: The Charms server provides a "funding UTXO" for transaction fees. This UTXO can be spent by another user between proof generation and broadcast, causing "inputs-missingorspent" errors.

**Solution**: Broadcast immediately after proof generation (race window ~1 second vs. ~1 minute).

### 4. Why hex serialization for `beneficiary_dest`?

**Problem**: Initially tried base64, but YAML/JSON string escaping caused issues.

**Solution**: Use hex string directly:

- Clean, URL-safe, standard in Bitcoin tooling
- Easy to derive: `bitcoin-cli getaddressinfo ... | jq -r '.scriptPubKey'`
- Custom serde in Rust handles hex ↔ Vec<u8>

## Security Model

### What CharmStream Prevents

- **Over-claiming**: Cannot claim more than vested amount at current time  
- **Beneficiary switch**: Once set, beneficiary cannot be changed  
- **State rollback**: `claimed_amount` must monotonically increase  
- **Value mismatch**: Native BTC outputs must exactly match state deltas  
- **Invalid transitions**: zkVM verifies WASM contract approved the transaction

### What CharmStream Does NOT Prevent (Future Work)

- **Cancellation**: No mechanism for payer to cancel unvested funds  
- **Cliff vesting**: No support for "lock until date X, then unlock"  
- **Pause/resume**: Once started, vesting continues regardless  
- **Multi-sig**: No built-in multi-party control

These are all implementable as contract extensions!

## Performance Characteristics

| Operation        | Time     | Notes                        |
| ---------------- | -------- | ---------------------------- |
| WASM build       | ~5s      | One-time per code change     |
| Proof generation | 30-60s   | Happens in Charms cloud      |
| Broadcast        | <1s      | Standard Bitcoin RPC         |
| Confirmation     | 10-20min | Testnet4 block time (varies) |

**Gas/Fees**:

- Charms charges ~1400 sats per proof (subject to change)
- Bitcoin miner fees: ~200 sats (testnet4, varies by size/demand)
- **Total cost**: ~1600 sats per transaction (~$1.60 at $100k BTC)

## Extensibility

CharmStream's architecture supports natural extensions:

### Cliff Vesting

```rust
fn vested_at(state: &StreamState, now: u64) -> u64 {
    if now < state.cliff_time {
        return 0;  // Nothing vested until cliff
    }
    // Then linear after cliff
    ...
}
```

### Cancellation

```rust
fn validate_cancel(prev: StreamState, payer_sig: Signature) -> bool {
    verify_signature(payer_sig, prev.payer_pubkey);
    // Return unvested to payer, vested to beneficiary
}
```

### Multi-Recipient Streams

```rust
struct StreamState {
    beneficiaries: Vec<(Vec<u8>, u64)>,  // (dest, percentage)
    ...
}
```

### zkBTC Integration

Replace native BTC inputs/outputs with Grail zkBTC vault operations, enabling:

- Private treasury management
- Cross-chain beaming of stream state
- DeFi composability while maintaining Bitcoin settlement

## Lessons Learned

### What Worked Well

1. **WASM contract model**: Rust → WASM → zkVM is elegant and familiar
2. **`tx.coin_outs`**: Critical feature for native BTC enforcement
3. **Automated scripts**: Abstracted complexity for better UX
4. **Hex serialization**: Simpler than base64 for scriptPubKeys

### Challenges Encountered

1. **Charms server caching**: UTXOs "tainted" by proof attempts
2. **Testnet4 irregularity**: Long block times, mempool quirks
3. **Funding UTXO race conditions**: Requires immediate broadcast
4. **Documentation gaps**: Had to discover many behaviors empirically

### Best Practices

- **Always use confirmed UTXOs** (≥1 confirmation)  
- **Use fresh UTXOs for each proof attempt**  
- **Broadcast immediately after proof generation**  
- **Set minimum stream amounts** (≥5000 sats) to avoid dust  
- **Validate vesting calculations client-side** before proving  
- **Check mempool status** after broadcast for debugging

## Future Directions

### Near-term (Weeks)

- [ ] Web UI (React + Bitcoin wallet integration)
- [ ] Multi-sig stream creation
- [ ] Batch claims (claim from multiple streams in one tx)
- [ ] Testnet → Mainnet deployment guide

### Mid-term (Months)

- [ ] Cliff vesting implementation
- [ ] Cancellation with refund logic
- [ ] Stream templates (payroll, grants, subscriptions)
- [ ] Integration with multisig tools (e.g., Gnosis Safe equivalent)

### Long-term (Vision)

- [ ] zkBTC vault integration (Grail protocol)
- [ ] Cross-chain beam support
- [ ] DAO treasury management dashboard
- [ ] Institutional payroll system
- [ ] Recurring payment primitives (subscriptions, recurring donations)
- [ ] Budget envelopes (hierarchical stream trees)

---

## References

- [Charms Documentation](https://docs.charms.dev/)
- [BitcoinOS Ecosystem](https://bitcoinos.build/)
- [Grail Protocol](https://bitcoinos.build/media-center/articles/grail-pro-bringing-institutional-bitcoin-to-defi)
- [charms-data crate](https://github.com/CharmsDev/charms/blob/main/charms-data/src/lib.rs)

---

**CharmStream proves that programmable Bitcoin is not only possible — it's elegant, secure, and ready for real-world use today.**
