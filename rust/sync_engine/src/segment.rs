//! The sync where nothing orders writes (WebDAV, iCloud): each device writes
//! only its own files, so no write races another device's.
//!
//! - `seg-<device>-<n>.age`: a batch of ops, n from 1 up, never written again.
//! - `snap-<device>.age`: the device's state, and how far it had read each
//!   device's segments (`covers`).
//! - `op-<device>-<stamp>.age`: the record of a large op the device stamped.
//!
//! A device reads each other device's segments after the last it read; one
//! gone (removed once covered), or not there yet while later ones are, is read
//! from a snapshot covering it. It removes its own segments once every
//! snapshot covers them, or once one does and they are [SEGMENT_MAX_MS] old.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::{Map, Value, json};
use tokio::sync::watch;

use crate::engine::{self, Core, Naming, Run};
use crate::{BlobStore, Error, Host, Listed, Result, Seal, now_ms};

/// A folder only this app writes to, on WebDAV or iCloud. Its [put_blob]
/// writes over one there.
pub trait Files: BlobStore {
    /// [body] as [name], in place of one there.
    fn write(&self, name: String, body: Vec<u8>) -> impl Future<Output = Result<()>> + Send;
}

const PREFIX: &str = "seg.";
const STORE: &str = "store";
const CURSOR: &str = "cur.";
const N: &str = "n";
const SENT: &str = "sent";
const JOINED: &str = "joined";
const SINCE: &str = "since";
const SNAPPED: &str = "snapped";
const COLLECTED: &str = "collected";

/// Segments read or written after which this device writes its snapshot
/// again; and how many of its own it keeps before looking which to remove.
pub const COMPACT_EVERY: i64 = 32;

const DAY_MS: i64 = 24 * 3600 * 1000;

/// How long a segment no key here opens stops the read of its device: one
/// sealed to another device's key, made at the same time as this one's before
/// either reached the other, opens once the keys are merged. Past it, the
/// segment is passed over.
const UNREADABLE_MAX_MS: i64 = 7 * DAY_MS;

/// Past this, a segment one snapshot covers is removed though another does
/// not: a device gone for good holds none back for ever.
const SEGMENT_MAX_MS: i64 = 30 * DAY_MS;

/// How often this device's segments are looked at for removal: each look
/// reads the other devices' snapshots.
const COLLECT_EVERY_MS: i64 = 6 * 3600 * 1000;

fn segment_name(device: &str, n: i64) -> String {
    format!("seg-{device}-{n}.age")
}

fn snapshot_name(device: &str) -> String {
    format!("snap-{device}.age")
}

fn is_device(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A folder's files, by kind.
#[derive(Default)]
struct Listing {
    /// Each device's segments, by number, and when each was written.
    segments: BTreeMap<String, BTreeMap<i64, Option<i64>>>,
    snapshots: BTreeMap<String, Option<i64>>,
}

impl Listing {
    fn of(files: Vec<Listed>) -> Self {
        let mut listing = Listing::default();
        for f in files {
            let Some(stem) = f.name.strip_suffix(".age") else { continue };
            if let Some(rest) = stem.strip_prefix("seg-")
                && let Some((device, n)) = rest.split_once('-')
                && is_device(device)
                && !n.is_empty()
                && n.bytes().all(|b| b.is_ascii_digit())
                && let Ok(n) = n.parse::<i64>()
            {
                listing.segments.entry(device.to_string()).or_default().insert(n, f.at);
            } else if let Some(device) = stem.strip_prefix("snap-")
                && is_device(device)
            {
                listing.snapshots.insert(device.to_string(), f.at);
            }
        }
        listing
    }
}

pub struct SegmentSync<H, F, S> {
    core: Core<H, F, S>,
    files: Arc<F>,
    /// The snapshots read to close a gap, and when each was written: one not
    /// written again since is not read again while the gap stays.
    snapshots_read: Mutex<HashMap<String, Option<i64>>>,
}

impl<H: Host, F: Files, S: Seal> SegmentSync<H, F, S> {
    pub fn new(host: Arc<H>, files: Arc<F>, seal: Arc<S>) -> Self {
        Self { core: Core::new(host, files.clone(), seal, PREFIX, Naming::ByDevice), files, snapshots_read: Mutex::new(HashMap::new()) }
    }

    pub fn too_new(&self) -> watch::Receiver<bool> {
        self.core.too_new.subscribe()
    }

    async fn mine(&self) -> Result<String> {
        Ok(format!("{:016x}", self.core.device().await?))
    }

    async fn cursor(&self, device: &str) -> Result<i64> {
        self.core.get_int(&format!("{CURSOR}{device}")).await
    }

    /// Reads what other devices wrote, then writes what this one has: written
    /// even when a device's segments cannot be read on (a newer build's).
    pub async fn sync(&self) -> Result<()> {
        let run = self.core.run().await?;
        self.core.begin_read();
        let listed = Listing::of(self.files.blobs(String::new()).await?);
        let read = self.read(&run, &listed).await;
        let read = self.core.reading(&run, read).await;
        self.push(&run, &listed).await?;
        read?;
        if self.core.get_int(SINCE).await? >= COMPACT_EVERY {
            self.write_snapshot(&run).await?;
        }
        self.collect(&listed).await;
        Ok(())
    }

    /// [forget], after the run going on.
    pub async fn reset(&self) -> Result<()> {
        let _run = self.core.run().await?;
        Self::forget(&*self.core.host).await?;
        self.core.too_new.send_replace(false);
        Ok(())
    }

    async fn read(&self, run: &Run<'_>, listed: &Listing) -> Result<()> {
        let mine = self.mine().await?;
        let mut read: HashSet<String> = {
            let done = self.snapshots_read.lock().unwrap_or_else(|e| e.into_inner());
            listed.snapshots.iter().filter(|(d, at)| done.get(*d) == Some(at)).map(|(d, _)| d.clone()).collect()
        };
        loop {
            let mut gaps = Vec::new();
            for (device, ns) in &listed.segments {
                let cursor = self.cursor(device).await?;
                if *device != mine && !ns.contains_key(&(cursor + 1)) && ns.keys().any(|&n| n > cursor + 1) {
                    gaps.push(device.clone());
                }
            }
            if gaps.is_empty() {
                break;
            }
            // The device's own covers what it wrote; another's may cover it too.
            let next = gaps
                .iter()
                .find(|d| listed.snapshots.contains_key(*d) && !read.contains(*d))
                .cloned()
                .or_else(|| listed.snapshots.keys().find(|d| **d != mine && !read.contains(*d)).cloned());
            let Some(next) = next else { break };
            read.insert(next.clone());
            self.read_snapshot(run, &next, &mine).await?;
            self.snapshots_read.lock().unwrap_or_else(|e| e.into_inner()).insert(next.clone(), listed.snapshots[&next]);
        }
        for (device, ns) in &listed.segments {
            if *device == mine {
                continue;
            }
            let mut n = self.cursor(device).await? + 1;
            while let Some(at) = ns.get(&n) {
                if !self.read_segment(run, device, n, *at).await? {
                    break;
                }
                n += 1;
            }
        }
        Ok(())
    }

    async fn read_snapshot(&self, run: &Run<'_>, device: &str, mine: &str) -> Result<()> {
        let name = snapshot_name(device);
        let Some(sealed) = self.files.get_blob(name.clone()).await? else { return Ok(()) };
        let plain = match self.core.open(&sealed).await {
            Ok(plain) => plain,
            Err(Error::Unreadable(e)) => {
                // Read again next time, while the gap it would close is there.
                self.core.host.warn(format!("Sync could not open {name}: {e}"));
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        let Some((ops, doc)) = self.core.parse(&plain, &name)? else { return Ok(()) };
        let mut state = Vec::new();
        for (d, n) in covers_of(&doc) {
            if d != mine && n > self.cursor(&d).await? {
                state.push((format!("{PREFIX}{CURSOR}{d}"), Some(n.to_string())));
            }
        }
        self.core.apply(run, Some(ops), state).await
    }

    /// Whether the read goes on past segment [n] of [device], written [at].
    async fn read_segment(&self, run: &Run<'_>, device: &str, n: i64, at: Option<i64>) -> Result<bool> {
        let name = segment_name(device, n);
        // Removed meanwhile: the next sync reads a snapshot covering it.
        let Some(sealed) = self.files.get_blob(name.clone()).await? else { return Ok(false) };
        let ops = match self.core.open(&sealed).await {
            Ok(plain) => self.core.parse(&plain, &name)?.map(|(ops, _)| ops),
            // Sealed to no key here; anything else (the network, the
            // password) stops the read, to be tried again.
            Err(Error::Unreadable(e)) => {
                if at.is_none_or(|at| now_ms() - at < UNREADABLE_MAX_MS) {
                    self.core.host.warn(format!("Sync waits for a key that opens {name}: {e}"));
                    return Ok(false);
                }
                self.core.host.warn(format!("Sync skipped unreadable {name}: {e}"));
                None
            }
            Err(e) => return Err(e),
        };
        let since = self.core.get_int(SINCE).await? + 1;
        let state = vec![(format!("{PREFIX}{CURSOR}{device}"), Some(n.to_string())), (format!("{PREFIX}{SINCE}"), Some(since.to_string()))];
        self.core.apply(run, ops, state).await?;
        Ok(true)
    }

    async fn push(&self, run: &Run<'_>, listed: &Listing) -> Result<()> {
        let core = &self.core;
        let store = core.get(STORE).await?;
        // Joining a store (the first time, or another one): every record goes,
        // whoever stamped it, so what this device holds reaches the others.
        let joining = core.get(JOINED).await? != store;
        core.host.stamp().await?;
        let sent = core.get_hlc(SENT).await?;
        let all = if joining { core.host.all().await? } else { core.host.pending(sent).await? };
        let carried: Vec<_> = all.iter().filter(|r| run.carries(&r.c)).cloned().collect();
        let (ops, complete) = core.ops_of(&carried).await?;
        // A record that could not be read stops the send just before it.
        let stopped = ops.last().map(|op| op.h);
        let stamped: Vec<_> = if complete { all } else { all.into_iter().filter(|r| stopped.is_some_and(|h| r.h <= h)).collect() };
        let device = core.device().await?;
        let mine = format!("{device:016x}");
        let mut last = sent;
        let mut n = listed.segments.get(&mine).and_then(|ns| ns.keys().max().copied()).unwrap_or(0).max(core.get_int(N).await?);
        for (chunk, body) in core.batches(ops)? {
            for op in &chunk {
                if op.h.device == device && Some(op.h) > last {
                    last = Some(op.h);
                }
            }
            // Kept once written: a write that failed is listed next time if it
            // landed (this device's own files list as written), and its number
            // is passed; else written again under it, leaving no gap.
            n += 1;
            self.files.write(segment_name(&mine, n), body).await?;
            let since = core.get_int(SINCE).await? + 1;
            core.put(vec![(N, Some(n.to_string())), (SENT, Some(last.map(|h| h.to_string()).unwrap_or_default())), (SINCE, Some(since.to_string()))]).await?;
        }
        // Past what was left out too, so it is not looked at again.
        let newest = stamped.iter().map(|r| r.h).filter(|h| h.device == device).fold(last, |a, h| if Some(h) > a { Some(h) } else { a });
        if newest != last {
            core.put(vec![(SENT, Some(newest.map(|h| h.to_string()).unwrap_or_default()))]).await?;
        }
        if joining && complete {
            core.put(vec![(JOINED, store)]).await?;
        }
        Ok(())
    }

    /// Writes this device's snapshot: what it holds, and how far it read.
    async fn write_snapshot(&self, run: &Run<'_>) -> Result<()> {
        let core = &self.core;
        let Some(ops) = core.snapshot_ops(run).await? else {
            core.host.warn("Sync snapshot left: a record could not be read".into());
            return Ok(());
        };
        let mine = self.mine().await?;
        let mut covers = Map::new();
        let at = format!("{PREFIX}{CURSOR}");
        for (k, v) in core.host.state_prefixed(at.clone()).await? {
            if let Ok(n) = v.parse::<i64>() {
                covers.insert(k[at.len()..].to_string(), json!(n));
            }
        }
        let own = core.get_int(N).await?;
        covers.insert(mine.clone(), json!(own));
        let mut extra = Map::new();
        extra.insert("covers".into(), Value::Object(covers));
        self.files.write(snapshot_name(&mine), core.seal.seal(&engine::encode(&ops, extra)?)?).await?;
        core.put(vec![(SINCE, None), (SNAPPED, Some(own.to_string()))]).await?;
        let named: HashSet<String> = ops.iter().filter_map(|op| Core::<H, F, S>::blob_of(&op.d).map(str::to_string)).collect();
        core.sweep_blobs(named).await;
        Ok(())
    }

    /// Removes this device's segments the snapshots cover, all but the last
    /// (what tells a device that read up to it that nothing is missing). Best
    /// effort.
    async fn collect(&self, listed: &Listing) {
        if let Err(e) = self.collect_in(listed).await {
            self.core.host.warn(format!("Sync segments removal: {e}"));
        }
    }

    async fn collect_in(&self, listed: &Listing) -> Result<()> {
        let core = &self.core;
        let mine = self.mine().await?;
        let Some(own) = listed.segments.get(&mine) else { return Ok(()) };
        if (own.len() as i64) < COMPACT_EVERY {
            return Ok(());
        }
        let now = now_ms();
        if now - core.get_int(COLLECTED).await? < COLLECT_EVERY_MS {
            return Ok(());
        }
        core.put(vec![(COLLECTED, Some(now.to_string()))]).await?;
        let snapped = core.get(SNAPPED).await?.and_then(|v| v.parse::<i64>().ok());
        let mut covered: Vec<i64> = snapped.into_iter().collect();
        for device in listed.snapshots.keys() {
            if *device != mine || snapped.is_none() {
                covered.push(self.cover_of(device, &mine).await);
            }
        }
        let (Some(&all), Some(&any)) = (covered.iter().min(), covered.iter().max()) else { return Ok(()) };
        let last = own.keys().max().copied().unwrap_or(0);
        let old = now - SEGMENT_MAX_MS;
        for (&n, &at) in own {
            if n >= last || n > any {
                continue;
            }
            if n <= all || at.is_some_and(|at| at < old) {
                self.files.delete_blob(segment_name(&mine, n)).await?;
            }
        }
        Ok(())
    }

    /// How far [device]'s snapshot covers [of]'s segments; 0 when it cannot
    /// be read.
    async fn cover_of(&self, device: &str, of: &str) -> i64 {
        let name = snapshot_name(device);
        let read = async {
            let Some(sealed) = self.files.get_blob(name.clone()).await? else { return Ok(0) };
            let plain = self.core.open(&sealed).await?;
            Ok::<_, Error>(engine::parse(&plain).map(|(_, doc)| covers_of(&doc).get(of).copied().unwrap_or(0)).unwrap_or(0))
        };
        match read.await {
            Ok(n) => n,
            Err(e) => {
                self.core.host.warn(format!("Sync could not read {name}: {e}"));
                0
            }
        }
    }

    /// Forgets what was read and sent: the next sync reads every device anew
    /// and joins again. For another store, or what is carried changing.
    pub async fn forget(host: &H) -> Result<()> {
        host.clear_state(PREFIX.to_string(), vec![format!("{PREFIX}{STORE}")]).await?;
        host.forget_passed(PREFIX.to_string()).await
    }

    /// The files of [store] from now on: another store's are forgotten.
    pub async fn bind(host: &H, store: &str) -> Result<()> {
        let key = format!("{PREFIX}{STORE}");
        if host.state(vec![key.clone()]).await?.pop().flatten().as_deref() == Some(store) {
            return Ok(());
        }
        Self::forget(host).await?;
        host.set_state(vec![(key, Some(store.to_string()))]).await
    }
}

fn covers_of(doc: &Map<String, Value>) -> BTreeMap<String, i64> {
    match doc.get("covers") {
        Some(Value::Object(m)) => m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_i64()?))).collect(),
        _ => BTreeMap::new(),
    }
}
