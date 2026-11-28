//! What both syncs share, whatever keeps the ops: reading the records as ops
//! (a large one as a blob), sealing them in batches, and handing the host the
//! ops other devices sent.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read as _, Write as _};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};

use fl_sync::{Hlc, Op};
use serde_json::{Map, Value, json};
use tokio::sync::{Mutex, MutexGuard, watch};

use crate::{BlobStore, Error, Host, Read, Result, RetainedBinding, Seal, Stamped, now_ms};

/// A batch or snapshot read: its ops, and what it holds besides.
pub type Parsed = (Vec<Op>, Map<String, Value>);

/// What a batch's sealed bytes may be, under homebase's 256 KiB.
pub const BATCH_MAX: usize = 250 << 10;

/// A record larger than this (as JSON) goes as a blob the op names
/// (`{"$blob": name}`), so a batch keeps many records.
pub const INLINE_MAX: usize = 64 << 10;

const BLOB_KEY: &str = "$blob";
const BLOB_PREFIX: &str = "op-";
const LEGACY_BLOBS_EXTRA: &str = "legacy_blobs";
/// Per-blob incremental state key prefix (`{prefix}signed_blob.{name}` -> `"1"`).
pub(crate) const SIGNED_BLOB_STATE_PREFIX: &str = "signed_blob.";
// TODO(migration): remove legacy monolithic `signed_blobs` state key once migrated.
const SIGNED_BLOBS_STATE: &str = "signed_blobs";
const LEGACY_BLOBS_STATE: &str = "legacy_blobs";

pub(crate) fn blob_of(d: &Option<Value>) -> Option<&str> {
    match d {
        Some(Value::Object(m)) if m.len() == 1 => m.get(BLOB_KEY)?.as_str(),
        _ => None,
    }
}

#[derive(Clone, Default)]
pub(crate) struct BlobBindings {
    /// Pre-signing unsigned blobs retained in a signed batch or snapshot
    /// (`name -> blake3_hex(remote_sealed_ciphertext)`).
    pub legacy_blobs: HashMap<String, String>,
    /// For an unsigned container accepted below the signing floor: each blob
    /// a verified signed snapshot covering it names, with its legacy digest
    /// (`None`: named as signed).
    pub covering: Option<Arc<HashMap<String, Option<String>>>>,
}

/// An op prepared for sending alongside the original snapshot stamp (`r.h`)
/// from the caller's record slice, so push cursors (`SENT`, `JOIN_SENT`,
/// `stopped`) stay monotonic even if a local concurrent edit refreshed `op.h`.
#[derive(Clone)]
pub(crate) struct PreparedOp {
    pub op: Op,
    pub snapshot_h: Hlc,
}

/// A blob nothing names is removed this long after it was written: a batch
/// being sent now may name it.
const BLOB_GRACE_MS: i64 = 24 * 3600 * 1000;

/// 2: the stores beside the entities, the secrets, picked files, skills and
/// benchmarks are records too. A build reading 1 only would compact them
/// away, so it stops at a 2 instead ([Error::TooNew]); 1 is still read.
pub const VERSION: i64 = 2;

/// Records read from the host at once.
const READ_CHUNK: usize = 256;

/// How a large op's blob is named.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Naming {
    /// By the op's stamp, keyed by the sync key: a snapshot carrying the same
    /// op names the batch's blob, so the sweep keeps what a batch names.
    Keyed,
    /// By the stamp, its device first: only that device removes it, and it
    /// has seen the op. Not by the key, which a merge with another device's
    /// may replace while a segment written before still names the blob.
    ByDevice,
}

/// One run's view: what is carried, as the run first asked.
pub(crate) struct Run<'a> {
    _serial: MutexGuard<'a, ()>,
    pub not_carried: HashSet<String>,
}

impl Run<'_> {
    pub fn carries(&self, c: &str) -> bool {
        !self.not_carried.contains(c)
    }
}

pub(crate) struct Core<H, B, S> {
    pub host: Arc<H>,
    pub blobs: Arc<B>,
    pub seal: Arc<S>,
    /// Where this engine's keys are in the state: `log.`, `seg.`.
    pub prefix: &'static str,
    naming: Naming,
    /// Whether the last read stopped at a newer build's batch.
    pub too_new: watch::Sender<bool>,
    serial: Mutex<()>,
    /// Whether the key was looked for again in this read: once is enough to
    /// find one that replaced it.
    refreshed: AtomicBool,
    /// Whether any legacy monolithic `signed_blobs` array has been migrated to
    /// incremental `signed_blob.<name>` state keys.
    migrated_signed_blobs: AtomicBool,
}

impl<H: Host, B: BlobStore, S: Seal> Core<H, B, S> {
    pub fn new(host: Arc<H>, blobs: Arc<B>, seal: Arc<S>, prefix: &'static str, naming: Naming) -> Self {
        Self {
            host,
            blobs,
            seal,
            prefix,
            naming,
            too_new: watch::Sender::new(false),
            serial: Mutex::new(()),
            refreshed: AtomicBool::new(false),
            migrated_signed_blobs: AtomicBool::new(false),
        }
    }

    /// One run at a time.
    pub async fn run(&self) -> Result<Run<'_>> {
        let serial = self.serial.lock().await;
        let not_carried = self.host.not_carried().await?;
        Ok(Run { _serial: serial, not_carried })
    }

    pub fn begin_read(&self) {
        self.refreshed.store(false, Ordering::SeqCst);
    }

    /// The outcome of a read of the other devices' ops, noting whether it
    /// stopped at a newer build's batch.
    pub async fn reading(&self, run: &Run<'_>, read: Result<()>) -> Result<()> {
        match read {
            Err(e @ Error::TooNew(_)) => {
                self.too_new.send_replace(true);
                Err(e)
            }
            Err(e) => Err(e),
            Ok(()) => {
                self.too_new.send_replace(false);
                self.host.after_read(run.not_carried.clone()).await
            }
        }
    }

    pub async fn device(&self) -> Result<u64> {
        self.host.device().await
    }

    // State.

    pub async fn get(&self, k: &str) -> Result<Option<String>> {
        Ok(self.host.state(vec![format!("{}{k}", self.prefix)]).await?.pop().flatten())
    }

    pub async fn get_int(&self, k: &str) -> Result<i64> {
        Ok(self.get(k).await?.and_then(|v| v.parse().ok()).unwrap_or(0))
    }

    pub async fn get_hlc(&self, k: &str) -> Result<Option<Hlc>> {
        Ok(self.get(k).await?.and_then(|v| v.parse().ok()))
    }

    pub async fn put(&self, values: Vec<(&str, Option<String>)>) -> Result<()> {
        self.host.set_state(values.into_iter().map(|(k, v)| (format!("{}{k}", self.prefix), v)).collect()).await
    }

    fn signed_blob_key(&self, name: &str) -> String {
        format!("{}{SIGNED_BLOB_STATE_PREFIX}{name}", self.prefix)
    }

    // TODO(migration): remove once legacy monolithic `signed_blobs` state rows
    // have been migrated to incremental `signed_blob.<name>` keys.
    async fn migrate_legacy_signed_blobs(&self) -> Result<()> {
        if self.migrated_signed_blobs.load(Ordering::Acquire) {
            return Ok(());
        }
        if let Some(raw) = self.get(SIGNED_BLOBS_STATE).await? {
            let names: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
            let mut updates: Vec<(String, Option<String>)> = names
                .into_iter()
                .map(|name| (self.signed_blob_key(&name), Some("1".to_string())))
                .collect();
            updates.push((format!("{}{SIGNED_BLOBS_STATE}", self.prefix), None));
            self.host.set_state(updates).await?;
        }
        self.migrated_signed_blobs.store(true, Ordering::Release);
        Ok(())
    }

    async fn known_signed_blobs_for(&self, names: &HashSet<String>) -> Result<HashSet<String>> {
        if names.is_empty() {
            return Ok(HashSet::new());
        }
        self.migrate_legacy_signed_blobs().await?;
        let ordered: Vec<&String> = names.iter().collect();
        let keys: Vec<String> = ordered.iter().map(|name| self.signed_blob_key(name)).collect();
        let values = self.host.state(keys).await?;
        Ok(ordered
            .into_iter()
            .zip(values)
            .filter_map(|(name, val)| val.is_some().then(|| name.clone()))
            .collect())
    }

    async fn is_known_signed_blob(&self, name: &str) -> Result<bool> {
        self.migrate_legacy_signed_blobs().await?;
        Ok(self.host.state(vec![self.signed_blob_key(name)]).await?.pop().flatten().is_some())
    }

    async fn record_signed_blobs(&self, added: &HashSet<String>) -> Result<()> {
        if added.is_empty() {
            return Ok(());
        }
        let updates: Vec<(String, Option<String>)> = added
            .iter()
            .map(|name| (self.signed_blob_key(name), Some("1".to_string())))
            .collect();
        self.host.set_state(updates).await
    }

    async fn known_legacy_blobs(&self) -> Result<HashMap<String, String>> {
        let Some(raw) = self.get(LEGACY_BLOBS_STATE).await? else {
            return Ok(HashMap::new());
        };
        Ok(serde_json::from_str::<HashMap<String, String>>(&raw).unwrap_or_default())
    }

    async fn record_legacy_blobs(&self, added: &HashMap<String, String>) -> Result<()> {
        if added.is_empty() {
            return Ok(());
        }
        let mut cur: BTreeMap<String, String> = self.known_legacy_blobs().await?.into_iter().collect();
        let mut changed = false;
        for (k, v) in added {
            if cur.get(k) != Some(v) {
                cur.insert(k.clone(), v.clone());
                changed = true;
            }
        }
        if changed {
            let raw = serde_json::to_string(&cur).map_err(|e| Error::Host(e.to_string()))?;
            self.put(vec![(LEGACY_BLOBS_STATE, Some(raw))]).await?;
        }
        Ok(())
    }

    // Records as ops.

    /// [records] (the oldest first) as ops; `complete` false when one could
    /// not be read now: the ops are those before it.
    pub async fn ops_of_bound(&self, records: &[Stamped]) -> Result<(Vec<Op>, bool, BlobBindings)> {
        let (prepared, complete, bindings) = self.ops_of_prepared(records).await?;
        Ok((prepared.into_iter().map(|p| p.op).collect(), complete, bindings))
    }

    pub async fn ops_of_prepared(&self, records: &[Stamped]) -> Result<(Vec<PreparedOp>, bool, BlobBindings)> {
        let known_legacy = if matches!(self.naming, Naming::Keyed) && self.blobs.signs_blobs() {
            self.known_legacy_blobs().await?
        } else {
            HashMap::new()
        };
        let mut sender = Sender::new(known_legacy);
        let mut ops = Vec::new();
        for chunk in records.chunks(READ_CHUNK) {
            let read = match self.host.read(chunk.iter().map(|r| (r.c.clone(), r.id.clone())).collect()).await {
                Ok(r) => r,
                Err(e) => {
                    let _ = self.record_signed_blobs(&sender.newly_signed).await;
                    let _ = self.record_legacy_blobs(&sender.newly_legacy).await;
                    return Err(e);
                }
            };
            if read.len() != chunk.len() {
                let _ = self.record_signed_blobs(&sender.newly_signed).await;
                let _ = self.record_legacy_blobs(&sender.newly_legacy).await;
                return Err(Error::Host(format!("read {} of {} records", read.len(), chunk.len())));
            }
            for (r, d) in chunk.iter().zip(read) {
                let d = match d {
                    Read::Unread => {
                        self.record_signed_blobs(&sender.newly_signed).await?;
                        self.record_legacy_blobs(&sender.newly_legacy).await?;
                        return Ok((ops, false, sender.bindings()));
                    }
                    Read::Silent => continue,
                    Read::Gone => None,
                    Read::Value(v) => Some(v),
                };
                match sender.send(self, Op { c: r.c.clone(), id: r.id.clone(), h: r.h, d }, false).await {
                    Ok(SendOutcome::Sent(op)) => ops.push(PreparedOp { op, snapshot_h: r.h }),
                    Ok(SendOutcome::Skip) => continue,
                    Ok(SendOutcome::Unread) => {
                        self.record_signed_blobs(&sender.newly_signed).await?;
                        self.record_legacy_blobs(&sender.newly_legacy).await?;
                        return Ok((ops, false, sender.bindings()));
                    }
                    Err(e) => {
                        let _ = self.record_signed_blobs(&sender.newly_signed).await;
                        let _ = self.record_legacy_blobs(&sender.newly_legacy).await;
                        return Err(e);
                    }
                }
            }
        }
        self.record_signed_blobs(&sender.newly_signed).await?;
        self.record_legacy_blobs(&sender.newly_legacy).await?;
        Ok((ops, true, sender.bindings()))
    }

    /// The blob of the op stamped [h].
    fn blob_name(&self, h: Hlc) -> String {
        let h = h.to_string();
        match self.naming {
            Naming::Keyed => format!("{BLOB_PREFIX}{}.age", self.seal.name_of(h.as_bytes())),
            Naming::ByDevice => format!("{BLOB_PREFIX}{}-{}.age", &h[16..], &h[..16]),
        }
    }

    /// The blobs [sweep_blobs] may remove.
    async fn sweep_prefix(&self) -> Result<String> {
        Ok(match self.naming {
            Naming::Keyed => BLOB_PREFIX.to_string(),
            Naming::ByDevice => format!("{BLOB_PREFIX}{:016x}-", self.device().await?),
        })
    }

    /// Removes the blobs the snapshot just written does not name, past the
    /// grace. A batch the snapshot covers may name one still: then its op
    /// lost to a later one of its record, which a device reading the batch
    /// reads after it, so the op is passed over ([resolve]). Best effort.
    pub async fn sweep_blobs(&self, named: HashSet<String>) {
        self.sweep_blobs_as_of(named, now_ms()).await;
    }

    /// Removes blobs not in [named] whose timestamp is older than
    /// `as_of_ms - BLOB_GRACE_MS`. Anchoring `as_of_ms` to when a snapshot's
    /// [named] set was captured prevents a delayed sweep from deleting blobs
    /// uploaded by other devices after that snapshot.
    pub async fn sweep_blobs_as_of(&self, named: HashSet<String>, as_of_ms: i64) {
        let swept = async {
            let before = as_of_ms.saturating_sub(BLOB_GRACE_MS);
            for blob in self.blobs.blobs(self.sweep_prefix().await?).await? {
                if named.contains(&blob.name) || blob.at.is_none_or(|at| at > before) {
                    continue;
                }
                self.blobs.delete_blob(blob.name).await?;
            }
            Ok::<_, Error>(())
        };
        if let Err(e) = swept.await {
            self.host.warn(format!("Sync blobs sweep: {e}"));
        }
    }

    /// [ops] with each blob an op names read in; an op whose blob is gone or
    /// unreadable is left out (a later op of its record has replaced it, or
    /// nothing here reads it). With [wait], a blob not there is
    /// [Error::Pending]: it may only not have arrived.
    async fn resolve_bound(
        &self,
        ops: Vec<Op>,
        bindings: &BlobBindings,
        container_signed: bool,
        wait: bool,
    ) -> Result<Vec<Op>> {
        let referenced: HashSet<String> = ops.iter().filter_map(|op| blob_of(&op.d).map(str::to_string)).collect();
        let known_signed = self.known_signed_blobs_for(&referenced).await?;
        let mut newly_signed = HashSet::new();
        let mut newly_legacy = HashMap::new();
        let mut out = Vec::with_capacity(ops.len());
        for op in ops {
            let Some(name) = blob_of(&op.d).map(str::to_string) else {
                out.push(op);
                continue;
            };
            let h_text = op.h.to_string();
            let bound_to_op = match self.naming {
                Naming::Keyed => name
                    .strip_prefix(BLOB_PREFIX)
                    .and_then(|s| s.strip_suffix(".age"))
                    .is_some_and(|stem| self.seal.matches_name_of(stem, h_text.as_bytes())),
                Naming::ByDevice => name == self.blob_name(op.h),
            };
            let previously_signed = known_signed.contains(&name) || newly_signed.contains(&name);
            // Unsigned bytes are taken on the retained path only when bound to
            // a digest from a verified container, trusted as far as it is: its
            // own, or (unsigned, so pre-signing) that of a signed snapshot
            // covering it. Any other reference stays on the strict policy.
            let covering = if container_signed { None } else { bindings.covering.as_ref() };
            let covered = covering.map(|c| c.get(&name));
            if covered == Some(None) {
                // Not named by a snapshot covering it: a later op replaced it.
                self.host.warn(format!("Sync passed over {}/{}: a snapshot covering it replaced it", op.c, op.id));
                continue;
            }
            let retained = (bound_to_op && !previously_signed)
                .then(|| bindings.legacy_blobs.get(&name).or_else(|| covered.flatten()?.as_ref()))
                .flatten()
                .and_then(|hex| blake3::Hash::from_hex(hex).ok())
                .map(|d| RetainedBinding::Digest(*d.as_bytes()));
            let require_signed = previously_signed
                || (container_signed && retained.is_none())
                || covered == Some(Some(&None));
            let fetched = match self.blobs.get_blob_verified(name.clone(), retained).await {
                Ok(v) => v,
                Err(e) => {
                    let _ = self.record_signed_blobs(&newly_signed).await;
                    let _ = self.record_legacy_blobs(&newly_legacy).await;
                    return Err(e);
                }
            };
            let Some((sealed, was_signed)) = fetched else {
                if wait {
                    self.record_signed_blobs(&newly_signed).await?;
                    self.record_legacy_blobs(&newly_legacy).await?;
                    return Err(Error::Pending(name));
                }
                self.host.warn(format!("Sync passed over {}/{}: its blob is gone", op.c, op.id));
                continue;
            };
            if require_signed && !was_signed {
                self.record_signed_blobs(&newly_signed).await?;
                self.record_legacy_blobs(&newly_legacy).await?;
                return Err(Error::Untrusted(format!("{name}: server stripped signature")));
            }
            if was_signed {
                newly_signed.insert(name.clone());
            }
            let d = match self.open(&sealed).await {
                Ok(plain) => blob_value(&plain),
                Err(e @ Error::Unreadable(_)) => Err(e),
                Err(e) => {
                    self.record_signed_blobs(&newly_signed).await?;
                    self.record_legacy_blobs(&newly_legacy).await?;
                    return Err(e);
                }
            };
            match d {
                Ok(d) => {
                    if !was_signed && retained.is_some() && matches!(self.naming, Naming::Keyed) {
                        newly_legacy.insert(name.clone(), blake3::hash(&sealed).to_hex().to_string());
                    }
                    out.push(Op { d: (!d.is_null()).then_some(d), ..op });
                }
                Err(e) => self.host.warn(format!("Sync passed over {}/{}: its blob is unreadable: {e}", op.c, op.id)),
            }
        }
        self.record_signed_blobs(&newly_signed).await?;
        self.record_legacy_blobs(&newly_legacy).await?;
        Ok(out)
    }

    /// The newest of [ops] for each record: no blob is read for an op a
    /// later one of the same read replaces.
    pub fn newest(ops: Vec<Op>) -> Vec<Op> {
        let mut at: HashMap<(String, String), usize> = HashMap::new();
        let mut out: Vec<Op> = Vec::new();
        for op in ops {
            match at.get(&(op.c.clone(), op.id.clone())) {
                Some(&i) if out[i].h >= op.h => {}
                Some(&i) => out[i] = op,
                None => {
                    at.insert((op.c.clone(), op.id.clone()), out.len());
                    out.push(op);
                }
            }
        }
        out
    }

    /// What this device holds as a snapshot holds it: its records it syncs,
    /// and what it keeps for the others ([Host::pass]); `None` when a record
    /// could not be read.
    pub async fn snapshot_ops(&self, run: &Run<'_>) -> Result<Option<Vec<Op>>> {
        Ok(self.snapshot_ops_bound(run).await?.map(|(ops, _)| ops))
    }

    pub async fn snapshot_ops_bound(&self, run: &Run<'_>) -> Result<Option<(Vec<Op>, BlobBindings)>> {
        self.host.stamp().await?;
        let all: Vec<Stamped> = self.host.all().await?.into_iter().filter(|r| run.carries(&r.c)).collect();
        let (mut ops, complete, mut bindings) = self.ops_of_bound(&all).await?;
        if !complete {
            return Ok(None);
        }
        // Kept for the others: what this device does not sync, and what it
        // does not keep (a newer build's collections).
        let held: HashSet<(&str, &str)> = all.iter().map(|r| (r.c.as_str(), r.id.as_str())).collect();
        let known_legacy = if matches!(self.naming, Naming::Keyed) && self.blobs.signs_blobs() {
            self.known_legacy_blobs().await?
        } else {
            HashMap::new()
        };
        let mut sender = Sender::new(known_legacy);
        for op in self.host.passed(self.prefix.to_string()).await? {
            if !run.carries(&op.c) || !held.contains(&(op.c.as_str(), op.id.as_str())) {
                match sender.send(self, op, true).await {
                    Ok(SendOutcome::Sent(sent)) => ops.push(sent),
                    Ok(SendOutcome::Skip) => continue,
                    Ok(SendOutcome::Unread) => {
                        self.record_signed_blobs(&sender.newly_signed).await?;
                        self.record_legacy_blobs(&sender.newly_legacy).await?;
                        return Ok(None);
                    }
                    Err(e) => {
                        let _ = self.record_signed_blobs(&sender.newly_signed).await;
                        let _ = self.record_legacy_blobs(&sender.newly_legacy).await;
                        return Err(e);
                    }
                }
            }
        }
        self.record_signed_blobs(&sender.newly_signed).await?;
        self.record_legacy_blobs(&sender.newly_legacy).await?;
        let passed_bindings = sender.bindings();
        bindings.legacy_blobs.extend(passed_bindings.legacy_blobs);
        Ok(Some((ops, bindings)))
    }

    /// The ops that win over what is here written, then [state] set. Without
    /// [received] (nothing here reads the batch), only the state. With
    /// [wait_for_blobs], nothing is written while a blob is not there yet
    /// ([Error::Pending]).
    pub async fn apply(&self, run: &Run<'_>, received: Option<Vec<Op>>, state: Vec<(String, Option<String>)>, wait_for_blobs: bool) -> Result<()> {
        self.apply_bound(run, received.map(|ops| (ops, BlobBindings::default())), false, state, wait_for_blobs)
            .await
    }

    pub async fn apply_bound(
        &self,
        run: &Run<'_>,
        received: Option<(Vec<Op>, BlobBindings)>,
        container_signed: bool,
        state: Vec<(String, Option<String>)>,
        wait_for_blobs: bool,
    ) -> Result<()> {
        if let Some((received, bindings)) = received {
            let (carried, passed): (Vec<Op>, Vec<Op>) = received.into_iter().partition(|op| run.carries(&op.c));
            // Kept for the others: a snapshot written here carries them on,
            // as content, not a blob's name, so a key rotated here seals them
            // again.
            let passed = self.resolve_bound(Self::newest(passed), &bindings, container_signed, wait_for_blobs).await?;
            if !passed.is_empty() {
                self.host.pass(self.prefix.to_string(), passed).await?;
            }
            let ops = self.resolve_bound(carried, &bindings, container_signed, wait_for_blobs).await?;
            if !ops.is_empty() {
                let unkept = self.host.apply(ops).await?;
                if !unkept.is_empty() {
                    self.host.pass(self.prefix.to_string(), Self::newest(unkept)).await?;
                }
            }
        }
        self.host.set_state(state).await
    }

    /// [ops] in batches each sealed under [BATCH_MAX]. One op too large alone
    /// is left out and said.
    pub fn batches_prepared(&self, ops: Vec<PreparedOp>, bindings: &BlobBindings) -> Result<Vec<(Vec<PreparedOp>, Vec<u8>)>> {
        let mut out = Vec::new();
        let mut todo = vec![ops];
        while let Some(chunk) = todo.pop() {
            if chunk.is_empty() {
                continue;
            }
            let raw_ops: Vec<Op> = chunk.iter().map(|p| p.op.clone()).collect();
            let extra = bindings.extra_for(&raw_ops);
            let body = self.seal.seal(&encode(&raw_ops, extra)?)?;
            if body.len() <= BATCH_MAX {
                out.push((chunk, body));
                continue;
            }
            if chunk.len() == 1 {
                self.host.warn(format!("Sync left out {}/{}: {} bytes", chunk[0].op.c, chunk[0].op.id, body.len()));
                continue;
            }
            let mut first = chunk;
            let second = first.split_off(first.len() / 2);
            // Popped first: the batches stay in the ops' order.
            todo.push(second);
            todo.push(first);
        }
        Ok(out)
    }

    /// [sealed] opened; sealed to a key that replaced the one held here, that
    /// key is taken first.
    pub async fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        match self.seal.open(sealed) {
            Err(Error::Unreadable(e)) => {
                if !self.refresh_key().await? {
                    return Err(Error::Unreadable(e));
                }
                self.seal.open(sealed)
            }
            other => other,
        }
    }

    /// Whether a key that replaced the one held here was found; looked for
    /// once per read.
    async fn refresh_key(&self) -> Result<bool> {
        Ok(!self.refreshed.swap(true, Ordering::SeqCst) && self.seal.refresh().await?)
    }

    /// [sealed]'s ops; `None`, said, for one nothing here can ever read (not
    /// sealed to this key, damaged), so the read goes on past it. A newer
    /// format stops the read.
    pub async fn decode_bound(&self, sealed: &[u8], what: &str) -> Result<Option<(Vec<Op>, BlobBindings)>> {
        let plain = match self.open(sealed).await {
            Ok(plain) => plain,
            Err(Error::Unreadable(e)) => {
                self.host.warn(format!("Sync skipped unreadable {what}: {e}"));
                return Ok(None);
            }
            Err(e) => return Err(e),
        };
        Ok(self.parse(&plain, what)?.map(|(ops, doc)| (ops, BlobBindings::from_doc(&doc))))
    }

    /// [plain]'s ops and what it holds besides; `None`, said, when it is not
    /// one this build reads.
    pub fn parse(&self, plain: &[u8], what: &str) -> Result<Option<Parsed>> {
        match parse(plain) {
            Ok(parsed) => Ok(Some(parsed)),
            Err(e @ Error::TooNew(_)) => Err(e),
            Err(e) => {
                self.host.warn(format!("Sync skipped unreadable {what}: {e}"));
                Ok(None)
            }
        }
    }
}

impl BlobBindings {
    pub fn from_doc(doc: &Map<String, Value>) -> Self {
        let legacy_blobs = doc
            .get(LEGACY_BLOBS_EXTRA)
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Self { legacy_blobs, covering: None }
    }

    /// Whether every blob [ops] name has a digest here.
    pub fn binds_all(&self, ops: &[Op]) -> bool {
        ops.iter().filter_map(|op| blob_of(&op.d)).all(|name| self.legacy_blobs.contains_key(name))
    }

    /// What a verified signed snapshot holding [ops] with these bindings
    /// covers ([Self::covering]).
    pub fn covering_of(&self, ops: &[Op]) -> HashMap<String, Option<String>> {
        ops.iter()
            .filter_map(|op| blob_of(&op.d))
            .map(|name| (name.to_string(), self.legacy_blobs.get(name).cloned()))
            .collect()
    }

    pub fn extra_for(&self, ops: &[Op]) -> Map<String, Value> {
        let mut extra = Map::new();
        let mut legacy = BTreeMap::new();
        for op in ops {
            if let Some(name) = blob_of(&op.d)
                && let Some(digest) = self.legacy_blobs.get(name)
            {
                legacy.insert(name.to_string(), Value::String(digest.clone()));
            }
        }
        if !legacy.is_empty() {
            extra.insert(LEGACY_BLOBS_EXTRA.into(), Value::Object(legacy.into_iter().collect()));
        }
        extra
    }
}

const CONTENT_UNCHECKED: u8 = 0;
const CONTENT_HELD: u8 = 1;
const CONTENT_DIFFERS: u8 = 2;
const CONTENT_UNREADABLE: u8 = 3;

enum BindOutcome {
    Bound,
    ContentMismatch,
}

enum SendOutcome {
    Sent(Op),
    Unread,
    Skip,
}

enum RefreshedOp {
    Changed(Op),
    Unread,
    Skip,
}

/// Sends ops: one larger than [INLINE_MAX] as a blob it names, sealed under
/// the key now.
struct Sender {
    there: Option<HashMap<String, bool>>,
    known_signed: HashMap<String, bool>,
    newly_signed: HashSet<String>,
    known_legacy: HashMap<String, String>,
    newly_legacy: HashMap<String, String>,
    legacy_blobs: HashMap<String, String>,
}

impl Sender {
    fn new(known_legacy: HashMap<String, String>) -> Self {
        Self {
            there: None,
            known_signed: HashMap::new(),
            newly_signed: HashSet::new(),
            known_legacy,
            newly_legacy: HashMap::new(),
            legacy_blobs: HashMap::new(),
        }
    }

    fn bindings(&self) -> BlobBindings {
        BlobBindings { legacy_blobs: self.legacy_blobs.clone(), covering: None }
    }

    async fn is_known_signed<H: Host, B: BlobStore, S: Seal>(&mut self, core: &Core<H, B, S>, name: &str) -> Result<bool> {
        if self.newly_signed.contains(name) {
            return Ok(true);
        }
        if let Some(&known) = self.known_signed.get(name) {
            return Ok(known);
        }
        let known = core.is_known_signed_blob(name).await?;
        self.known_signed.insert(name.to_string(), known);
        Ok(known)
    }

    async fn bind_existing_unsigned_blob<H: Host, B: BlobStore, S: Seal>(
        &mut self,
        core: &Core<H, B, S>,
        name: &str,
        json: &[u8],
        expected_value: &Option<Value>,
        from_conflict: bool,
    ) -> Result<BindOutcome> {
        if self.is_known_signed(core, name).await? {
            match core.blobs.get_blob_verified(name.to_string(), None).await? {
                Some((_, true)) => return Ok(BindOutcome::Bound),
                Some((_, false)) => return Err(Error::Untrusted(format!("{name}: server stripped signature"))),
                None => {
                    if from_conflict {
                        return Err(Error::Untrusted(format!("{name}: server answered 412 for missing blob")));
                    }
                    let sealed = core.seal.seal(&gzip(json)?)?;
                    let signed = core.blobs.put_blob_signed(name.to_string(), sealed).await?;
                    if !signed && core.blobs.signs_blobs() {
                        return Err(Error::Untrusted(format!("{name}: expected signed upload after missing blob")));
                    }
                    if let Some(there) = self.there.as_mut() {
                        there.insert(name.to_string(), signed);
                    }
                    if signed {
                        self.newly_signed.insert(name.to_string());
                    }
                    return Ok(BindOutcome::Bound);
                }
            }
        }
        // Unsigned bytes there are taken only when they hold this device's own
        // content for the op.
        let fetched = loop {
            let seen = AtomicU8::new(CONTENT_UNCHECKED);
            let holds = |sealed: &[u8]| {
                let found = match core.seal.open(sealed).and_then(|plain| blob_value(&plain)) {
                    Ok(v) if (!v.is_null()).then_some(&v) == expected_value.as_ref() => CONTENT_HELD,
                    Ok(_) => CONTENT_DIFFERS,
                    Err(_) => CONTENT_UNREADABLE,
                };
                seen.store(found, Ordering::Relaxed);
                found == CONTENT_HELD
            };
            match core.blobs.get_blob_verified(name.to_string(), Some(RetainedBinding::Content(&holds))).await {
                Err(Error::Untrusted(e)) => match seen.load(Ordering::Relaxed) {
                    CONTENT_DIFFERS => return Ok(BindOutcome::ContentMismatch),
                    CONTENT_UNREADABLE if core.refresh_key().await? => continue,
                    CONTENT_UNREADABLE => return Err(Error::Unreadable(e)),
                    _ => return Err(Error::Untrusted(e)),
                },
                other => break other?,
            }
        };
        match fetched {
            Some((_, true)) => {
                self.newly_signed.insert(name.to_string());
                if let Some(there) = self.there.as_mut() {
                    there.insert(name.to_string(), true);
                }
                Ok(BindOutcome::Bound)
            }
            Some((remote_sealed, false)) => {
                if let Some(there) = self.there.as_mut() {
                    there.insert(name.to_string(), false);
                }
                let hex = blake3::hash(&remote_sealed).to_hex().to_string();
                if let Some(cached) = self.known_legacy.get(name).or_else(|| self.newly_legacy.get(name))
                    && cached != &hex
                {
                    return Err(Error::Untrusted(format!("{name}: {}", crate::RETAINED_MISMATCH)));
                }
                self.newly_legacy.insert(name.to_string(), hex.clone());
                self.legacy_blobs.insert(name.to_string(), hex);
                Ok(BindOutcome::Bound)
            }
            None => {
                if from_conflict {
                    return Err(Error::Untrusted(format!("{name}: server answered 412 for missing blob")));
                }
                let sealed = core.seal.seal(&gzip(json)?)?;
                let signed = core.blobs.put_blob_signed(name.to_string(), sealed).await?;
                if !signed && core.blobs.signs_blobs() {
                    return Err(Error::Untrusted(format!("{name}: expected signed upload after missing blob")));
                }
                if let Some(there) = self.there.as_mut() {
                    there.insert(name.to_string(), signed);
                }
                if signed {
                    self.newly_signed.insert(name.to_string());
                }
                Ok(BindOutcome::Bound)
            }
        }
    }

    async fn refresh_local_op<H: Host, B: BlobStore, S: Seal>(
        core: &Core<H, B, S>,
        op: &Op,
        from_passed: bool,
    ) -> Result<Option<RefreshedOp>> {
        if from_passed {
            let found = core
                .host
                .passed(core.prefix.to_string())
                .await?
                .into_iter()
                .find(|p| p.c == op.c && p.id == op.id);
            let Some(next) = found else {
                return Ok(Some(RefreshedOp::Skip));
            };
            return Ok((next != *op).then_some(RefreshedOp::Changed(next)));
        }
        core.host.stamp().await?;
        let stamped = core
            .host
            .all()
            .await?
            .into_iter()
            .find(|r| r.c == op.c && r.id == op.id);
        let Some(r) = stamped else {
            return Ok(Some(RefreshedOp::Skip));
        };
        let mut read = core.host.read(vec![(op.c.clone(), op.id.clone())]).await?;
        if read.len() != 1 {
            return Err(Error::Host(format!("read {} of 1 record", read.len())));
        }
        let next_d = match read.pop().expect("len 1") {
            Read::Unread => return Ok(Some(RefreshedOp::Unread)),
            Read::Silent => return Ok(Some(RefreshedOp::Skip)),
            Read::Gone => None,
            Read::Value(v) => Some(v),
        };
        let next = Op { c: op.c.clone(), id: op.id.clone(), h: r.h, d: next_d };
        Ok((next != *op).then_some(RefreshedOp::Changed(next)))
    }

    async fn send<H: Host, B: BlobStore, S: Seal>(&mut self, core: &Core<H, B, S>, mut op: Op, from_passed: bool) -> Result<SendOutcome> {
        const MAX_LOCAL_REFRESHES: usize = 3;
        for attempt in 0..=MAX_LOCAL_REFRESHES {
            let json = serde_json::to_vec(&op.d).map_err(|e| Error::Host(e.to_string()))?;
            if json.len() <= INLINE_MAX {
                return Ok(SendOutcome::Sent(op));
            }
            let name = core.blob_name(op.h);
            if self.there.is_none() {
                self.there = Some(
                    core.blobs
                        .blobs(BLOB_PREFIX.to_string())
                        .await?
                        .into_iter()
                        .map(|b| (b.name, b.signed))
                        .collect(),
                );
            }
            let listed = self.there.as_ref().expect("listed").get(&name).copied();
            let bind_outcome = match listed {
                None => {
                    let sealed = core.seal.seal(&gzip(&json)?)?;
                    let signed = core.blobs.put_blob_signed(name.clone(), sealed).await?;
                    self.there.as_mut().expect("listed").insert(name.clone(), signed);
                    if signed {
                        self.newly_signed.insert(name.clone());
                        BindOutcome::Bound
                    } else if matches!(core.naming, Naming::Keyed) && core.blobs.signs_blobs() {
                        self.bind_existing_unsigned_blob(core, &name, &json, &op.d, true).await?
                    } else {
                        BindOutcome::Bound
                    }
                }
                Some(true) => {
                    if matches!(core.naming, Naming::Keyed) && core.blobs.signs_blobs() {
                        if self.is_known_signed(core, &name).await? {
                            BindOutcome::Bound
                        } else {
                            // Listing metadata is untrusted: fetch and verify the
                            // blob body before persisting its name as signed, and
                            // fall back to legacy binding checks if unsigned.
                            self.bind_existing_unsigned_blob(core, &name, &json, &op.d, false).await?
                        }
                    } else {
                        BindOutcome::Bound
                    }
                }
                Some(false) => {
                    if matches!(core.naming, Naming::Keyed) && core.blobs.signs_blobs() {
                        self.bind_existing_unsigned_blob(core, &name, &json, &op.d, false).await?
                    } else {
                        BindOutcome::Bound
                    }
                }
            };
            match bind_outcome {
                BindOutcome::Bound => return Ok(SendOutcome::Sent(Op { d: Some(json!({ BLOB_KEY: name })), ..op })),
                BindOutcome::ContentMismatch => {
                    if attempt < MAX_LOCAL_REFRESHES
                        && let Some(refreshed) = Self::refresh_local_op(core, &op, from_passed).await?
                    {
                        match refreshed {
                            RefreshedOp::Changed(next_op) => {
                                op = next_op;
                                continue;
                            }
                            RefreshedOp::Unread => return Ok(SendOutcome::Unread),
                            RefreshedOp::Skip => return Ok(SendOutcome::Skip),
                        }
                    }
                    return Err(Error::Untrusted(format!("{name}: unsigned blob content mismatch")));
                }
            }
        }
        unreachable!("loop returns on final attempt")
    }
}

/// [ops] as a batch or snapshot holds them, with [extra] beside them.
pub fn encode(ops: &[Op], extra: Map<String, Value>) -> Result<Vec<u8>> {
    let mut doc = Map::new();
    doc.insert("v".into(), json!(VERSION));
    doc.insert("ops".into(), serde_json::to_value(ops).map_err(|e| Error::Host(e.to_string()))?);
    doc.extend(extra);
    gzip(&serde_json::to_vec(&doc).map_err(|e| Error::Host(e.to_string()))?)
}

/// [plain]'s ops and the rest of it.
pub fn parse(plain: &[u8]) -> Result<Parsed> {
    let json = gunzip(plain)?;
    let mut doc: Map<String, Value> = serde_json::from_slice(&json).map_err(|e| Error::Unreadable(e.to_string()))?;
    let version = doc.get("v").cloned().unwrap_or(Value::Null);
    match version.as_i64() {
        Some(v) if v > VERSION => return Err(Error::TooNew(version)),
        Some(v) if v >= 1 => {}
        _ => return Err(Error::Unreadable(format!("version {version}"))),
    }
    let ops = doc.remove("ops").unwrap_or(Value::Null);
    let ops: Vec<Op> = serde_json::from_value(ops).map_err(|e| Error::Unreadable(e.to_string()))?;
    Ok((ops, doc))
}

pub fn gzip(data: &[u8]) -> Result<Vec<u8>> {
    let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    e.write_all(data).and_then(|_| e.finish()).map_err(|e| Error::Host(e.to_string()))
}

/// A blob's opened bytes as the record's value.
fn blob_value(plain: &[u8]) -> Result<Value> {
    serde_json::from_slice(&gunzip(plain)?).map_err(|e| Error::Unreadable(e.to_string()))
}

pub fn gunzip(data: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    flate2::read::MultiGzDecoder::new(data).read_to_end(&mut out).map_err(|e| Error::Unreadable(format!("gzip: {e}")))?;
    Ok(out)
}

/// A batch's `Idempotency-Key`: random, kept with its bytes until answered.
pub fn new_key() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("the OS random source");
    b.iter().map(|x| format!("{x:02x}")).collect()
}
