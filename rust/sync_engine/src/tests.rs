//! An in-memory host, LK Cloud log, folder, key file and keychain: devices
//! syncing with each other through them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use fl_sync::{Clock, Hlc, Op};
use serde_json::{Value, json};

use crate::key::{BoxFuture, KeyFile, KeyRing, Secrets, SyncKey, Versioned};
use crate::log::{Appended, LogSync, LogTransport, Page, SnapshotBody};
use crate::segment::{Files, SegmentSync};
use crate::{BlobStore, Error, Host, Listed, Read, Result, Seal, Stamped, now_ms};

// The host.

#[derive(Default)]
struct HostState {
    /// `(c, id)` → (stamp, value; `None` deleted).
    records: BTreeMap<(String, String), (Hlc, Option<Value>)>,
    state: BTreeMap<String, String>,
    passed: BTreeMap<(String, String, String), Op>,
    not_carried: HashSet<String>,
    unread: HashSet<(String, String)>,
    /// Collections this build does not keep (a newer one's).
    unkept: HashSet<String>,
    warnings: Vec<String>,
    applied: usize,
}

struct MemHost {
    device: u64,
    clock: Mutex<Clock>,
    s: Mutex<HostState>,
}

impl MemHost {
    fn new(device: u64) -> Arc<Self> {
        Arc::new(Self { device, clock: Mutex::new(Clock::new(device)), s: Mutex::new(HostState::default()) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HostState> {
        self.s.lock().unwrap()
    }

    /// A local edit: stamped by this device.
    fn edit(&self, c: &str, id: &str, d: Option<Value>) {
        let h = self.clock.lock().unwrap().tick(now_ms() as u64);
        self.lock().records.insert((c.into(), id.into()), (h, d));
    }

    fn value(&self, c: &str, id: &str) -> Option<Value> {
        self.lock().records.get(&(c.to_string(), id.to_string())).and_then(|(_, d)| d.clone())
    }

    fn values(&self) -> BTreeMap<(String, String), Value> {
        self.lock().records.iter().filter_map(|(k, (_, d))| Some((k.clone(), d.clone()?))).collect()
    }
}

impl Host for MemHost {
    async fn device(&self) -> Result<u64> {
        Ok(self.device)
    }

    async fn stamp(&self) -> Result<()> {
        Ok(())
    }

    async fn all(&self) -> Result<Vec<Stamped>> {
        let mut all: Vec<_> = self.lock().records.iter().map(|((c, id), (h, _))| Stamped { c: c.clone(), id: id.clone(), h: *h }).collect();
        all.sort_by_key(|r| r.h);
        Ok(all)
    }

    async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
        Ok(self.all().await?.into_iter().filter(|r| r.h.device == self.device && after.is_none_or(|a| r.h > a)).collect())
    }

    async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
        let s = self.lock();
        Ok(ids
            .into_iter()
            .map(|k| {
                if s.unread.contains(&k) {
                    return Read::Unread;
                }
                match s.records.get(&k) {
                    Some((_, Some(v))) => Read::Value(v.clone()),
                    _ => Read::Gone,
                }
            })
            .collect())
    }

    async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
        let mut s = self.lock();
        let (ops, unkept): (Vec<Op>, Vec<Op>) = ops.into_iter().partition(|op| !s.unkept.contains(&op.c));
        let won: Vec<Op> = fl_sync::winners(|c, id| s.records.get(&(c.to_string(), id.to_string())).map(|(h, _)| *h), &ops).into_iter().cloned().collect();
        for op in won {
            self.clock.lock().unwrap().observe(op.h);
            s.records.insert((op.c, op.id), (op.h, op.d));
            s.applied += 1;
        }
        Ok(unkept)
    }

    async fn not_carried(&self) -> Result<HashSet<String>> {
        Ok(self.lock().not_carried.clone())
    }

    async fn after_read(&self, _: HashSet<String>) -> Result<()> {
        Ok(())
    }

    async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
        let s = self.lock();
        Ok(keys.iter().map(|k| s.state.get(k).cloned()).collect())
    }

    async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
        Ok(self.lock().state.iter().filter(|(k, _)| k.starts_with(&prefix)).map(|(k, v)| (k.clone(), v.clone())).collect())
    }

    async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
        let mut s = self.lock();
        for (k, v) in values {
            match v {
                Some(v) => s.state.insert(k, v),
                None => s.state.remove(&k),
            };
        }
        Ok(())
    }

    async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
        self.lock().state.retain(|k, _| !k.starts_with(&prefix) || keep.contains(k));
        Ok(())
    }

    async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
        let mut s = self.lock();
        for op in ops {
            let key = (engine.clone(), op.c.clone(), op.id.clone());
            if s.passed.get(&key).is_none_or(|had| op.h > had.h) {
                s.passed.insert(key, op);
            }
        }
        Ok(())
    }

    async fn passed(&self, engine: String) -> Result<Vec<Op>> {
        Ok(self.lock().passed.iter().filter(|((e, _, _), _)| *e == engine).map(|(_, op)| op.clone()).collect())
    }

    async fn forget_passed(&self, engine: String) -> Result<()> {
        self.lock().passed.retain(|(e, _, _), _| *e != engine);
        Ok(())
    }

    fn warn(&self, message: String) {
        self.lock().warnings.push(message);
    }
}

// LK Cloud's log.

#[derive(Default)]
struct LogState {
    log: String,
    /// `(seq, idempotency key, body)`.
    batches: Vec<(i64, String, Vec<u8>)>,
    /// Batches at or below this are dropped (covered by the snapshot).
    dropped: i64,
    snapshot: Option<(i64, Vec<u8>)>,
    blobs: BTreeMap<String, (Vec<u8>, i64)>,
    /// Batches past the snapshot before `sync_log_full`.
    full_after: Option<usize>,
    compact_after: usize,
}

struct MemLog {
    s: Mutex<LogState>,
    /// Takes the next append but fails to answer it.
    lose_answer: AtomicBool,
    page: usize,
}

impl MemLog {
    fn new() -> Arc<Self> {
        Arc::new(Self { s: Mutex::new(LogState { log: "log-1".into(), compact_after: 1000, ..Default::default() }), lose_answer: AtomicBool::new(false), page: 3 })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, LogState> {
        self.s.lock().unwrap()
    }

    /// Drops what the snapshot covers, as homebase does after a while.
    fn drop_covered(&self) {
        let mut s = self.lock();
        let covered = s.snapshot.as_ref().map_or(0, |(seq, _)| *seq);
        s.batches.retain(|(seq, _, _)| *seq > covered);
        s.dropped = covered;
    }

    fn head(s: &LogState) -> i64 {
        s.batches.last().map_or(s.dropped, |b| b.0)
    }
}

impl BlobStore for MemLog {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.lock().blobs.entry(name).or_insert((body, now_ms()));
        Ok(())
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        Ok(self.lock().blobs.get(&name).map(|(b, _)| b.clone()))
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        Ok(self.lock().blobs.iter().filter(|(n, _)| n.starts_with(&prefix)).map(|(n, (_, at))| Listed { name: n.clone(), at: Some(*at) }).collect())
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.lock().blobs.remove(&name);
        Ok(())
    }
}

impl LogTransport for MemLog {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        let mut s = self.lock();
        if let Some(&(seq, _, _)) = s.batches.iter().find(|(_, k, _)| *k == key) {
            return Ok(Appended { log: s.log.clone(), seq, compact: false });
        }
        let covered = s.snapshot.as_ref().map_or(0, |(seq, _)| *seq);
        let live = s.batches.iter().filter(|(seq, _, _)| *seq > covered).count();
        if s.full_after.is_some_and(|n| live >= n) {
            return Err(Error::LogFull);
        }
        let seq = Self::head(&s) + 1;
        s.batches.push((seq, key, body));
        let compact = live + 1 >= s.compact_after;
        let answer = Appended { log: s.log.clone(), seq, compact };
        drop(s);
        if self.lose_answer.swap(false, Ordering::SeqCst) {
            return Err(Error::Remote("no answer".into()));
        }
        Ok(answer)
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        let s = self.lock();
        if log.as_ref().is_some_and(|l| *l != s.log) || after < s.dropped {
            return Ok(Page::Compacted { log: Some(s.log.clone()) });
        }
        let next: Vec<_> = s.batches.iter().filter(|(seq, _, _)| *seq > after).collect();
        let more = next.len() > self.page;
        Ok(Page::Batches { log: Some(s.log.clone()), batches: next.into_iter().take(self.page).map(|(seq, _, b)| (*seq, b.clone())).collect(), more })
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        let mut s = self.lock();
        if s.snapshot.as_ref().is_some_and(|(at, _)| *at >= seq) {
            return Ok(false);
        }
        s.snapshot = Some((seq, body));
        Ok(true)
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        let s = self.lock();
        Ok(s.snapshot.as_ref().map(|(seq, body)| SnapshotBody { log: s.log.clone(), seq: *seq, body: body.clone() }))
    }
}

// A WebDAV folder.

#[derive(Default)]
struct MemFiles {
    files: Mutex<BTreeMap<String, (Vec<u8>, i64)>>,
}

impl MemFiles {
    fn names(&self) -> Vec<String> {
        self.files.lock().unwrap().keys().cloned().collect()
    }
}

impl BlobStore for MemFiles {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.files.lock().unwrap().insert(name, (body, now_ms()));
        Ok(())
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        Ok(self.files.lock().unwrap().get(&name).map(|(b, _)| b.clone()))
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        Ok(self.files.lock().unwrap().iter().filter(|(n, _)| n.starts_with(&prefix)).map(|(n, (_, at))| Listed { name: n.clone(), at: Some(*at) }).collect())
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.files.lock().unwrap().remove(&name);
        Ok(())
    }
}

impl Files for MemFiles {
    async fn write(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.put_blob(name, body).await
    }
}

// The key file and the keychain.

/// Versions unique across stores, as etags are.
static VERSIONS: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
struct MemKeyFile {
    file: Mutex<Option<(Vec<u8>, String)>>,
    /// A store that does not order writes: one may only not have arrived.
    unordered: bool,
}

struct KeyFileOf(Arc<MemKeyFile>, String);

impl KeyFile for KeyFileOf {
    fn id(&self) -> String {
        self.1.clone()
    }

    fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
        Box::pin(async { Ok(self.0.file.lock().unwrap().clone()) })
    }

    fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async move {
            let mut file = self.0.file.lock().unwrap();
            if file.as_ref().map(|(_, v)| v.clone()) != if_version {
                return Ok(None);
            }
            let version = format!("v{}", VERSIONS.fetch_add(1, Ordering::SeqCst));
            *file = Some((body, version.clone()));
            Ok(Some(version))
        })
    }

    fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
        Box::pin(async { Ok(!self.0.unordered) })
    }
}

#[derive(Default)]
struct MemSecrets {
    password: Mutex<Option<String>>,
    kept: Mutex<HashMap<String, String>>,
    epochs: Mutex<HashMap<String, i64>>,
    pending: Mutex<HashMap<String, String>>,
}

impl MemSecrets {
    fn with(password: &str) -> Arc<Self> {
        let s = Arc::new(Self::default());
        *s.password.lock().unwrap() = Some(password.into());
        s
    }
}

impl Secrets for MemSecrets {
    fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(self.password.lock().unwrap().clone()) })
    }

    fn kept(&self, id: String) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async move { Ok(self.kept.lock().unwrap().get(&id).cloned()) })
    }

    fn set_kept(&self, id: String, identities: String) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            self.kept.lock().unwrap().insert(id, identities);
            Ok(())
        })
    }

    fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
        Box::pin(async { Ok(self.epochs.lock().unwrap().clone()) })
    }

    fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            *self.epochs.lock().unwrap() = epochs;
            Ok(())
        })
    }

    fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
        Box::pin(async { Ok(self.pending.lock().unwrap().clone()) })
    }

    fn set_pending(&self, pending: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            *self.pending.lock().unwrap() = pending;
            Ok(())
        })
    }
}

/// A device: its host, keychain and key.
struct Device {
    host: Arc<MemHost>,
    secrets: Arc<MemSecrets>,
    ring: KeyRing,
}

static NEXT_DEVICE: AtomicU64 = AtomicU64::new(1);

impl Device {
    fn new(password: &str) -> Self {
        let secrets = MemSecrets::with(password);
        Self { host: MemHost::new(NEXT_DEVICE.fetch_add(1, Ordering::SeqCst)), secrets: secrets.clone(), ring: KeyRing::new(secrets, "Test sync key") }
    }

    async fn key(&self, file: &Arc<MemKeyFile>) -> Result<Arc<SyncKey>> {
        self.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), true).await
    }

    async fn log(&self, log: &Arc<MemLog>, file: &Arc<MemKeyFile>) -> LogSync<MemHost, MemLog, SyncKey> {
        LogSync::new(self.host.clone(), log.clone(), self.key(file).await.unwrap())
    }

    async fn segments(&self, files: &Arc<MemFiles>, file: &Arc<MemKeyFile>) -> SegmentSync<MemHost, MemFiles, SyncKey> {
        SegmentSync::new(self.host.clone(), files.clone(), self.key(file).await.unwrap())
    }
}

// The log.

#[tokio::test]
async fn devices_converge_on_the_log() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    a.host.edit("kv:setting", "theme", Some(json!("dark")));
    a.host.edit("server", "s1", Some(json!({"name": "one"})));
    b.host.edit("kv:setting", "font", Some(json!(14)));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
    assert_eq!(b.host.value("server", "s1"), Some(json!({"name": "one"})));
    assert_eq!(a.host.value("kv:setting", "font"), Some(json!(14)));
}

#[tokio::test]
async fn a_delete_goes_through_and_a_later_edit_wins() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    a.host.edit("server", "s1", Some(json!(1)));
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("server", "s1"), Some(json!(1)));
    a.host.edit("server", "s1", None);
    la.sync().await.unwrap();
    // Made after the delete: it stays, and goes to a.
    b.host.edit("server", "s1", Some(json!(2)));
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.value("server", "s1"), Some(json!(2)));
    assert_eq!(b.host.value("server", "s1"), Some(json!(2)));
}

#[tokio::test]
async fn an_older_op_does_not_overwrite_an_edit_here() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    a.host.edit("k", "x", Some(json!("a")));
    b.host.edit("k", "x", Some(json!("b")));
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.value("k", "x"), Some(json!("b")));
    assert_eq!(b.host.value("k", "x"), Some(json!("b")));
}

#[tokio::test]
async fn a_large_record_goes_as_a_blob() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let big = "x".repeat(200 << 10);
    a.host.edit("chat", "c1/u1", Some(json!({"text": big})));
    a.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(log.lock().blobs.len(), 1);
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("chat", "c1/u1"), Some(json!({"text": big})));
}

#[tokio::test]
async fn many_records_split_into_batches_under_the_limit() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    // Random, so gzip leaves them their size: 60 KiB each, inline.
    for i in 0..20 {
        let mut noise = vec![0u8; 30 << 10];
        getrandom::fill(&mut noise).unwrap();
        let text: String = noise.iter().map(|b| format!("{b:02x}")).collect();
        a.host.edit("k", &format!("r{i}"), Some(json!(text)));
    }
    a.log(&log, &file).await.sync().await.unwrap();
    let batches = log.lock().batches.clone();
    assert!(batches.len() > 1);
    assert!(batches.iter().all(|(_, _, b)| b.len() <= crate::engine::BATCH_MAX));
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_device_joins_from_the_snapshot() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    for i in 0..4 {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        la.sync().await.unwrap();
    }
    assert!(log.lock().snapshot.is_some());
    log.drop_covered();
    let b = Device::new("pw");
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_full_log_is_compacted_then_sent() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().full_after = Some(2);
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    for i in 0..5 {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        la.sync().await.unwrap();
    }
    assert!(log.lock().snapshot.is_some());
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn an_unanswered_batch_is_sent_again_once() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    // Joined first (a log known): joining sends every record again.
    a.host.edit("k", "w", Some(json!(0)));
    la.sync().await.unwrap();
    a.host.edit("k", "x", Some(json!(1)));
    log.lose_answer.store(true, Ordering::SeqCst);
    assert!(la.sync().await.is_err());
    la.sync().await.unwrap();
    assert_eq!(log.lock().batches.len(), 2);
}

#[tokio::test]
async fn a_newer_batch_stops_the_read_but_not_the_send() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let key = a.key(&file).await.unwrap();
    let la = a.log(&log, &file).await;
    la.sync().await.unwrap();
    // A build after this one's.
    let newer = crate::engine::gzip(br#"{"v":3,"ops":[]}"#).unwrap();
    log.append("k".repeat(16), key.seal(&newer).unwrap()).await.unwrap();
    let lb = b.log(&log, &file).await;
    b.host.edit("k", "x", Some(json!(1)));
    assert!(matches!(lb.sync().await, Err(Error::TooNew(_))));
    assert!(*lb.too_new().borrow());
    // Sent all the same, after the batch this build does not read.
    assert_eq!(log.lock().batches.len(), 2);
}

#[tokio::test]
async fn an_unreadable_batch_is_passed_over() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    log.append("j".repeat(16), b"not age".to_vec()).await.unwrap();
    a.host.edit("k", "x", Some(json!(1)));
    la.sync().await.unwrap();
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("k", "x"), Some(json!(1)));
    assert!(b.host.lock().warnings.iter().any(|w| w.contains("unreadable batch 1")));
}

#[tokio::test]
async fn what_is_not_carried_here_is_kept_for_the_others() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let (a, b, c) = (Device::new("pw"), Device::new("pw"), Device::new("pw"));
    a.host.edit("kv:setting", "theme", Some(json!("dark")));
    a.log(&log, &file).await.sync().await.unwrap();
    // b does not sync settings, and writes the snapshot.
    b.host.lock().not_carried.insert("kv:setting".into());
    let lb = b.log(&log, &file).await;
    for i in 0..3 {
        b.host.edit("k", &format!("r{i}"), Some(json!(i)));
        lb.sync().await.unwrap();
    }
    assert_eq!(b.host.value("kv:setting", "theme"), None);
    log.drop_covered();
    c.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(c.host.value("kv:setting", "theme"), Some(json!("dark")));
}

#[tokio::test]
async fn what_this_build_does_not_keep_stays_in_the_log() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let (a, b, c) = (Device::new("pw"), Device::new("pw"), Device::new("pw"));
    a.host.edit("new:kind", "x", Some(json!(1)));
    a.log(&log, &file).await.sync().await.unwrap();
    // b is an older build: it writes the snapshot, and keeps a's record in it.
    b.host.lock().unkept.insert("new:kind".into());
    let lb = b.log(&log, &file).await;
    for i in 0..3 {
        b.host.edit("k", &format!("r{i}"), Some(json!(i)));
        lb.sync().await.unwrap();
    }
    assert_eq!(b.host.value("new:kind", "x"), None);
    log.drop_covered();
    c.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(c.host.value("new:kind", "x"), Some(json!(1)));
}

#[tokio::test]
async fn a_record_that_cannot_be_read_holds_the_send_back() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    a.host.edit("k", "1", Some(json!(1)));
    a.host.edit("k", "2", Some(json!(2)));
    a.host.lock().unread.insert(("k".into(), "2".into()));
    la.sync().await.unwrap();
    let lb = b.log(&log, &file).await;
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("k", "1"), Some(json!(1)));
    assert_eq!(b.host.value("k", "2"), None);
    a.host.lock().unread.clear();
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("k", "2"), Some(json!(2)));
}

#[tokio::test]
async fn a_rotated_key_reaches_a_device_that_holds_only_it() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    a.host.edit("k", "x", Some(json!(1)));
    la.sync().await.unwrap();
    let key = a.key(&file).await.unwrap();
    la.rotate(async { key.rotate().await }).await.unwrap();
    log.drop_covered();
    // b first meets the key now: only the newest would open the snapshot.
    let b = Device::new("pw");
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("k", "x"), Some(json!(1)));
}

#[tokio::test]
async fn another_account_is_read_anew() {
    let host = MemHost::new(99);
    host.set_state(vec![("log.cursor".into(), Some("5".into()))]).await.unwrap();
    LogSync::<MemHost, MemLog, SyncKey>::bind(&host, "a").await.unwrap();
    assert_eq!(host.state(vec!["log.cursor".into()]).await.unwrap(), vec![None]);
    host.set_state(vec![("log.cursor".into(), Some("5".into()))]).await.unwrap();
    LogSync::<MemHost, MemLog, SyncKey>::bind(&host, "a").await.unwrap();
    assert_eq!(host.state(vec!["log.cursor".into()]).await.unwrap(), vec![Some("5".into())]);
}

// The segments.

#[tokio::test]
async fn devices_converge_on_segments() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    a.host.edit("k", "a", Some(json!(1)));
    b.host.edit("k", "b", Some(json!(2)));
    let (sa, sb) = (a.segments(&files, &file).await, b.segments(&files, &file).await);
    sa.sync().await.unwrap();
    sb.sync().await.unwrap();
    sa.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
    assert!(files.names().iter().any(|n| n.starts_with("seg-")));
}

#[tokio::test]
async fn a_gap_is_read_from_a_snapshot_and_covered_segments_go() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*a.host, "dav").await.unwrap();
    let sa = a.segments(&files, &file).await;
    for i in 0..(crate::segment::COMPACT_EVERY + 2) {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        sa.sync().await.unwrap();
    }
    let mine = format!("{:016x}", a.host.device);
    assert!(files.names().contains(&format!("snap-{mine}.age")));
    // Segments the snapshot covers, gone: b reads them from it.
    let first = format!("seg-{mine}-1.age");
    files.delete_blob(first).await.unwrap();
    let b = Device::new("pw");
    SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*b.host, "dav").await.unwrap();
    b.segments(&files, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_blob_that_has_not_arrived_is_waited_for() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    let big = "y".repeat(200 << 10);
    a.host.edit("font", "f1", Some(json!(big)));
    a.segments(&files, &file).await.sync().await.unwrap();
    // The folder has the segment, not yet the blob it names.
    let blob = files.names().into_iter().find(|n| n.starts_with("op-")).unwrap();
    let held = files.files.lock().unwrap().remove(&blob).unwrap();
    let sb = b.segments(&files, &file).await;
    sb.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), None);
    files.files.lock().unwrap().insert(blob, held);
    sb.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), Some(json!(big)));
}

#[tokio::test]
async fn a_blob_its_device_removed_is_not_waited_for() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    let sa = a.segments(&files, &file).await;
    a.host.edit("font", "f1", Some(json!("x".repeat(200 << 10))));
    sa.sync().await.unwrap();
    // Replaced, and a's snapshot written past it: the old blob goes.
    a.host.edit("font", "f1", Some(json!("new")));
    for i in 0..crate::segment::COMPACT_EVERY {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        sa.sync().await.unwrap();
    }
    let blob = files.names().into_iter().find(|n| n.starts_with("op-")).unwrap();
    files.delete_blob(blob).await.unwrap();
    b.segments(&files, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), Some(json!("new")));
    assert_eq!(a.host.values(), b.host.values());
}

// The key.

#[tokio::test]
async fn the_key_opens_on_another_device_with_the_password() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let ka = a.key(&file).await.unwrap();
    let kb = b.key(&file).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"hi").unwrap()).unwrap(), b"hi");
    let (sealed, _) = file.file.lock().unwrap().clone().unwrap();
    assert!(String::from_utf8_lossy(&sealed).starts_with("-----BEGIN AGE ENCRYPTED FILE-----"));
    let plain = crate::key::open_with_password(&sealed, "pw").unwrap().unwrap();
    assert!(String::from_utf8(plain).unwrap().starts_with("# Test sync key, epoch 0\nAGE-SECRET-KEY-1"));
}

#[tokio::test]
async fn another_password_syncs_nothing() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("other"));
    a.key(&file).await.unwrap();
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));
    assert!(b.ring.mismatch().borrow().contains("account"));
}

#[tokio::test]
async fn a_changed_password_seals_the_file_again() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("old"), Device::new("old"));
    let ka = a.key(&file).await.unwrap();
    b.key(&file).await.unwrap();
    a.ring.password_changed(Some("old".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("new".into());
    ka.check(true, true).await.unwrap();
    let (sealed, _) = file.file.lock().unwrap().clone().unwrap();
    let plain = String::from_utf8(crate::key::open_with_password(&sealed, "new").unwrap().unwrap()).unwrap();
    assert!(plain.starts_with("# Test sync key, epoch 1\n"));
    // b, still on the old one, is told; with the new one it opens the same key.
    let kb = b.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), true).await.unwrap();
    assert!(matches!(kb.check(true, true).await, Err(Error::PasswordMismatch(_))));
    *b.secrets.password.lock().unwrap() = Some("new".into());
    kb.check(true, true).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"x").unwrap()).unwrap(), b"x");
}

#[tokio::test]
async fn keys_made_at_once_on_an_unordered_store_are_merged() {
    // Two folders as two devices saw one before the other's write arrived.
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let ka = a.key(&file).await.unwrap();
    let sealed_by_a = ka.seal(b"from a").unwrap();
    // b made its own elsewhere first.
    let other = Arc::new(MemKeyFile::default());
    let kb = b.ring.of(Arc::new(KeyFileOf(other, "account".into())), true).await.unwrap();
    let sealed_by_b = kb.seal(b"from b").unwrap();
    // Then b meets a's file: it puts its key in beside a's.
    let kb = b.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), true).await.unwrap();
    kb.check(true, true).await.unwrap();
    assert_eq!(kb.open(&sealed_by_a).unwrap(), b"from a");
    assert!(ka.refresh().await.unwrap());
    assert_eq!(ka.open(&sealed_by_b).unwrap(), b"from b");
}

#[tokio::test]
async fn none_is_made_where_one_may_only_not_have_arrived() {
    let file = Arc::new(MemKeyFile { unordered: true, ..Default::default() });
    let a = Device::new("pw");
    assert!(matches!(a.key(&file).await, Err(Error::KeyNotHere(_))));
}

#[test]
fn a_key_sealed_file_is_told_from_a_password_sealed_one() {
    assert!(crate::key::sealed_to_key(b"age-encryption.org/v1\n-> X25519 abc"));
    assert!(!crate::key::sealed_to_key(b"age-encryption.org/v1\n-> scrypt abc"));
}

#[test]
fn rfc3339_reads_as_unix_ms() {
    assert_eq!(crate::lkc::rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(crate::lkc::rfc3339_ms("2026-11-10T08:00:00.5Z"), Some(1_794_297_600_500));
    assert_eq!(crate::lkc::rfc3339_ms("2026-11-10T16:00:00.500+08:00"), Some(1_794_297_600_500));
    assert_eq!(crate::lkc::rfc3339_ms("yesterday"), None);
}

#[test]
fn a_batch_reads_back_and_a_bad_one_is_unreadable() {
    let ops = vec![Op { c: "k".into(), id: "x".into(), h: Hlc { ms: 1, counter: 0, device: 2 }, d: Some(json!({"a": [1, 2]})) }];
    let (back, _) = crate::engine::parse(&crate::engine::encode(&ops, Default::default()).unwrap()).unwrap();
    assert_eq!(back, ops);
    assert!(matches!(crate::engine::parse(&crate::engine::gzip(br#"{"v":0,"ops":[]}"#).unwrap()), Err(Error::Unreadable(_))));
    assert!(matches!(crate::engine::parse(b"plain"), Err(Error::Unreadable(_))));
}

// What the Dart engine wrote reads here: the batch shape as `jsonEncode`
// wrote it, keys in its order.
#[test]
fn a_dart_batch_reads() {
    let json = br#"{"v":2,"ops":[{"c":"kv:setting","id":"theme","h":"0192f3a1b2c30000000000000000002a","d":"dark"},{"c":"server","id":"s1","h":"0192f3a1b2c30001000000000000002a","d":null}]}"#;
    let (ops, _) = crate::engine::parse(&crate::engine::gzip(json).unwrap()).unwrap();
    assert_eq!(ops.len(), 2);
    assert_eq!(ops[0].d, Some(json!("dark")));
    assert_eq!(ops[1].d, None);
    assert_eq!(ops[1].h.device, 42);
}
