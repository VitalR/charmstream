# Charms Escalation Notes

## TL;DR

We consistently observe prover-side failures on **Bitcoin testnet4** where the WASM/app contract validates successfully (`✅ app contract satisfied`), but the prover returns `unexecutable`, and subsequent retries can be rejected with `duplicate funding UTXO spend with different spell`. We are trying to align on the **intended prover semantics** (cache key, TTL, scope, retry/cancel behavior) so we can implement correct retry/UX logic and avoid costly iteration. We now have **deterministic repro** (`--repro`) plus a script that bundles all artifacts for support.

---

## Observed Errors

1. `400 Bad Request: "duplicate funding UTXO spend with different spell"`
2. `400 Bad Request: "Proof request <id> is unexecutable"`
3. `400 Bad Request: "Proof request <id> timed out during the auction"`

Both happen even when:

- stream input UTXO and funding UTXO are freshly generated, confirmed, and never used in `spell prove` before
- we supply raw prev-tx hex for both inputs via `--prev-txs`
- the WASM contract passes (`✅ app contract satisfied` in `.build/create.raw`)

Note: `timed out during the auction` is observed in the same situation (app validation succeeds first), but indicates the prover did not finalize the request within its internal scheduling/auction window.

---

## Observed Prover Semantics (current understanding)

We understand funding UTXOs **may be intentionally single-use by design**. The primary area of confusion for us is **how that policy applies when a request fails before any transaction is broadcast** (including user-cancelled signing flows).

Based on repeated runs and retries:

- Submitting a proof request appears to **reserve** the specified funding UTXO at request submission time.
- If the prover returns `unexecutable`, subsequent submissions that reuse the same funding UTXO may be rejected immediately with `duplicate funding UTXO spend with different spell`.
- Our `--repro` mode allows byte-for-byte identical spell rendering, which helps distinguish spell variability from prover-side reservation/caching behavior.

Other considerations (still unclear without prover diagnostics):

- `unexecutable` may reflect prover-side constraints after app validation (e.g., fee/dust policy, missing ancestor prev_txs/visibility, input selection constraints, tx assembly constraints, mempool/0-conf assumptions, or internal funding constraints).
- Even when providing `--funding-utxo`, the prover may still have internal funding/fee handling assumptions that influence feasibility.

---

## Instrumentation Added

- `run_create_flow.sh --repro` freezes all dynamic fields. Env overrides
  (`REPRO_TOTAL_AMOUNT`, `REPRO_DURATION`, `REPRO_NOW`, `REPRO_*ADDR`)
  let us reproduce a failing spell byte-for-byte.
- `scripts/prepare_fresh_utxos.sh` creates two fresh wallet-controlled outpoints (stream + fee), waits for confirmations, and prints the `txid:vout` pairs to paste into the create flow.
- Both create/claim scripts honor `BTC_CMD` and validate UTXOs, prev txs, and decoded transactions. They log:
  - `.build/<flow>.rendered.yaml` (the exact spell text)
  - `.build/<flow>.command.txt` (full `charms` CLI invocation)
  - `.build/<flow>.context.txt` (UTXO IDs, values, change address, hashes, request metadata)
  - `.build/<flow>.prevtxs.txt`, `.build/<flow>.raw`, `.build/<flow>.hex`
  - `.build/used_utxos.txt` for historical tracking
- `scripts/make_escalation_bundle.sh <flow>` packages the above plus `.build/env.sh` into a tarball ready for Charms support.

---

## Questions for the Charms Team

### 1) Cache / reservation semantics

1. For `duplicate funding UTXO spend with different spell`, what is the **cache/reservation key**?
   - outpoint (`txid:vout`), `txid`-only, address/scriptPubKey, session/user identity, or something else?
2. What is the **reservation TTL** (if any)? Is it time-based or effectively indefinite?
3. If a spell has multiple inputs (e.g., identity + funding), which inputs are **reserved/cached**?
   - only the funding UTXO, or all inputs?

### 2) Retry / cancellation behavior

4. If a request fails as `unexecutable` **before any tx is broadcast** (or the user cancels signing),
   is there an expected way to **clear/retry** (API/CLI/admin action), or should clients treat funding UTXOs as one-shot per attempt?

### 3) “Unexecutable” after app contract passes

5. When the app contract has already passed but the prover reports `unexecutable`, what are the most common causes?
   - fee policy / dust limits
   - missing ancestor prev_txs / visibility
   - mempool / 0-conf assumptions
   - tx assembly constraints
   - internal funding/fee constraints
6. Even when `--funding-utxo` is supplied, can the prover still depend on internal funding/fee inputs or internal policies that may cause `unexecutable`?

### 4) Diagnostics / observability

7. Is there any endpoint/CLI to fetch request **status** or more detailed **diagnostics/logs** beyond the final error string?
   Today we only see `unexecutable` / `duplicate funding UTXO...` in `.build/*.raw` even though app validation passed, and it would help to know _which stage_ failed (policy check vs input selection vs tx assembly, etc.).

---

## Recommended Next Step

If the above behavior is **expected**:

- Please confirm the intended contract (e.g., “funding UTXOs are always single-use once submitted, even on failure”) and any TTL details, so we can implement the correct UX and avoid retries that will never succeed.

If the above behavior is **not intended**:

- Please point us to the supported cleanup/retry pathway (or confirm what information you need from the repro bundle to diagnose).

If you want logs:

- We can share a minimal repro privately (request id + rendered spell + inputs), or provide the full bundle generated by `scripts/make_escalation_bundle.sh`.

---

## How to Reproduce With Logging

1. Generate two fresh confirmed UTXOs (one for the stream input, one for fees). Note their `txid:vout`.
   - Optional helper: run `./scripts/prepare_fresh_utxos.sh` and use the printed `STREAM_UTXO` / `FUNDING_UTXO`.
2. Run `./scripts/run_create_flow.sh --repro` and paste those inputs. Let the script finish; even on failure, `.build/create.*` will contain the rendered spell, command, and context.
3. If the prover responds with `unexecutable`, rerun the **same** command without changing any parameters (or just rerun with `--repro`).
   - Under the current understanding, a follow-up `duplicate funding UTXO...` response would be consistent with “reservation-at-submit” semantics.
4. Gather the files into a bundle:
   ```sh
   scripts/make_escalation_bundle.sh create
   ```
5. Share the `.tar.gz` plus the request ID from `.build/create.raw` with the Charms team along with the questions above.
