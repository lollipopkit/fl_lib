use std::collections::BTreeMap;

use proptest::prelude::*;
use serde_json::json;

use super::*;

fn op(c: &str, id: &str, ms: u64, counter: u16, device: u64, d: Option<Value>) -> Op {
    Op { c: c.into(), id: id.into(), h: Hlc { ms, counter, device }, d }
}

#[test]
fn a_stamp_sorts_as_its_text() {
    let a = Hlc { ms: 1_762_000_000_000, counter: 2, device: 9 };
    let b = Hlc { ms: 1_762_000_000_000, counter: 10, device: 1 };
    assert!(a < b && a.to_string() < b.to_string());
    assert_eq!(a.to_string().parse::<Hlc>(), Ok(a));
    assert_eq!(serde_json::to_value(a).unwrap(), json!(a.to_string()));
    for bad in ["", "0", &"g".repeat(32), &"A".repeat(32), &"0".repeat(33)] {
        assert_eq!(bad.parse::<Hlc>(), Err(BadHlc), "{bad:?}");
    }
}

#[test]
fn a_clock_goes_forward_whatever_the_wall_clock_does() {
    let mut clock = Clock::new(7);
    let a = clock.tick(1000);
    let b = clock.tick(1000);
    let c = clock.tick(900); // the wall clock stepped back
    assert!(a < b && b < c);
    assert_eq!((c.ms, c.counter), (1000, 2));
    // Another device far ahead: what comes next is after it.
    clock.observe(Hlc { ms: 5000, counter: 3, device: 1 });
    let d = clock.tick(1001);
    assert_eq!((d.ms, d.counter, d.device), (5000, 4, 7));
    // A spent counter borrows the next millisecond.
    let mut full = Clock::resume(7, Hlc { ms: 10, counter: u16::MAX, device: 7 });
    assert_eq!(full.tick(10), Hlc { ms: 11, counter: 0, device: 7 });
    // At the very last stamp the clock stays there instead of wrapping below.
    let mut last = Clock::resume(7, Hlc { ms: MAX_MS, counter: u16::MAX, device: 1 });
    assert_eq!(last.tick(0), Hlc { ms: MAX_MS, counter: u16::MAX, device: 7 });
}

#[test]
fn the_greatest_stamp_wins_and_a_delete_is_an_op() {
    let ops = [
        op("spi", "a", 5, 0, 1, Some(json!({ "name": "old" }))),
        op("spi", "a", 7, 0, 2, None),
        op("spi", "a", 6, 0, 3, Some(json!({ "name": "late" }))),
        op("setting", "theme", 4, 0, 1, Some(json!("dark"))),
    ];
    let won = winners(|_, _| None, &ops);
    assert_eq!(won.len(), 2);
    assert_eq!(won[0].d, None, "the delete is newest");
    // What the host already applied at or after a stamp stays.
    let won = winners(|c, _| (c == "setting").then_some(Hlc { ms: 4, counter: 0, device: 1 }), &ops);
    assert_eq!(won.iter().map(|o| o.c.as_str()).collect::<Vec<_>>(), ["spi"]);
    // One millisecond, one counter: the device decides.
    let tie = [op("k", "x", 1, 0, 2, Some(json!(2))), op("k", "x", 1, 0, 9, Some(json!(9)))];
    assert_eq!(winners(|_, _| None, &tie)[0].d, Some(json!(9)));
}

#[test]
fn compaction_keeps_the_last_op_per_record() {
    let ops = vec![op("k", "x", 1, 0, 1, Some(json!(1))), op("k", "x", 3, 0, 1, None), op("k", "y", 2, 0, 1, Some(json!(2)))];
    let snap = compact(ops.clone());
    assert_eq!(snap.len(), 2);
    assert_eq!(snap.iter().find(|o| o.id == "x").unwrap().d, None);
    assert_eq!(newest(&ops), Some(Hlc { ms: 3, counter: 0, device: 1 }));
}

/// A device's state: the last op applied per record.
#[derive(Default, Clone, PartialEq, Debug)]
struct Device(BTreeMap<(String, String), Op>);

impl Device {
    fn apply(&mut self, ops: &[Op]) {
        let won: Vec<Op> = winners(|c, id| self.0.get(&(c.into(), id.into())).map(|o| o.h), ops).into_iter().cloned().collect();
        for op in won {
            self.0.insert((op.c.clone(), op.id.clone()), op);
        }
    }
}

fn arb_op() -> impl Strategy<Value = Op> {
    (0..3usize, 0..4usize, 0u64..20, 0u16..3, 0u64..3, proptest::option::of(0i32..5))
        .prop_map(|(c, id, ms, counter, device, d)| op(["spi", "key", "setting"][c], &id.to_string(), ms, counter, device, d.map(|v| json!(v))))
}

proptest! {
    /// Any order and any split into batches ends in one state.
    #[test]
    fn devices_that_saw_the_same_ops_agree(
        ops in proptest::collection::vec(arb_op(), 0..40),
        order in proptest::collection::vec(any::<prop::sample::Index>(), 0..40),
        cuts in proptest::collection::vec(1usize..6, 0..10),
    ) {
        // A clock never makes one stamp twice, so no two ops share one.
        let mut seen = std::collections::HashSet::new();
        let ops: Vec<Op> = ops.into_iter().filter(|o| seen.insert(o.h)).collect();
        let mut one = Device::default();
        one.apply(&ops);

        let mut shuffled = ops.clone();
        for (i, j) in order.iter().enumerate() {
            if shuffled.is_empty() { break }
            let a = i % shuffled.len();
            let b = j.index(shuffled.len());
            shuffled.swap(a, b);
        }
        let mut other = Device::default();
        let mut rest = shuffled.as_slice();
        for cut in cuts.iter().cycle().take(rest.len() + 1) {
            if rest.is_empty() { break }
            let (batch, tail) = rest.split_at((*cut).min(rest.len()));
            other.apply(batch);
            rest = tail;
        }
        other.apply(rest);
        prop_assert_eq!(&one, &other);
        // A snapshot answers for the same state.
        let mut from_snapshot = Device::default();
        from_snapshot.apply(&compact(ops.clone()));
        prop_assert_eq!(&one, &from_snapshot);
    }

    /// Every stamp a clock makes is after every one it made or observed.
    #[test]
    fn a_clock_never_repeats_or_goes_back(steps in proptest::collection::vec((0u64..50, any::<bool>(), 0u64..60, 0u16..4), 1..60)) {
        let mut clock = Clock::new(1);
        let mut last = Hlc::ZERO;
        for (now, observe, ms, counter) in steps {
            if observe {
                let seen = Hlc { ms, counter, device: 2 };
                clock.observe(seen);
                last = last.max(seen);
            }
            let h = clock.tick(now);
            prop_assert!(h > last, "{h} after {last}");
            last = h;
        }
    }
}
