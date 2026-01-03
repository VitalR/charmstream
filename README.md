# CharmStream – Bitcoin-Native Payroll & Treasury Streams

**CharmStream** is a Bitcoin-native payroll and vesting primitive built on [Charms](https://charms.dev) (BitcoinOS). It lets DAOs and institutions lock BTC into "enchanted" UTXOs that represent salary or treasury streams, then gradually release funds over time according to rules enforced by a Charms app and zk proofs. Smart contracts on Ethereum _do things_; smart contracts on Bitcoin with Charms _verify things_. CharmStream embraces this model by encoding the stream state and rules directly into charms attached to UTXOs.

Using the Charms SDK, we implement a Rust/WASM app contract that verifies time-based unlocks: for any transaction that claims from a stream, the zkVM checks that the claimed amount is no more than the vested amount at the current time and that the remaining stream state is updated correctly. The contract also enforces native BTC value movement using `tx.coin_outs`, ensuring that the actual satoshis match the claimed amounts and destinations.

In the long term, CharmStream is designed as a building block for DAO and institutional BTC treasury management: funding contributor payroll and vesting, milestone-based grants, recurring service payments, and even subscription or donation streams—backed by BTC or zkBTC vaults, enforced at the UTXO level, and ready to beam to other chains when needed.

## Core Features

- **StreamCharm app (Rust/WASM)** – Charms app defining a `StreamState` (total_amount, claimed_amount, start_time, end_time, beneficiary_dest) and verifying safe, time-based claims with native BTC enforcement.
- **End-to-end on-chain flow** – Automated scripts for creating stream UTXOs and claiming vested funds on Bitcoin testnet4, with zk proof generation via Charms CLI.
- **Programmable BTC at UTXO level** – Streams live as enchanted UTXOs with app state, demonstrating how Charms adds real programmable functionality to Bitcoin without changing the protocol.
- **Extensible architecture** – Foundation for adding cliffs, cancellations, multi-recipient streams, zkBTC/Grail integration, and cross-chain beaming.

## Quick Start

### Prerequisites

- Rust with `wasm32-wasip1` target
- [Charms CLI](https://docs.charms.dev) installed
- Bitcoin Core node running on testnet4 with RPC access
- Some testnet4 BTC (from faucet)

### Build

```sh
rustup target add wasm32-wasip1
cargo update
make build
```

### Run On-Chain Flow (testnet4)

**Prepare two fresh UTXOs (recommended):**

Because the prover may reserve/cache funding outpoints, retries can require brand-new UTXOs. This helper creates two new wallet-controlled outputs (stream + fee), waits for confirmations, and prints the exact `txid:vout` pairs to paste into the create flow:

```sh
./scripts/prepare_fresh_utxos.sh
```

**Create a stream:**

```sh
./scripts/run_create_flow.sh
```

This will:

1. Build the WASM contract
2. List your available UTXOs
3. Prompt for stream parameters (amount, duration, beneficiary)
4. Generate a zk proof
5. Broadcast the create transaction to testnet4

**Claim vested funds:**

```sh
./scripts/run_claim_flow.sh
```

This will:

1. Calculate vested amount based on current time
2. Prompt for claim amount (up to vested)
3. Generate a zk proof for the claim
4. Broadcast the claim transaction
5. Update the stream state on-chain

## Debugging & Escalation Toolkit

- **Deterministic create runs** – `./scripts/run_create_flow.sh --repro` freezes `now`, `start_time`, `end_time`, `total_amount`, and default addresses so you can retry the _exact same_ spell text when debugging prover behaviour. Override the frozen values with `REPRO_TOTAL_AMOUNT`, `REPRO_DURATION`, `REPRO_NOW`, `REPRO_ADDR_0`, `REPRO_BENEFICIARY_ADDR`, or `REPRO_CHANGE_ADDR`.
- **Consistent RPC config** – Both scripts honor `BTC_CMD` (default `bitcoin-cli -testnet4`). Set `BTC_CMD="bitcoin-cli -testnet4 -rpcwallet=<name>"` if you run a non-default wallet or endpoint.
- **Rich logging out of the box** – Every run writes the fully rendered spell, its SHA256, the exact `charms` command, the prev-tx hex, and a `*.context.txt` summary under `.build/`. Both scripts verify that the provided UTXOs exist in the decoded prev-tx blobs and that the returned raw transaction spends the expected inputs and pays the expected outputs.
- **Fresh UTXO prep helper** – `./scripts/prepare_fresh_utxos.sh` creates two new outpoints (stream + funding) and prints them for copy/paste into `./scripts/run_create_flow.sh`.
- **UTXO safety rails** – `.build/used_utxos.txt` tracks each `txid:vout` submitted to the prover so you can avoid reusing funding UTXOs that the Charms service has already seen.
- **Escalation bundles** – `./scripts/make_escalation_bundle.sh create` (or `claim`) bundles all relevant artifacts plus your `.build/env.sh` into a tarball you can share with the Charms team. See `docs/CHARMS_ESCALATION.md` for the context and questions we send upstream.

## How It Works

1. **Create Stream**: A payer creates a "stream UTXO" by locking BTC into a charm-enchanted output. The `StreamState` records:

   - `total_amount`: Total sats in the stream
   - `claimed_amount`: Sats already claimed
   - `start_time` / `end_time`: Vesting schedule (linear unlock)
   - `beneficiary_dest`: scriptPubKey of the recipient

2. **Vesting Logic**: The WASM contract implements `vested_at(state, now)` which calculates how many sats are unlocked at any given time using linear interpolation.

3. **Claim**: The beneficiary creates a claim transaction that:

   - Spends the stream UTXO as input
   - Pays vested sats to `beneficiary_dest` (enforced via `tx.coin_outs`)
   - Creates a new stream output with updated `claimed_amount`
   - Generates a zk proof that all rules are satisfied

4. **Enforcement**: The Charms zkVM verifies:
   - Claimed amount ≤ vested amount (time-based check)
   - Native BTC payout matches claimed delta (value check)
   - Stream state transitions correctly (state machine check)
   - Beneficiary destination is immutable (security check)

## Technical Details

### Environment variables for spells

**Note**: The automated scripts (`run_create_flow.sh`, `run_claim_flow.sh`) handle these automatically. Manual setup is only needed for advanced usage.

Set these in your shell before running `make check-*` / `make prove-*`:

- `app_id`, `app_vk`, `app_bin` – App identifiers and WASM binary path
- `in_utxo_0` (funding UTXO for create), `stream_utxo_0` (existing stream for claim)
- `addr_0` (stream UTXO address), `beneficiary_addr` (payout address)
- `beneficiary_dest_hex` – Hex-encoded scriptPubKey bytes of `beneficiary_addr`
- `total_amount`, `start_time`, `end_time`, `claimed_before`, `claimed_after`, `payout_sats`, `remaining_sats`, `now`
- `PREV_TXS` – Raw hex blobs for inputs you are spending (comma separated if multiple)

Helper script to derive scriptPubKey hex:

```sh
BITCOIN_CHAIN=testnet4 scripts/address_to_spk_base64.sh <beneficiary_bech32>
```

## Spells

- `spells/create-stream.yaml` – creates the stream UTXO with native BTC amount and StreamState.
- `spells/claim-stream.yaml` – pays the beneficiary and rolls the stream forward, with strict native coin checks.

Run checks / proofs:

```sh
make check-create
make prove-create      # writes .build/create.raw
make check-claim
make prove-claim       # writes .build/claim.raw
```

Broadcast using your local bitcoin node on testnet4:

```sh
make broadcast-create
make broadcast-claim
```

### Native BTC enforcement via `beneficiary_dest`

The contract stores the beneficiary's scriptPubKey bytes (as hex in `StreamState`) and enforces:

- **Payout output** must exactly match `beneficiary_dest` and the claimed delta
- **Stream output** must keep the remaining sats with updated state
- **Immutability**: Once set, the beneficiary cannot be changed (prevents rug-pulls)

This ensures that the WASM contract verifies not just state transitions but actual Bitcoin value movement.

## Extensibility & Future Directions

CharmStream's architecture is designed to be extended in multiple directions:

### Near-term enhancements

- **Web UI**: Treasury dashboard to create/manage streams; recipient view to claim funds
- **Cliff vesting**: Lock funds until a specific date, then begin linear unlock
- **Cancellation**: Allow payer to cancel and reclaim unvested funds
- **Multi-recipient streams**: Split one stream across multiple beneficiaries

### Integration opportunities

- **zkBTC vaults**: Back streams with zkBTC from [Grail](https://bitcoinos.build/media-center/articles/grail-pro-bringing-institutional-bitcoin-to-defi) for DeFi-like treasury management
- **Cross-chain beaming**: Use Charms' beam primitive to send stream state and funds to other chains
- **Institutional payroll**: Integration with HR systems for automated contributor payments
- **Recurring payments**: Subscriptions, donations, service agreements with auto-renewal

### Why Charms for Bitcoin Programmability

Traditional Bitcoin script is limited by design. Charms adds programmability at the UTXO level without changing Bitcoin consensus:

- **State**: Attach structured data to UTXOs (e.g., `StreamState`)
- **Verification**: WASM contracts run in zkVM to verify complex conditions
- **Proofs**: zk-SNARKs ensure contract execution was valid
- **Composability**: Charms can encode logic for vesting, governance, DeFi primitives, and more

CharmStream demonstrates that real programmable Bitcoin is possible today, opening the door to institutional adoption and DAO treasury management on the world's most secure and decentralized blockchain.

## Resources

- [Charms Documentation](https://docs.charms.dev/)
- [BitcoinOS Ecosystem](https://bitcoinos.build/)
- [Grail Protocol](https://bitcoinos.build/media-center/articles/grail-pro-bringing-institutional-bitcoin-to-defi)
- [Why Charms?](https://docs.charms.dev/concepts/why/)
