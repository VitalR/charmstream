CharmStream is a programmable BTC streaming / vesting primitive built on [Charms](https://charms.dev) (BitcoinOS). A payer creates a stream UTXO, and the beneficiary can claim vested sats over time. The WASM app enforces both the vesting schedule and the native BTC movement using `tx.coin_outs`.

## Quick start

```sh
rustup target add wasm32-wasip1
cargo update
make build
```

Useful helper to derive the base64 scriptPubKey for an address (used as `beneficiary_dest`):

```sh
BITCOIN_CHAIN=testnet4 scripts/address_to_spk_base64.sh <beneficiary_bech32>
```

## Environment you need for spells

Set these in your shell before running `make check-*` / `make prove-*`:

- `app_id`, `app_vk`, `app_bin` (or rely on `make build` to set `APP_BIN`)
- `in_utxo_0` (funding UTXO for create), `stream_utxo_0` (existing stream for claim)
- `addr_0` (stream UTXO address), `beneficiary_addr` (payout address)
- `beneficiary_dest` (base64 scriptPubKey bytes of `beneficiary_addr`)
- `total_amount`, `start_time`, `end_time`, `claimed_before`, `claimed_after`, `payout_sats`, `remaining_sats`, `now`
- `PREV_TXS` raw hex blobs for inputs you are spending (comma separated if multiple)

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

## Notes on beneficiary_dest

The contract stores the beneficiary scriptPubKey bytes and enforces:

- Payout output must exactly match `beneficiary_dest` and the claimed delta.
- Stream output must keep the remaining sats.

Use `scripts/address_to_spk_base64.sh` to get the base64 blob, then export:

```sh
export beneficiary_dest=$(BITCOIN_CHAIN=testnet4 scripts/address_to_spk_base64.sh tb1...beneficiary)
```
