use charms_sdk::data::{charm_values, check, App, Data, Transaction};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StreamState {
    pub total_amount: u64,   // Total stream amount (in token units)
    pub claimed_amount: u64, // Already claimed
    pub start_time: u64,     // Unix ts (seconds)
    pub end_time: u64,       // Must be > start_time
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
        (0, 1) => {
            check!(validate_create(&outs[0]));
            true
        }

        // CLAIM: 1 input stream, 1 output stream
        (1, 1) => {
            check!(validate_claim(&ins[0], &outs[0], now));
            true
        }

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

fn validate_create(out: &StreamState) -> bool {
    if out.total_amount == 0 {
        eprintln!("total_amount must be > 0");
        return false;
    }
    if out.start_time >= out.end_time {
        eprintln!("start_time must be < end_time");
        return false;
    }
    if out.claimed_amount != 0 {
        eprintln!("claimed_amount must be 0 at create");
        return false;
    }
    true
}

fn validate_claim(prev: &StreamState, next: &StreamState, now: u64) -> bool {
    if now < prev.start_time {
        eprintln!("cannot claim before stream start_time");
        return false;
    }

    // same schedule
    if next.total_amount != prev.total_amount {
        eprintln!("total_amount cannot change");
        return false;
    }
    if next.start_time != prev.start_time || next.end_time != prev.end_time {
        eprintln!("stream schedule cannot change");
        return false;
    }

    // claimed only moves forward
    if next.claimed_amount < prev.claimed_amount {
        eprintln!("claimed_amount cannot decrease");
        return false;
    }

    // hard upper bound
    if next.claimed_amount > next.total_amount {
        eprintln!("claimed_amount cannot exceed total_amount");
        return false;
    }

    // no more than vested
    let vested = prev.vested_at(now);
    if next.claimed_amount > vested {
        eprintln!(
            "claimed_amount {} exceeds vested {} at now={}",
            next.claimed_amount, vested, now
        );
        return false;
    }

    true
}

fn stream_states_in(app: &App, tx: &Transaction) -> Vec<StreamState> {
    // Inputs: tx.ins is Vec<(UtxoId, Data)>
    charm_values(app, tx.ins.iter().map(|(_, v)| v))
        .filter_map(|data| data.value::<StreamState>().ok())
        .collect()
}

fn stream_states_out(app: &App, tx: &Transaction) -> Vec<StreamState> {
    // Outputs: tx.outs is Vec<Data>
    charm_values(app, tx.outs.iter())
        .filter_map(|data| data.value::<StreamState>().ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vested_at_linear() {
        let s = StreamState {
            total_amount: 100,
            claimed_amount: 0,
            start_time: 1000,
            end_time: 2000,
        };

        assert_eq!(s.vested_at(900), 0);
        assert_eq!(s.vested_at(1000), 0);
        assert_eq!(s.vested_at(1500), 50);
        assert_eq!(s.vested_at(2000), 100);
        assert_eq!(s.vested_at(2100), 100);
    }
}

#[test]
fn validate_create_rejects_zero_total() {
    let s = StreamState {
        total_amount: 0,
        claimed_amount: 0,
        start_time: 1000,
        end_time: 2000,
    };
    assert!(!validate_create(&s));
}

#[test]
fn validate_create_rejects_claimed_nonzero() {
    let s = StreamState {
        total_amount: 100,
        claimed_amount: 1,
        start_time: 1000,
        end_time: 2000,
    };
    assert!(!validate_create(&s));
}

#[test]
fn validate_claim_happy_path() {
    let prev = StreamState {
        total_amount: 100,
        claimed_amount: 0,
        start_time: 1000,
        end_time: 2000,
    };
    // at now=1500, vested=50
    let next = StreamState {
        total_amount: 100,
        claimed_amount: 50,
        start_time: 1000,
        end_time: 2000,
    };

    assert!(validate_claim(&prev, &next, 1500));
}

#[test]
fn validate_claim_rejects_over_vesting() {
    let prev = StreamState {
        total_amount: 100,
        claimed_amount: 0,
        start_time: 1000,
        end_time: 2000,
    };
    // 60 > vested(1500)=50
    let next = StreamState {
        total_amount: 100,
        claimed_amount: 60,
        start_time: 1000,
        end_time: 2000,
    };

    assert!(!validate_claim(&prev, &next, 1500));
}

#[test]
fn validate_claim_rejects_schedule_change() {
    let prev = StreamState {
        total_amount: 100,
        claimed_amount: 0,
        start_time: 1000,
        end_time: 2000,
    };
    let next = StreamState {
        total_amount: 100,
        claimed_amount: 10,
        start_time: 1100, // changed
        end_time: 2000,
    };

    assert!(!validate_claim(&prev, &next, 1500));
}
