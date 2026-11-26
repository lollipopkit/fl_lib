//! The sync on a server-ordered log, LK Cloud's: sends this device's changes
//! as batches of ops, applies the ops other devices sent that win, and writes
//! a snapshot when the log asks for one.

use std::collections::HashSet;
use std::future::Future;
use std::sync::{Arc, Mutex};

use fl_sync::Hlc;
use serde_json::Map;
use tokio::sync::watch;

use crate::engine::{self, Core, Naming, Run};
use crate::{BlobStore, Error, Host, Result, Seal, now_ms};

/// Where the log is kept (LK Cloud's `/v2/sync/{app}/log`).
pub trait LogTransport: BlobStore {
    /// Appends [body] once per [key]. [Error::LogFull] while a snapshot is due
    /// before any more.
    fn append(&self, key: String, body: Vec<u8>) -> impl Future<Output = Result<Appended>> + Send;

    /// The batches after [after] of [log].
    fn read(&self, after: i64, log: Option<String>) -> impl Future<Output = Result<Page>> + Send;

    /// [body] as the snapshot up to [seq]; false when one at or past it is
    /// there already.
    fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> impl Future<Output = Result<bool>> + Send;

    /// The snapshot, `None` before there is one.
    fn snapshot(&self) -> impl Future<Output = Result<Option<SnapshotBody>>> + Send;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Appended {
    pub log: String,
    pub seq: i64,
    /// A snapshot is due.
    pub compact: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Page {
    Batches { log: Option<String>, batches: Vec<(i64, Vec<u8>)>, more: bool },
    /// The batches after the cursor are gone, or it was of another log: the
    /// snapshot is read, then the log after it.
    Compacted { log: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotBody {
    pub log: String,
    pub seq: i64,
    pub body: Vec<u8>,
}

const PREFIX: &str = "log.";
const LOG: &str = "log";
const CURSOR: &str = "cursor";
const SENT: &str = "sent";
const JOINED: &str = "joined";
const JOIN_LOG: &str = "join_log";
const JOIN_SENT: &str = "join_sent";
const ACCOUNT: &str = "account";
/// Set by builds that dropped what they did not carry.
/// TODO: remove once no install has the row.
const PARTIAL: &str = "partial";

/// An unanswered batch older than this is built again rather than sent: a
/// blob it names may have been swept meanwhile.
const UNANSWERED_MAX_MS: i64 = 12 * 3600 * 1000;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct JoinCursor {
    h: Hlc,
    c: String,
    id: String,
}

impl JoinCursor {
    fn encode(&self) -> String {
        serde_json::json!([self.h.to_string(), self.c, self.id]).to_string()
    }

    fn decode(raw: &str) -> Option<Self> {
        let arr = serde_json::from_str::<serde_json::Value>(raw).ok()?;
        let items = arr.as_array()?;
        if items.len() != 3 {
            return None;
        }
        let h: Hlc = items[0].as_str()?.parse().ok()?;
        let c = items[1].as_str()?.to_string();
        let id = items[2].as_str()?.to_string();
        Some(Self { h, c, id })
    }
}

#[derive(Clone)]
struct Batch {
    key: String,
    body: Vec<u8>,
    last: Option<Hlc>,
    join_last: Option<JoinCursor>,
    /// The log id prior join batches were committed to; `None` only when this
    /// batch begins a fresh join from the first record.
    join_for_log: Option<String>,
    mark_joined: bool,
}

#[derive(Clone)]
struct PendingSnapshot {
    log: Option<String>,
    seq: i64,
    body: Vec<u8>,
    named: HashSet<String>,
    /// Wall-clock timestamp when [named] was captured so a delayed sweep never
    /// deletes blobs uploaded by other devices after this snapshot.
    created_at: i64,
}

pub struct LogSync<H, T, S> {
    core: Core<H, T, S>,
    transport: Arc<T>,
    /// A batch sealed and not yet answered: sent again as it is, so the
    /// server takes it once; and when it was first sent.
    unanswered: Mutex<Option<(Batch, i64)>>,
    /// A snapshot committed remotely whose local watermark save failed: retried
    /// with the exact same bytes so transport flushes local state without
    /// resending, then sweeps covered blobs.
    pending_snapshot: Mutex<Option<PendingSnapshot>>,
}

fn hlc_text(h: Option<Hlc>) -> String {
    h.map(|h| h.to_string()).unwrap_or_default()
}

impl<H: Host, T: LogTransport, S: Seal> LogSync<H, T, S> {
    pub fn new(host: Arc<H>, transport: Arc<T>, seal: Arc<S>) -> Self {
        Self {
            core: Core::new(host, transport.clone(), seal, PREFIX, Naming::Keyed),
            transport,
            unanswered: Mutex::new(None),
            pending_snapshot: Mutex::new(None),
        }
    }

    /// Whether the last read stopped at a newer build's batch: this device
    /// reads no further until updated.
    pub fn too_new(&self) -> watch::Receiver<bool> {
        self.core.too_new.subscribe()
    }

    /// Reads what other devices sent, then sends what this one has: sent even
    /// when the log cannot be read on (a batch of a newer build).
    pub async fn sync(&self) -> Result<()> {
        let run = self.core.run().await?;
        let flushed = self.flush_pending_snapshot().await?;
        let read = self.pull_in(&run).await;
        let defer_sweep = if let Some(pending) = flushed {
            if read.is_ok() {
                if self.core.get(LOG).await? == pending.log && self.core.get_int(CURSOR).await? <= pending.seq {
                    self.core.sweep_blobs_as_of(pending.named, pending.created_at).await;
                    false
                } else {
                    // Batches followed `pending.seq` or the log was recreated:
                    // defer blob sweep until a fresh snapshot covers them.
                    true
                }
            } else {
                false
            }
        } else {
            false
        };
        let wrote_snapshot = self.push(&run).await?;
        if defer_sweep && !wrote_snapshot {
            self.pull_in(&run).await?;
            self.write_snapshot(&run).await?;
        }
        read
    }

    /// Reads what other devices sent.
    pub async fn pull(&self) -> Result<()> {
        let run = self.core.run().await?;
        self.pull_in(&run).await
    }

    /// Whether the log at [seq] has batches not read here.
    pub async fn behind(&self, seq: i64) -> Result<bool> {
        Ok(seq > self.core.get_int(CURSOR).await?)
    }

    /// [forget], after the run going on.
    pub async fn reset(&self) -> Result<()> {
        let _run = self.core.run().await?;
        Self::forget(&*self.core.host).await?;
        // Sealed under what was carried before: its records are read again.
        *self.unanswered.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.pending_snapshot.lock().unwrap_or_else(|e| e.into_inner()) = None;
        self.core.too_new.send_replace(false);
        Ok(())
    }

    /// Replaces the key ([rekey] makes the new one current and findable),
    /// then writes a snapshot under it at once, so a device that has only the
    /// new key has the state whole. Batches before it stay readable with the
    /// old key until the server drops them.
    pub async fn rotate<F: Future<Output = Result<()>> + Send>(&self, rekey: F) -> Result<()> {
        let run = self.core.run().await?;
        self.flush_pending_snapshot().await?;
        self.pull_in(&run).await?;
        rekey.await?;
        // A snapshot goes past the last one: a batch makes room for it.
        let body = self.core.seal.seal(&engine::encode(&[], Map::new())?)?;
        let last = self.core.get_hlc(SENT).await?;
        self.append(&run, Batch { key: engine::new_key(), body, last, join_last: None, join_for_log: None, mark_joined: false }).await?;
        self.pull_in(&run).await?;
        if !self.write_snapshot(&run).await? {
            return Err(Error::Host("no snapshot written".into()));
        }
        Ok(())
    }

    async fn pull_in(&self, run: &Run<'_>) -> Result<()> {
        let read = self.read(run).await;
        self.core.reading(run, read).await
    }

    async fn read(&self, run: &Run<'_>) -> Result<()> {
        self.core.begin_read();
        loop {
            let cursor = self.core.get_int(CURSOR).await?;
            let log = if cursor == 0 { None } else { self.core.get(LOG).await? };
            match self.transport.read(cursor, log).await? {
                Page::Compacted { log } => {
                    let Some(snapshot) = self.transport.snapshot().await? else {
                        // A log made anew, with nothing covering it: read it
                        // from its start.
                        self.core.put(vec![(LOG, log), (CURSOR, Some("0".into()))]).await?;
                        if cursor == 0 {
                            return Ok(());
                        }
                        continue;
                    };
                    let ops = self.core.decode(&snapshot.body, &format!("snapshot {}", snapshot.seq)).await?;
                    self.core.apply(run, ops, self.state(vec![(LOG, Some(snapshot.log)), (CURSOR, Some(snapshot.seq.to_string()))]), false).await?;
                }
                Page::Batches { log, batches, more } => {
                    for (seq, body) in batches {
                        let ops = self.core.decode(&body, &format!("batch {seq}")).await?;
                        self.core.apply(run, ops, self.state(vec![(LOG, log.clone()), (CURSOR, Some(seq.to_string()))]), false).await?;
                    }
                    if !more {
                        return Ok(());
                    }
                }
            }
        }
    }

    fn state(&self, values: Vec<(&str, Option<String>)>) -> Vec<(String, Option<String>)> {
        values.into_iter().map(|(k, v)| (format!("{PREFIX}{k}"), v)).collect()
    }

    async fn push(&self, run: &Run<'_>) -> Result<bool> {
        let core = &self.core;
        let mut compact = false;
        // Before what is pending is read: it moves what was sent.
        let unanswered = {
            let mut held = self.unanswered.lock().unwrap_or_else(|e| e.into_inner());
            // Not sent as far as this device knows: what was sent did not
            // move, so its records are read and sent again below.
            if held.as_ref().is_some_and(|(_, at)| now_ms() - at > UNANSWERED_MAX_MS) {
                *held = None;
            }
            held.as_ref().map(|(b, _)| b.clone())
        };
        if let Some(batch) = unanswered {
            compact |= self.append(run, batch).await?;
        }
        core.host.stamp().await?;
        let log = core.get(LOG).await?;
        // Joining a log (the first time, or one made anew): every record goes,
        // whoever stamped it, so what this device holds reaches the others.
        let joining = log.is_none() || core.get(JOINED).await? != log;
        let join_sent = if joining && log.is_some() && core.get(JOIN_LOG).await? == log {
            core.get(JOIN_SENT).await?.and_then(|raw| JoinCursor::decode(&raw))
        } else {
            None
        };
        let sent = core.get_hlc(SENT).await?;
        let mut all = if joining { core.host.all().await? } else { core.host.pending(sent).await? };
        if joining {
            all.sort_by(|a, b| a.h.cmp(&b.h).then_with(|| a.c.cmp(&b.c)).then_with(|| a.id.cmp(&b.id)));
            if let Some(after) = &join_sent {
                all.retain(|r| (&r.h, &r.c, &r.id) > (&after.h, &after.c, &after.id));
            }
        }
        let carried: Vec<_> = all.iter().filter(|r| run.carries(&r.c)).cloned().collect();
        let (ops, complete) = core.ops_of(&carried).await?;
        // A record that could not be read stops the send just before it, so it
        // and what follows are read again next time.
        let stopped = ops.last().map(|op| op.h);
        let stamped: Vec<_> = if complete { all } else { all.into_iter().filter(|r| stopped.is_some_and(|h| r.h <= h)).collect() };
        let mine = core.device().await?;
        let mut last = sent;
        let mut join_last = join_sent.clone();
        let batches = core.batches(ops)?;
        let last_idx = batches.len().saturating_sub(1);
        for (idx, (chunk, body)) in batches.into_iter().enumerate() {
            for op in &chunk {
                if op.h.device == mine && Some(op.h) > last {
                    last = Some(op.h);
                }
                if joining {
                    let cur = JoinCursor { h: op.h, c: op.c.clone(), id: op.id.clone() };
                    if join_last.as_ref().is_none_or(|prev| cur > *prev) {
                        join_last = Some(cur);
                    }
                }
            }
            let mark_joined = joining && complete && idx == last_idx;
            let batch_join = if joining && !mark_joined { join_last.clone() } else { None };
            let join_for_log = if joining && (join_sent.is_some() || idx > 0) {
                core.get(LOG).await?
            } else {
                None
            };
            compact |= self.append(run, Batch { key: engine::new_key(), body, last, join_last: batch_join, join_for_log, mark_joined }).await?;
        }
        // Past what was left out too, so it is not looked at again.
        let newest = stamped.iter().map(|r| r.h).filter(|h| h.device == mine).fold(last, |a, h| if Some(h) > a { Some(h) } else { a });
        if newest != last {
            core.put(vec![(SENT, Some(hlc_text(newest)))]).await?;
        }
        if joining && complete {
            core.put(vec![(JOINED, core.get(LOG).await?), (JOIN_LOG, None), (JOIN_SENT, None)]).await?;
        }
        let mut wrote_snapshot = false;
        if compact {
            self.pull_in(run).await?;
            wrote_snapshot = self.write_snapshot(run).await?;
        }
        Ok(wrote_snapshot)
    }

    /// Sends [batch]; whether a snapshot is due. A full log is compacted
    /// first, then sent again.
    async fn append(&self, run: &Run<'_>, batch: Batch) -> Result<bool> {
        let core = &self.core;
        let mut compacted = false;
        loop {
            {
                let mut held = self.unanswered.lock().unwrap_or_else(|e| e.into_inner());
                let at = match held.as_ref() {
                    Some((b, at)) if b.key == batch.key => *at,
                    _ => now_ms(),
                };
                *held = Some((batch.clone(), at));
            }
            let (appended, persist_err) = match self.transport.append(batch.key.clone(), batch.body.clone()).await {
                Err(Error::LogFull) if !compacted => {
                    self.pull_in(run).await?;
                    if !self.write_snapshot(run).await? {
                        return Err(Error::LogFull);
                    }
                    compacted = true;
                    continue;
                }
                Err(Error::AppendPersistFailed { appended, detail }) => (appended, Some(detail)),
                other => (other?, None),
            };
            *self.unanswered.lock().unwrap_or_else(|e| e.into_inner()) = None;
            let log = core.get(LOG).await?;
            let cursor = core.get_int(CURSOR).await?;
            let mut state = vec![(SENT, Some(hlc_text(batch.last)))];
            if log.is_none() {
                state.push((LOG, Some(appended.log.clone())));
            }
            // Only advance join progress when the batch landed on the same log
            // its preceding join batches belonged to (never mark a recreated log
            // joined from a stale unanswered batch).
            if batch.join_for_log.as_deref().is_none_or(|exp| exp == appended.log) {
                if batch.mark_joined {
                    state.push((JOINED, Some(appended.log.clone())));
                    state.push((JOIN_LOG, None));
                    state.push((JOIN_SENT, None));
                } else if let Some(j) = &batch.join_last {
                    state.push((JOIN_LOG, Some(appended.log.clone())));
                    state.push((JOIN_SENT, Some(j.encode())));
                }
            }
            // Right after the cursor: nothing between to read, and this batch
            // is what is here already.
            if (log.is_none() || log.as_deref() == Some(&appended.log)) && appended.seq == cursor + 1 {
                state.push((CURSOR, Some(appended.seq.to_string())));
            }
            core.put(state).await?;
            if let Some(detail) = persist_err {
                return Err(Error::Host(detail));
            }
            return Ok(appended.compact);
        }
    }

    async fn flush_pending_snapshot(&self) -> Result<Option<PendingSnapshot>> {
        let Some(pending) = self.pending_snapshot.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return Ok(None);
        };
        match self.transport.put_snapshot(pending.seq, pending.body.clone()).await {
            Ok(written) => {
                *self.pending_snapshot.lock().unwrap_or_else(|e| e.into_inner()) = None;
                Ok(written.then_some(pending))
            }
            Err(Error::SnapshotPersistFailed { detail, .. }) => Err(Error::Host(detail)),
            Err(e) => Err(e),
        }
    }

    /// Writes a snapshot at the cursor; whether one is there now.
    async fn write_snapshot(&self, run: &Run<'_>) -> Result<bool> {
        let core = &self.core;
        let cursor = core.get_int(CURSOR).await?;
        if cursor == 0 {
            return Ok(false);
        }
        let log = core.get(LOG).await?;
        let created_at = now_ms();
        let Some(ops) = core.snapshot_ops(run).await? else {
            core.host.warn("Sync snapshot left: a record could not be read".into());
            return Ok(false);
        };
        let body = core.seal.seal(&engine::encode(&ops, Map::new())?)?;
        let named: HashSet<String> = ops.iter().filter_map(|op| Core::<H, T, S>::blob_of(&op.d).map(str::to_string)).collect();
        match self.transport.put_snapshot(cursor, body.clone()).await {
            Ok(false) => {
                core.host.warn(format!("Sync snapshot at {cursor}: another is there already"));
                return Ok(true);
            }
            Ok(true) => {}
            Err(Error::SnapshotPersistFailed { seq, detail }) => {
                *self.pending_snapshot.lock().unwrap_or_else(|e| e.into_inner()) = Some(PendingSnapshot { log, seq, body, named, created_at });
                return Err(Error::Host(detail));
            }
            Err(e) => return Err(e),
        }
        core.sweep_blobs_as_of(named, created_at).await;
        Ok(true)
    }

    /// Forgets the log: the next sync reads it from its start and joins it
    /// again. For another account, or what is carried changing.
    pub async fn forget(host: &H) -> Result<()> {
        host.set_state([LOG, CURSOR, SENT, JOINED, JOIN_LOG, JOIN_SENT, PARTIAL].iter().map(|k| (format!("{PREFIX}{k}"), None)).collect()).await?;
        host.forget_passed(PREFIX.to_string()).await
    }

    /// The log of [account] from now on: another account's is forgotten.
    pub async fn bind(host: &H, account: &str) -> Result<()> {
        let key = format!("{PREFIX}{ACCOUNT}");
        if host.state(vec![key.clone()]).await?.pop().flatten().as_deref() == Some(account) {
            return Ok(());
        }
        Self::forget(host).await?;
        host.set_state(vec![(key, Some(account.to_string()))]).await
    }
}
