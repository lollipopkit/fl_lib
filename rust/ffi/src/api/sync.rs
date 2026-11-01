//! `fl_sync` for Dart: the clock a device stamps its changes with, and which
//! incoming ops win. Stateless: the host keeps its last stamp and its records'
//! stamps, and passes them in.

use flutter_rust_bridge::frb;
use fl_sync::{Clock, Hlc, Op};

/// Why a call could not be answered: a stamp or an op that is not one.
#[derive(Debug)]
pub struct SyncFailure {
    pub message: String,
}

fn failure(e: impl std::fmt::Display) -> SyncFailure {
    SyncFailure { message: e.to_string() }
}

fn hlc(s: &str) -> Result<Hlc, SyncFailure> {
    s.parse().map_err(failure)
}

/// The stamp for a local change at [now_ms], after [last] (this device's
/// newest stamp, or the newest it has seen; empty for none) — `fl_sync::Clock::tick`.
#[frb(sync)]
pub fn sync_tick(device: u64, last: String, now_ms: u64) -> Result<String, SyncFailure> {
    let mut clock = if last.is_empty() { Clock::new(device) } else { Clock::resume(device, hlc(&last)?) };
    Ok(clock.tick(now_ms).to_string())
}

/// The greater of two stamps, either empty for none: what a clock resumes
/// after once [seen] came from elsewhere.
#[frb(sync)]
pub fn sync_later(last: String, seen: String) -> Result<String, SyncFailure> {
    Ok(match (last.is_empty(), seen.is_empty()) {
        (true, _) => seen,
        (_, true) => last,
        _ => hlc(&last)?.max(hlc(&seen)?).to_string(),
    })
}

/// The stamp an existing millisecond time gets when it first enters the log:
/// [ms], counter 0, [device].
#[frb(sync)]
pub fn sync_stamp_of(ms: u64, device: u64) -> String {
    Hlc { ms: ms.min(fl_sync::MAX_MS), counter: 0, device }.to_string()
}

/// Of [ops_json] (a JSON array of `{c, id, h, d}`), the ones to write: per
/// record, the greatest stamp, when greater than [current_json]'s for it (a
/// JSON object `{"<c>\u0000<id>": "<h>"}` of the stamps this side holds).
/// Answers a JSON array, in the ops' order.
#[frb(sync)]
pub fn sync_winners(ops_json: String, current_json: String) -> Result<String, SyncFailure> {
    let ops: Vec<Op> = serde_json::from_str(&ops_json).map_err(failure)?;
    let current: std::collections::HashMap<String, String> = serde_json::from_str(&current_json).map_err(failure)?;
    let won = fl_sync::winners(|c, id| current.get(&format!("{c}\u{0}{id}")).and_then(|h| h.parse().ok()), &ops);
    serde_json::to_string(&won).map_err(failure)
}
