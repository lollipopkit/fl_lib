//! Sync as an operation log.
//!
//! Everything synced is a record addressed by `(collection, id)`; a change is
//! an [`Op`] carrying the whole record (or none: a delete), stamped with a
//! [`Hlc`]. A record's state is the op with the greatest stamp seen for it, so
//! devices that have seen the same ops hold the same state whatever order the
//! ops came in. Pure: the host reads and writes its own stores.

use std::collections::BTreeMap;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// The largest millisecond a stamp holds (48 bits: until the year 10889).
pub const MAX_MS: u64 = (1 << 48) - 1;

/// A hybrid logical clock stamp: wall-clock milliseconds, a counter for
/// stamps within one millisecond, and the device that made it as the final
/// tie break. Ordered field by field, as written.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Hlc {
    pub ms: u64,
    pub counter: u16,
    pub device: u64,
}

impl Hlc {
    pub const ZERO: Hlc = Hlc { ms: 0, counter: 0, device: 0 };
}

/// Fixed-width lowercase hex (`ms` 12, `counter` 4, `device` 16 digits), so
/// stamps sort as text in the order they sort as stamps.
impl fmt::Display for Hlc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:012x}{:04x}{:016x}", self.ms, self.counter, self.device)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadHlc;

impl fmt::Display for BadHlc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("not a stamp: 32 lowercase hex digits")
    }
}

impl std::error::Error for BadHlc {}

impl FromStr for Hlc {
    type Err = BadHlc;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if s.len() != 32 || !s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
            return Err(BadHlc);
        }
        let hex = |r: std::ops::Range<usize>| u64::from_str_radix(&s[r], 16).map_err(|_| BadHlc);
        Ok(Hlc { ms: hex(0..12)?, counter: hex(12..16)? as u16, device: hex(16..32)? })
    }
}

impl Serialize for Hlc {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Hlc {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        String::deserialize(d)?.parse().map_err(serde::de::Error::custom)
    }
}

/// One device's clock: never goes back, and never stamps below what it has
/// seen from others.
#[derive(Debug, Clone)]
pub struct Clock {
    device: u64,
    ms: u64,
    counter: u16,
}

impl Clock {
    /// [device] is made once per install and kept on the device.
    pub fn new(device: u64) -> Self {
        Clock { device, ms: 0, counter: 0 }
    }

    /// A clock that resumes after [last], this device's newest stamp or the
    /// newest one it has seen.
    pub fn resume(device: u64, last: Hlc) -> Self {
        let mut clock = Clock::new(device);
        clock.observe(last);
        clock
    }

    pub fn device(&self) -> u64 {
        self.device
    }

    /// A stamp for a local change at wall-clock [now_ms], after every stamp
    /// this clock made or observed.
    pub fn tick(&mut self, now_ms: u64) -> Hlc {
        let now = now_ms.min(MAX_MS);
        if now > self.ms {
            self.ms = now;
            self.counter = 0;
        } else if self.counter == u16::MAX {
            // A millisecond's counter is spent: borrow the next millisecond.
            self.ms = (self.ms + 1).min(MAX_MS);
            self.counter = 0;
        } else {
            self.counter += 1;
        }
        Hlc { ms: self.ms, counter: self.counter, device: self.device }
    }

    /// [h] came from elsewhere: the next local stamp goes after it, so a
    /// device whose clock runs behind still writes after what it has seen.
    pub fn observe(&mut self, h: Hlc) {
        if (h.ms, h.counter) > (self.ms, self.counter) {
            self.ms = h.ms.min(MAX_MS);
            self.counter = h.counter;
        }
    }
}

/// A change to one record: the whole record, or `None` for a delete.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Op {
    pub c: String,
    pub id: String,
    pub h: Hlc,
    pub d: Option<Value>,
}

impl Op {
    pub fn key(&self) -> (&str, &str) {
        (&self.c, &self.id)
    }
}

/// Of [ops], the ones the host writes: per record, the op with the greatest
/// stamp, and only when that is greater than [current]'s stamp for it (the
/// last op the host applied or made for the record, `None` if it has none).
/// In the order of [ops]' first appearance per record, so a batch applies in
/// a stable order.
pub fn winners(mut current: impl FnMut(&str, &str) -> Option<Hlc>, ops: &[Op]) -> Vec<&Op> {
    let mut best: Vec<&Op> = Vec::new();
    let mut at: BTreeMap<(&str, &str), usize> = BTreeMap::new();
    for op in ops {
        match at.get(&op.key()) {
            Some(&i) if best[i].h >= op.h => {}
            Some(&i) => best[i] = op,
            None => {
                at.insert(op.key(), best.len());
                best.push(op);
            }
        }
    }
    best.retain(|op| current(&op.c, &op.id).is_none_or(|h| op.h > h));
    best
}

/// The last op per record of [ops]: a state that answers for all of them.
/// Deletes stay, so a device that had the record learns it is gone.
pub fn compact(ops: impl IntoIterator<Item = Op>) -> Vec<Op> {
    let mut last: BTreeMap<(String, String), Op> = BTreeMap::new();
    for op in ops {
        match last.get(&(op.c.clone(), op.id.clone())) {
            Some(kept) if kept.h >= op.h => {}
            _ => {
                last.insert((op.c.clone(), op.id.clone()), op);
            }
        }
    }
    last.into_values().collect()
}

/// The greatest stamp of [ops], what a clock observes after applying them.
pub fn newest<'a>(ops: impl IntoIterator<Item = &'a Op>) -> Option<Hlc> {
    ops.into_iter().map(|op| op.h).max()
}

#[cfg(test)]
mod tests;
