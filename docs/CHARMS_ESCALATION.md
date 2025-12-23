# Charms Escalation Notes

## Observed Errors

1. `400 Bad Request: "duplicate funding UTXO spend with different spell"`
2. `400 Bad Request: "Proof request <id> is unexecutable"`

Both happen even when:
- stream input UTXO and funding UTXO are freshly generated, confirmed, and never used in `spell prove` before
- we supply raw prev-tx hex for both inputs via `--prev-txs`
- the WASM contract passes (`✅ app contract satisfied` in `.build/create.raw`)

## Working Hypothesis

- **Primary (Hyp B)**: the Charms prover marks a funding UTXO as “reserved” the moment a job is submitted and never releases it when the job fails. Evidence: once a request ID hits `unexecutable`, any subsequent submission with the same funding UTXO is rejected immediately as a duplicate, even if we rerun the identical spell text via `--repro`.
- **Secondary (Hyp A)**: if a funding UTXO is tied to the hash of the rendered spell, retries that tweak even a single field (now, duration, change address) look like “different spells” to the server. Our new `--repro` mode allows us to disprove this: identical spell hashes still get rejected, so caching is independent of spell contents.
- **Other considerations**: `unexecutable` might mean the server cannot finalize its own commit/funding inputs (even though we supply ours). We now provide our own fee UTXO and validate the returned transaction consumes both inputs, so any remaining failure is entirely server-side.

## Instrumentation Added

- `run_create_flow.sh --repro` freezes all dynamic fields. Env overrides (`REPRO_TOTAL_AMOUNT`, `REPRO_DURATION`, `REPRO_NOW`, `REPRO_*ADDR`) let us reproduce a failing spell byte-for-byte.
- Both create/claim scripts honor `BTC_CMD` and validate UTXOs, prev txs, and decoded transactions. They log:
  - `.build/<flow>.rendered.yaml` (the exact spell text)
  - `.build/<flow>.command.txt` (full `charms` CLI invocation)
  - `.build/<flow>.context.txt` (UTXO IDs, values, change address, hashes, request metadata)
  - `.build/<flow>.prevtxs.txt`, `.build/<flow>.raw`, `.build/<flow>.hex`
  - `.build/used_utxos.txt` for historical tracking
- `scripts/make_escalation_bundle.sh <flow>` packages the above plus `.build/env.sh` into a tarball ready for Charms support.

## Questions for the Charms Team

1. What conditions cause a request to be marked “unexecutable” *after* the WASM contract has passed? Is it fee policy, dust limits, or internal funding exhaustion?
2. Can the prover release/clear a funding UTXO reservation when a request fails? Right now every failed attempt permanently bricks that UTXO for future proofs.
3. Is there an API/CLI endpoint to fetch job status or logs (similar to `charms job status <id>`)? We only see the final error string in `.build/*.raw`.
4. Does the prover expect identical spell text for retries that reuse the same funding UTXO? Our logging now surfaces the spell hash so we can confirm.

## How to Reproduce With Logging

1. Generate two fresh confirmed UTXOs (one for the stream input, one for fees). Note their `txid:vout`.
2. Run `./scripts/run_create_flow.sh --repro` and paste those inputs. Let the script finish; even on failure, `.build/create.*` will contain the rendered spell, command, and context.
3. If the prover responds with `unexecutable`, rerun the *same* command without changing any parameters (or just re-run with `--repro`). If the second attempt returns “duplicate funding UTXO”, gather the files into a bundle:
   ```sh
   scripts/make_escalation_bundle.sh create
   ```
4. Share the `.tar.gz` plus the request ID from `.build/create.raw` with the Charms team along with the questions above.

## Past Script Issues (Now Fixed)

- Change addresses were regenerated every run, making spells highly variable.
- Prev-tx hex was not validated against the selected inputs, which could mask mistakes.
- No audit trail existed for prover submissions; bundling the rendered spell and command is now automatic.
- Inputs were sometimes tiny (dust-level), so we now enforce ≥20,000 sat funding UTXOs and verify the decoded tx actually spends our inputs.

These changes make it possible to isolate genuine prover bugs from client-side mistakes.
