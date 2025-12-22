use charms_sdk::data::{check, App, Charms, Data, NativeOutput, Transaction};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StreamState {
    pub total_amount: u64,   // Total stream amount (in token units)
    pub claimed_amount: u64, // Already claimed
    pub start_time: u64,     // Unix ts (seconds)
    pub end_time: u64,       // Must be > start_time
    /// Beneficiary's scriptPubKey as hex string. Pinned at create.
    #[serde(with = "hex_string")]
    pub beneficiary_dest: Vec<u8>,
}

mod hex_string {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(data: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&hex::encode(data))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        hex::decode(&s).map_err(serde::de::Error::custom)
    }
}

impl StreamState {
    pub fn vested_at(&self, now: u64) -> u64 {
        if now <= self.start_time {
            0
        } else if now >= self.end_time {
            self.total_amount
        } else {
            let elapsed = now - self.start_time;
            let duration = self.end_time - self.start_time;
            self.total_amount.saturating_mul(elapsed) / duration
        }
    }
}

pub fn app_contract(app: &App, tx: &Transaction, x: &Data, w: &Data) -> bool {
    // For now we don't use public input x; require it to be empty.
    let empty = Data::empty();
    check!(x == &empty);

    check!(stream_contract_satisfied(app, tx, w));

    true
}

fn stream_contract_satisfied(app: &App, tx: &Transaction, w: &Data) -> bool {
    // Decode "now" as u64 from witness `w`
    let now: u64 = match w.value() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("witness must contain a u64 `now` timestamp");
            return false;
        }
    };

    let ins = stream_states_in(app, tx);
    let outs = stream_states_out(app, tx);

    match (ins.len(), outs.len()) {
        // CREATE: 0 input streams, 1 output stream
        (0, 1) => validate_create(&outs[0], tx),

        // CLAIM: 1 input stream, 1 output stream
        (1, 1) => validate_claim(&ins[0], &outs[0], tx, now),

        // For now: disallow anything else
        _ => {
            eprintln!(
                "unexpected number of stream states: in={}, out={}",
                ins.len(),
                outs.len()
            );
            false
        }
    }
}

fn validate_create(out: &IndexedStreamState, tx: &Transaction) -> bool {
    let coins = match coin_outs_required(tx) {
        Some(c) => c,
        None => return false,
    };

    if out.state.total_amount == 0 {
        eprintln!("total_amount must be > 0");
        return false;
    }
    if out.state.start_time >= out.state.end_time {
        eprintln!("start_time must be < end_time");
        return false;
    }
    if out.state.claimed_amount != 0 {
        eprintln!("claimed_amount must be 0 at create");
        return false;
    }
    if out.state.beneficiary_dest.is_empty() {
        eprintln!("beneficiary_dest must be provided");
        return false;
    }

    // Stream UTXO must actually hold the native coins
    match coins.get(out.index) {
        Some(stream_coin) if stream_coin.amount == out.state.total_amount => {}
        Some(stream_coin) => {
            eprintln!(
                "stream output amount mismatch: expected {}, found {}",
                out.state.total_amount, stream_coin.amount
            );
            return false;
        }
        None => {
            eprintln!("missing coin_out for stream output index {}", out.index);
            return false;
        }
    }

    true
}

fn validate_claim(
    prev: &IndexedInputStreamState,
    next: &IndexedStreamState,
    tx: &Transaction,
    now: u64,
) -> bool {
    let prev_state = &prev.state;
    if now < prev_state.start_time {
        eprintln!("cannot claim before stream start_time");
        return false;
    }

    // same schedule
    if next.state.total_amount != prev_state.total_amount {
        eprintln!("total_amount cannot change");
        return false;
    }
    if next.state.start_time != prev_state.start_time || next.state.end_time != prev_state.end_time
    {
        eprintln!("stream schedule cannot change");
        return false;
    }

    // claimed only moves forward
    if next.state.claimed_amount < prev_state.claimed_amount {
        eprintln!("claimed_amount cannot decrease");
        return false;
    }

    // hard upper bound
    if next.state.claimed_amount > next.state.total_amount {
        eprintln!("claimed_amount cannot exceed total_amount");
        return false;
    }

    // no more than vested
    let vested = prev_state.vested_at(now);
    if next.state.claimed_amount > vested {
        eprintln!(
            "claimed_amount {} exceeds vested {} at now={}",
            next.state.claimed_amount, vested, now
        );
        return false;
    }

    if prev_state.beneficiary_dest != next.state.beneficiary_dest {
        eprintln!("beneficiary_dest cannot change");
        return false;
    }
    if next.state.beneficiary_dest.is_empty() {
        eprintln!("beneficiary_dest must be provided");
        return false;
    }

    let coin_ins = match coin_ins_required(tx) {
        Some(c) => c,
        None => return false,
    };
    let coins = match coin_outs_required(tx) {
        Some(c) => c,
        None => return false,
    };

    let prev_remaining = match prev_state
        .total_amount
        .checked_sub(prev_state.claimed_amount)
    {
        Some(v) => v,
        None => {
            eprintln!("prev.claimed_amount exceeds total_amount");
            return false;
        }
    };

    let input_amount = match coin_ins.get(prev.index) {
        Some(native_in) => native_in.amount,
        None => {
            eprintln!(
                "missing coin_in for stream input index {}; coin_ins len {}",
                prev.index,
                coin_ins.len()
            );
            return false;
        }
    };

    if input_amount != prev_remaining {
        eprintln!(
            "stream input amount mismatch: expected {}, found {}",
            prev_remaining, input_amount
        );
        return false;
    }

    let delta = match next
        .state
        .claimed_amount
        .checked_sub(prev_state.claimed_amount)
    {
        Some(d) => d,
        None => {
            eprintln!("claimed_amount must not decrease");
            return false;
        }
    };
    let remaining_after_claim = match input_amount.checked_sub(delta) {
        Some(r) => r,
        None => {
            eprintln!(
                "claim delta {} exceeds stream escrow amount {}",
                delta, input_amount
            );
            return false;
        }
    };

    // Payout must exist and be exact
    let payout_ok = coins
        .iter()
        .any(|o| o.dest == next.state.beneficiary_dest && o.amount == delta);
    if !payout_ok {
        eprintln!(
            "payout output missing or mismatched: dest len {}, amount {}",
            next.state.beneficiary_dest.len(),
            delta
        );
        return false;
    }

    // Remaining balance must stay with the stream output index
    let expected_remaining_from_state = next
        .state
        .total_amount
        .saturating_sub(next.state.claimed_amount);
    if expected_remaining_from_state != remaining_after_claim {
        eprintln!(
            "state remainder {} differs from coin math {}",
            expected_remaining_from_state, remaining_after_claim
        );
        return false;
    }
    match coins.get(next.index) {
        Some(stream_coin) if stream_coin.amount == expected_remaining_from_state => {}
        Some(stream_coin) => {
            eprintln!(
                "stream remainder mismatch: expected {}, found {}",
                expected_remaining_from_state, stream_coin.amount
            );
            return false;
        }
        None => {
            eprintln!(
                "missing coin_out for updated stream output index {}",
                next.index
            );
            return false;
        }
    }

    true
}

fn stream_states_in(app: &App, tx: &Transaction) -> Vec<IndexedInputStreamState> {
    tx.ins
        .iter()
        .enumerate()
        .filter_map(|(i, (_, charms))| {
            stream_state_in_charms(app, charms)
                .map(|state| IndexedInputStreamState { state, index: i })
        })
        .collect()
}

fn stream_states_out(app: &App, tx: &Transaction) -> Vec<IndexedStreamState> {
    tx.outs
        .iter()
        .enumerate()
        .filter_map(|(i, charms)| {
            stream_state_in_charms(app, charms).map(|state| IndexedStreamState { state, index: i })
        })
        .collect()
}

fn stream_state_in_charms(app: &App, charms: &Charms) -> Option<StreamState> {
    charms
        .get(app)
        .and_then(|data| data.value::<StreamState>().ok())
}

fn coin_outs_required(tx: &Transaction) -> Option<&Vec<NativeOutput>> {
    let Some(coins) = tx.coin_outs.as_ref() else {
        eprintln!("tx.coin_outs missing; expected native amounts present");
        return None;
    };
    if coins.len() != tx.outs.len() {
        eprintln!(
            "coin_outs length {} does not match outs length {}",
            coins.len(),
            tx.outs.len()
        );
        return None;
    }
    Some(coins)
}

fn coin_ins_required(tx: &Transaction) -> Option<&Vec<NativeOutput>> {
    let Some(coins) = tx.coin_ins.as_ref() else {
        eprintln!("tx.coin_ins missing; expected native inputs present");
        return None;
    };
    if coins.len() != tx.ins.len() {
        eprintln!(
            "coin_ins length {} does not match ins length {}",
            coins.len(),
            tx.ins.len()
        );
        return None;
    }
    Some(coins)
}

#[derive(Clone, Debug)]
struct IndexedStreamState {
    state: StreamState,
    index: usize,
}

#[derive(Clone, Debug)]
struct IndexedInputStreamState {
    state: StreamState,
    index: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use charms_sdk::data::{TxId, UtxoId, B32};
    use std::collections::BTreeMap;

    fn dummy_app() -> App {
        App {
            tag: 'n',
            identity: B32([1u8; 32]),
            vk: B32([2u8; 32]),
        }
    }

    fn beneficiary() -> Vec<u8> {
        vec![0x51, 0x21]
    }

    fn stream_dest() -> Vec<u8> {
        vec![0x76, 0xa9]
    }

    fn stream_state(total: u64, claimed: u64) -> StreamState {
        StreamState {
            total_amount: total,
            claimed_amount: claimed,
            start_time: 1_000,
            end_time: 2_000,
            beneficiary_dest: beneficiary(),
        }
    }

    fn native_output(dest: Vec<u8>, amount: u64) -> NativeOutput {
        NativeOutput { amount, dest }
    }

    fn tx(
        app: &App,
        ins_states: Vec<StreamState>,
        outs_states: Vec<Option<StreamState>>,
        coin_ins: Option<Vec<NativeOutput>>,
        coin_outs: Vec<NativeOutput>,
    ) -> Transaction {
        let ins = ins_states
            .into_iter()
            .enumerate()
            .map(|(i, state)| {
                (
                    UtxoId(TxId([i as u8; 32]), i as u32),
                    charms_with_state(app, state),
                )
            })
            .collect();

        let outs = outs_states
            .into_iter()
            .map(|maybe_state| match maybe_state {
                Some(state) => charms_with_state(app, state),
                None => BTreeMap::new(),
            })
            .collect();

        Transaction {
            ins,
            refs: vec![],
            outs,
            coin_ins,
            coin_outs: Some(coin_outs),
            prev_txs: BTreeMap::new(),
            app_public_inputs: BTreeMap::new(),
        }
    }

    fn charms_with_state(app: &App, state: StreamState) -> Charms {
        let mut c = BTreeMap::new();
        c.insert(app.clone(), Data::from(&state));
        c
    }

    #[test]
    fn test_vested_at_linear() {
        let s = stream_state(100, 0);

        assert_eq!(s.vested_at(900), 0);
        assert_eq!(s.vested_at(1000), 0);
        assert_eq!(s.vested_at(1500), 50);
        assert_eq!(s.vested_at(2000), 100);
        assert_eq!(s.vested_at(2100), 100);
    }

    #[test]
    fn validate_create_requires_amount_and_beneficiary() {
        let app = dummy_app();
        let stream = stream_state(100, 0);
        let coins = vec![native_output(stream_dest(), 100)];
        let tx = tx(&app, vec![], vec![Some(stream.clone())], None, coins);
        let outs = stream_states_out(&app, &tx);
        assert_eq!(outs.len(), 1);
        assert!(validate_create(&outs[0], &tx));
    }

    #[test]
    fn claim_rejects_over_vesting() {
        let app = dummy_app();
        let prev = stream_state(100, 0);
        let next = stream_state(100, 60); // vested(1500)=50, so reject

        let outs = vec![None, Some(next.clone())];
        let coins = vec![
            native_output(beneficiary(), 60),
            native_output(stream_dest(), 40),
        ];
        let coin_ins = vec![native_output(stream_dest(), 100)];
        let tx = tx(&app, vec![prev.clone()], outs, Some(coin_ins), coins);
        let outs_indexed = stream_states_out(&app, &tx);
        assert_eq!(outs_indexed.len(), 1);
        let ins_indexed = stream_states_in(&app, &tx);
        assert_eq!(ins_indexed.len(), 1);
        assert!(!validate_claim(
            &ins_indexed[0],
            &outs_indexed[0],
            &tx,
            1500
        ));
    }

    #[test]
    fn claim_rejects_payout_mismatch() {
        let app = dummy_app();
        let prev = stream_state(100, 20);
        let next = stream_state(100, 50);

        // wrong dest (stream_dest instead of beneficiary)
        let outs = vec![None, Some(next.clone())];
        let coins = vec![
            native_output(stream_dest(), 30),
            native_output(stream_dest(), 50),
        ];
        let coin_ins = vec![native_output(stream_dest(), 80)];
        let tx = tx(&app, vec![prev.clone()], outs, Some(coin_ins), coins);
        let outs_indexed = stream_states_out(&app, &tx);
        assert_eq!(outs_indexed.len(), 1);
        let ins_indexed = stream_states_in(&app, &tx);
        assert_eq!(ins_indexed.len(), 1);
        assert!(!validate_claim(
            &ins_indexed[0],
            &outs_indexed[0],
            &tx,
            1_500
        ));
    }

    #[test]
    fn claim_rejects_remainder_mismatch() {
        let app = dummy_app();
        let prev = stream_state(100, 20);
        let next = stream_state(100, 50); // delta=30, remainder=50

        let outs = vec![None, Some(next.clone())];
        let coins = vec![
            native_output(beneficiary(), 30),
            native_output(stream_dest(), 55), // wrong remainder
        ];
        let coin_ins = vec![native_output(stream_dest(), 80)];
        let tx = tx(&app, vec![prev.clone()], outs, Some(coin_ins), coins);
        let outs_indexed = stream_states_out(&app, &tx);
        assert_eq!(outs_indexed.len(), 1);
        let ins_indexed = stream_states_in(&app, &tx);
        assert_eq!(ins_indexed.len(), 1);
        assert!(!validate_claim(
            &ins_indexed[0],
            &outs_indexed[0],
            &tx,
            1_500
        ));
    }

    #[test]
    fn claim_accepts_valid_transition() {
        let app = dummy_app();
        let prev = stream_state(100, 20);
        let next = stream_state(100, 60); // delta = 40, remainder 40

        let outs = vec![None, Some(next.clone())];
        let coin_ins = vec![native_output(stream_dest(), 80)];
        let coin_outs = vec![
            native_output(beneficiary(), 40),
            native_output(stream_dest(), 40),
        ];
        let tx = tx(&app, vec![prev.clone()], outs, Some(coin_ins), coin_outs);
        let outs_indexed = stream_states_out(&app, &tx);
        let ins_indexed = stream_states_in(&app, &tx);
        assert_eq!(outs_indexed.len(), 1);
        assert_eq!(ins_indexed.len(), 1);
        assert!(validate_claim(
            &ins_indexed[0],
            &outs_indexed[0],
            &tx,
            1_800
        ));
    }

    #[test]
    fn claim_rejects_wrong_input_amount() {
        let app = dummy_app();
        let prev = stream_state(100, 10); // remaining 90, but coin_in says 80
        let next = stream_state(100, 40);

        let outs = vec![None, Some(next.clone())];
        let coin_ins = vec![native_output(stream_dest(), 80)];
        let coin_outs = vec![
            native_output(beneficiary(), 30),
            native_output(stream_dest(), 60),
        ];
        let tx = tx(&app, vec![prev.clone()], outs, Some(coin_ins), coin_outs);
        let outs_indexed = stream_states_out(&app, &tx);
        let ins_indexed = stream_states_in(&app, &tx);
        assert_eq!(outs_indexed.len(), 1);
        assert_eq!(ins_indexed.len(), 1);
        assert!(!validate_claim(
            &ins_indexed[0],
            &outs_indexed[0],
            &tx,
            1_500
        ));
    }
}
