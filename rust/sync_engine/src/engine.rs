//! What both syncs share, whatever keeps the ops: reading the records as ops
//! (a large one as a blob), sealing them in batches, and handing the host the
//! ops other devices sent.

use std::collections::{HashMap, HashSet};
use std::io::{Read as _, Write as _};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use fl_sync::{Hlc, Op};
use serde_json::{Map, Value, json};
use tokio::sync::{Mutex, MutexGuard, watch};

use crate::{BlobStore, Error, Host, Read, Result, Seal, Stamped, now_ms};

/// A batch or snapshot read: its ops, and what it holds besides.
pub type Parsed = (Vec<Op>, Map<String, Value>);

/// What a batch's sealed bytes may be, under homebase's 256 KiB.
pub const BATCH_MAX: usize = 250 << 10;

/// A record larger than this (as JSON) goes as a blob the op names
/// (`{"$blob": name}`), so a batch keeps many records.
pub const INLINE_MAX: usize = 64 << 10;

const BLOB_KEY: &str = "$blob";
const BLOB_PREFIX: &str = "op-";

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
}

impl<H: Host, B: BlobStore, S: Seal> Core<H, B, S> {
    pub fn new(host: Arc<H>, blobs: Arc<B>, seal: Arc<S>, prefix: &'static str, naming: Naming) -> Self {
        Self { host, blobs, seal, prefix, naming, too_new: watch::Sender::new(false), serial: Mutex::new(()), refreshed: AtomicBool::new(false) }
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

    // Records as ops.

    /// [records] (the oldest first) as ops; `complete` false when one could
    /// not be read now: the ops are those before it.
    pub async fn ops_of(&self, records: &[Stamped]) -> Result<(Vec<Op>, bool)> {
        let mut sender = Sender::default();
        let mut ops = Vec::new();
        for chunk in records.chunks(READ_CHUNK) {
            let read = self.host.read(chunk.iter().map(|r| (r.c.clone(), r.id.clone())).collect()).await?;
            if read.len() != chunk.len() {
                return Err(Error::Host(format!("read {} of {} records", read.len(), chunk.len())));
            }
            for (r, d) in chunk.iter().zip(read) {
                let d = match d {
                    Read::Unread => return Ok((ops, false)),
                    Read::Silent => continue,
                    Read::Gone => None,
                    Read::Value(v) => Some(v),
                };
                ops.push(sender.send(self, Op { c: r.c.clone(), id: r.id.clone(), h: r.h, d }).await?);
            }
        }
        Ok((ops, true))
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

    pub fn blob_of(d: &Option<Value>) -> Option<&str> {
        match d {
            Some(Value::Object(m)) if m.len() == 1 => m.get(BLOB_KEY)?.as_str(),
            _ => None,
        }
    }

    /// Removes the blobs the snapshot just written does not name, past the
    /// grace. A batch the snapshot covers may name one still: then its op
    /// lost to a later one of its record, which a device reading the batch
    /// reads after it, so the op is passed over ([resolve]). Best effort.
    pub async fn sweep_blobs(&self, named: HashSet<String>) {
        let swept = async {
            let before = now_ms() - BLOB_GRACE_MS;
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
    /// nothing here reads it).
    pub async fn resolve(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
        let mut out = Vec::with_capacity(ops.len());
        for op in ops {
            let Some(name) = Self::blob_of(&op.d).map(str::to_string) else {
                out.push(op);
                continue;
            };
            let Some(sealed) = self.blobs.get_blob(name).await? else {
                self.host.warn(format!("Sync passed over {}/{}: its blob is gone", op.c, op.id));
                continue;
            };
            let d = match self.open(&sealed).await {
                Ok(plain) => gunzip(&plain).and_then(|json| serde_json::from_slice::<Value>(&json).map_err(|e| Error::Unreadable(e.to_string()))),
                Err(e @ Error::Unreadable(_)) => Err(e),
                Err(e) => return Err(e),
            };
            match d {
                Ok(d) => out.push(Op { d: (!d.is_null()).then_some(d), ..op }),
                Err(e) => self.host.warn(format!("Sync passed over {}/{}: its blob is unreadable: {e}", op.c, op.id)),
            }
        }
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
        self.host.stamp().await?;
        let all: Vec<Stamped> = self.host.all().await?.into_iter().filter(|r| run.carries(&r.c)).collect();
        let (mut ops, complete) = self.ops_of(&all).await?;
        if !complete {
            return Ok(None);
        }
        let mut sender = Sender::default();
        for op in self.host.passed(self.prefix.to_string()).await? {
            if !run.carries(&op.c) {
                ops.push(sender.send(self, op).await?);
            }
        }
        Ok(Some(ops))
    }

    /// The ops that win over what is here written, then [state] set. Without
    /// [received] (nothing here reads the batch), only the state.
    pub async fn apply(&self, run: &Run<'_>, received: Option<Vec<Op>>, state: Vec<(String, Option<String>)>) -> Result<()> {
        if let Some(received) = received {
            let (carried, passed): (Vec<Op>, Vec<Op>) = received.into_iter().partition(|op| run.carries(&op.c));
            // Kept for the others: a snapshot written here carries them on,
            // as content, not a blob's name, so a key rotated here seals them
            // again.
            let passed = self.resolve(Self::newest(passed)).await?;
            if !passed.is_empty() {
                self.host.pass(self.prefix.to_string(), passed).await?;
            }
            let ops = self.resolve(carried).await?;
            if !ops.is_empty() {
                self.host.apply(ops).await?;
            }
        }
        self.host.set_state(state).await
    }

    /// [ops] in batches each sealed under [BATCH_MAX]. One op too large alone
    /// is left out and said.
    pub fn batches(&self, ops: Vec<Op>) -> Result<Vec<(Vec<Op>, Vec<u8>)>> {
        let mut out = Vec::new();
        let mut todo = vec![ops];
        while let Some(ops) = todo.pop() {
            if ops.is_empty() {
                continue;
            }
            let body = self.seal.seal(&encode(&ops, Map::new())?)?;
            if body.len() <= BATCH_MAX {
                out.push((ops, body));
                continue;
            }
            if ops.len() == 1 {
                self.host.warn(format!("Sync left out {}/{}: {} bytes", ops[0].c, ops[0].id, body.len()));
                continue;
            }
            let mut first = ops;
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
                if self.refreshed.swap(true, Ordering::SeqCst) || !self.seal.refresh().await? {
                    return Err(Error::Unreadable(e));
                }
                self.seal.open(sealed)
            }
            other => other,
        }
    }

    /// [sealed]'s ops; `None`, said, for one nothing here can ever read (not
    /// sealed to this key, damaged), so the read goes on past it. A newer
    /// format stops the read.
    pub async fn decode(&self, sealed: &[u8], what: &str) -> Result<Option<Vec<Op>>> {
        let plain = match self.open(sealed).await {
            Ok(plain) => plain,
            Err(Error::Unreadable(e)) => {
                self.host.warn(format!("Sync skipped unreadable {what}: {e}"));
                return Ok(None);
            }
            Err(e) => return Err(e),
        };
        Ok(self.parse(&plain, what)?.map(|(ops, _)| ops))
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

/// Sends ops: one larger than [INLINE_MAX] as a blob it names, sealed under
/// the key now.
#[derive(Default)]
struct Sender {
    there: Option<HashSet<String>>,
}

impl Sender {
    async fn send<H: Host, B: BlobStore, S: Seal>(&mut self, core: &Core<H, B, S>, op: Op) -> Result<Op> {
        let json = serde_json::to_vec(&op.d).map_err(|e| Error::Host(e.to_string()))?;
        if json.len() <= INLINE_MAX {
            return Ok(op);
        }
        let name = core.blob_name(op.h);
        if self.there.is_none() {
            self.there = Some(core.blobs.blobs(BLOB_PREFIX.to_string()).await?.into_iter().map(|b| b.name).collect());
        }
        let there = self.there.as_mut().expect("listed");
        if !there.contains(&name) {
            core.blobs.put_blob(name.clone(), core.seal.seal(&gzip(&json)?)?).await?;
            there.insert(name.clone());
        }
        Ok(Op { d: Some(json!({ BLOB_KEY: name })), ..op })
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
