//! An in-memory host, LK Cloud log, folder, key file and keychain: devices
//! syncing with each other through them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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
    /// Takes the next append and fails local watermark persistence while returning the committed result.
    fail_persist_append: AtomicBool,
    append_calls: AtomicU64,
    page: usize,
}

impl MemLog {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            s: Mutex::new(LogState { log: "log-1".into(), compact_after: 1000, ..Default::default() }),
            lose_answer: AtomicBool::new(false),
            fail_persist_append: AtomicBool::new(false),
            append_calls: AtomicU64::new(0),
            page: 3,
        })
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
        self.append_calls.fetch_add(1, Ordering::SeqCst);
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
        if self.fail_persist_append.swap(false, Ordering::SeqCst) {
            return Err(Error::AppendPersistFailed { appended: answer, detail: "watermark save failed".into() });
        }
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
    reads: AtomicUsize,
    /// A store that does not order writes: one may only not have arrived.
    unordered: bool,
}

struct KeyFileOf(Arc<MemKeyFile>, String);

impl KeyFile for KeyFileOf {
    fn id(&self) -> String {
        self.1.clone()
    }

    fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
        self.0.reads.fetch_add(1, Ordering::SeqCst);
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
    secret_key: Mutex<Option<String>>,
    pending_secret_key: Mutex<Option<String>>,
    allow_auto_gen: AtomicBool,
    fail_set_secret_key: AtomicBool,
    fail_set_epochs: AtomicBool,
    epochs_delay_ms: AtomicU64,
    kept: Mutex<HashMap<String, String>>,
    epochs: Mutex<HashMap<String, i64>>,
    pending: Mutex<HashMap<String, String>>,
}

impl MemSecrets {
    fn with(password: &str) -> Arc<Self> {
        static SHARED_KEY: std::sync::LazyLock<String> =
            std::sync::LazyLock::new(|| fl_lkc::secret_key::SecretKey::generate().format().to_string());
        let s = Arc::new(Self { allow_auto_gen: AtomicBool::new(true), ..Default::default() });
        *s.password.lock().unwrap() = Some(password.into());
        *s.secret_key.lock().unwrap() = Some(SHARED_KEY.clone());
        s
    }
}

impl Secrets for MemSecrets {
    fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(self.password.lock().unwrap().clone()) })
    }

    fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(self.secret_key.lock().unwrap().clone()) })
    }

    fn set_secret_key(&self, key: String) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            if self.fail_set_secret_key.load(Ordering::SeqCst) {
                return Err(Error::Host("keychain locked".into()));
            }
            *self.secret_key.lock().unwrap() = Some(key);
            Ok(())
        })
    }

    fn pending_secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(self.pending_secret_key.lock().unwrap().clone()) })
    }

    fn set_pending_secret_key(&self, key: Option<String>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            *self.pending_secret_key.lock().unwrap() = key;
            Ok(())
        })
    }

    fn allow_auto_generate_secret_key(&self) -> BoxFuture<'_, Result<bool>> {
        Box::pin(async { Ok(self.allow_auto_gen.load(Ordering::SeqCst)) })
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
        Box::pin(async {
            let snapshot = self.epochs.lock().unwrap().clone();
            let delay = self.epochs_delay_ms.load(Ordering::SeqCst);
            if delay > 0 {
                tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
            }
            tokio::task::yield_now().await;
            Ok(snapshot)
        })
    }

    fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            if self.fail_set_epochs.load(Ordering::SeqCst) {
                return Err(Error::Host("prefs full".into()));
            }
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

/// Whether saved personal versions record a signed snapshot of `serverbox`.
fn snapshot_signed(versions: &Value) -> bool {
    versions["signed_snapshots"].as_array().is_some_and(|apps| apps.iter().any(|a| a == "serverbox"))
}

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
    // Bare password alone must not open the two-factor sealed key file.
    assert!(crate::key::open_with_password(&sealed, "pw").unwrap().is_none());
    let sk = fl_lkc::secret_key::SecretKey::parse(a.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let plain = crate::key::open_with_password(&sealed, &sk.combine_passphrase("pw")).unwrap().unwrap();
    assert!(String::from_utf8(plain.to_vec()).unwrap().starts_with("# Test sync key, epoch 0\nAGE-SECRET-KEY-1"));
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
    assert!(crate::key::open_with_password(&sealed, "new").unwrap().is_none());
    let sk = fl_lkc::secret_key::SecretKey::parse(a.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let plain = String::from_utf8(crate::key::open_with_password(&sealed, &sk.combine_passphrase("new")).unwrap().unwrap().to_vec()).unwrap();
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

#[tokio::test]
async fn secret_key_protects_key_file_and_migrates_legacy() {
    let file = Arc::new(MemKeyFile::default());
    // Device A starts without a secret key: one is generated and saved.
    let a = Device::new("weak123");
    *a.secrets.secret_key.lock().unwrap() = None;
    let ka = a.key(&file).await.unwrap();
    let generated = a.secrets.secret_key.lock().unwrap().clone().expect("secret key generated");
    assert!(generated.starts_with("S1-"));
    // The uploaded identity.age cannot be opened with the bare password alone.
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, "weak123").unwrap().is_none());

    // Device B has the password but no secret key: gets SecretKeyMissing.
    let b = Device::new("weak123");
    *b.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));

    // Device B imports the wrong secret key: gets PasswordMismatch.
    *b.secrets.secret_key.lock().unwrap() = Some(fl_lkc::secret_key::SecretKey::generate().format().to_string());
    b.ring.recheck().await;
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));

    // Device B imports Device A's secret key: opens the key and decrypts A's data.
    *b.secrets.secret_key.lock().unwrap() = Some(generated);
    b.ring.recheck().await;
    let kb = b.key(&file).await.unwrap();
    let sealed = ka.seal(b"ssh private key").unwrap();
    assert_eq!(kb.open(&sealed).unwrap(), b"ssh private key");

    // Legacy single-factor identity.age is opened and transparently upgraded.
    let legacy_file = Arc::new(MemKeyFile::default());
    let old_id = age::x25519::Identity::generate();
    let old_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 0\n{}", old_id.to_string().expose_secret())
    };
    *legacy_file.file.lock().unwrap() = Some((crate::key::seal_with_password(old_text.as_bytes(), "legacy-pw").unwrap(), "v1".into()));

    let c = Device::new("legacy-pw");
    *c.secrets.secret_key.lock().unwrap() = None;
    let kc = c.key(&legacy_file).await.unwrap();
    assert!(c.secrets.secret_key.lock().unwrap().is_some());
    // The remote key file is now re-sealed under two-factor (bare password fails).
    let upgraded = legacy_file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&upgraded, "legacy-pw").unwrap().is_none());
    let cipher = kc.seal(b"after upgrade").unwrap();
    assert_eq!(kc.open(&cipher).unwrap(), b"after upgrade");
}

#[tokio::test]
async fn secret_key_missing_stays_distinct_across_cache_and_recheck_and_blocks_bare_takeover() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("weak123");
    let ka = a.key(&file).await.unwrap();
    let sk_a = a.secrets.secret_key.lock().unwrap().clone().unwrap();

    // Device B has no secret key: first check AND cached second check both
    // report SecretKeyMissing (never PasswordMismatch), and recheck keeps it.
    let b = Device::new("weak123");
    *b.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));
    assert!(b.ring.mismatch().borrow().is_empty());
    assert!(b.ring.secret_key_missing().borrow().contains("account"));
    // Second check within 60s cache window must STILL be SecretKeyMissing.
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));
    b.ring.recheck().await;
    assert!(b.ring.mismatch().borrow().is_empty());
    assert!(b.ring.secret_key_missing().borrow().contains("account"));

    // Attacker guesses weak123 and injects a bare-password identity.age
    // containing an attacker X25519 key onto a remote that Device A already
    // opened with 2FA: Device A must refuse the bare-password downgrade!
    let attacker_id = age::x25519::Identity::generate();
    let attacker_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 99\n{}", attacker_id.to_string().expose_secret())
    };
    *file.file.lock().unwrap() = Some((crate::key::seal_with_password(attacker_text.as_bytes(), "weak123").unwrap(), "v-evil".into()));
    assert!(matches!(ka.check(true, true).await, Err(Error::PasswordMismatch(_))));
    // Remote file must NOT be re-sealed with attacker's key.
    let still = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&still, &fl_lkc::secret_key::SecretKey::parse(&sk_a).unwrap().combine_passphrase("weak123")).unwrap().is_none());

    // Pending password is preserved while secret key is missing, and completes
    // once the secret key is supplied.
    let file2 = Arc::new(MemKeyFile::default());
    let c = Device::new("old-pw");
    let _kc = c.key(&file2).await.unwrap();
    let sk_c = c.secrets.secret_key.lock().unwrap().clone().unwrap();
    c.ring.password_changed(Some("old-pw".into())).await.unwrap();
    *c.secrets.password.lock().unwrap() = Some("new-pw".into());
    *c.secrets.secret_key.lock().unwrap() = None;
    c.ring.recheck().await;
    assert_eq!(c.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("old-pw"));
    *c.secrets.secret_key.lock().unwrap() = Some(sk_c);
    c.ring.recheck().await;
    assert!(c.secrets.pending.lock().unwrap().is_empty());
    assert!(c.ring.mismatch().borrow().is_empty());
    assert!(c.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn disabling_auto_generate_pauses_legacy_upgrade_without_flagging_2fa_missing() {
    // 1. Empty remote with auto-generate disabled: no file created, no key generated.
    let empty_file = Arc::new(MemKeyFile::default());
    let d1 = Device::new("pw");
    *d1.secrets.secret_key.lock().unwrap() = None;
    d1.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(d1.key(&empty_file).await, Err(Error::SecretKeyMissing)));
    assert!(empty_file.file.lock().unwrap().is_none());
    assert!(d1.secrets.secret_key.lock().unwrap().is_none());
    assert!(d1.ring.secret_key_missing().borrow().is_empty());

    // 2. Legacy 1FA remote with auto-generate disabled: remote stays untouched,
    // secret_key_missing stays empty (not yet 2FA).
    let legacy_file = Arc::new(MemKeyFile::default());
    let old_id = age::x25519::Identity::generate();
    let old_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 0\n{}", old_id.to_string().expose_secret())
    };
    let legacy_bytes = crate::key::seal_with_password(old_text.as_bytes(), "legacy-pw").unwrap();
    *legacy_file.file.lock().unwrap() = Some((legacy_bytes.clone(), "v1".into()));

    let a = Device::new("legacy-pw");
    *a.secrets.secret_key.lock().unwrap() = None;
    a.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(a.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert_eq!(legacy_file.file.lock().unwrap().as_ref().unwrap().0, legacy_bytes);
    assert!(a.secrets.secret_key.lock().unwrap().is_none());
    assert!(a.ring.secret_key_missing().borrow().is_empty());
    // Checks meanwhile wait for one instead of reading the file again.
    let reads = legacy_file.reads.load(Ordering::SeqCst);
    assert!(matches!(a.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert_eq!(legacy_file.reads.load(Ordering::SeqCst), reads);

    // Once user explicitly stores a key, Device A upgrades the legacy remote cleanly.
    let chosen = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    *a.secrets.secret_key.lock().unwrap() = Some(chosen.clone());
    let ka = a.key(&legacy_file).await.unwrap();
    let upgraded = legacy_file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&upgraded, "legacy-pw").unwrap().is_none());

    // 3. Device B with auto-generate disabled probes the already-2FA remote:
    // MUST mark secret_key_missing so UI switches to import-only.
    let b = Device::new("legacy-pw");
    *b.secrets.secret_key.lock().unwrap() = None;
    b.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(b.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert!(b.ring.secret_key_missing().borrow().contains("account"));

    // Importing Device A's key unlocks immediately.
    *b.secrets.secret_key.lock().unwrap() = Some(chosen);
    b.ring.recheck().await;
    let kb = b.key(&legacy_file).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn opened_at_does_not_cache_when_epoch_persistence_fails() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    d.secrets.fail_set_epochs.store(true, Ordering::SeqCst);
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert!(d.secrets.epochs.lock().unwrap().is_empty());

    // Once epoch persistence succeeds, retrying MUST persist the 2FA marker and epoch.
    d.secrets.fail_set_epochs.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("2fa:account"), Some(&1));
    assert_eq!(k.open(&k.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn concurrent_epoch_updates_and_secret_key_init_across_remotes_are_serialized() {
    let file_a = Arc::new(MemKeyFile::default());
    let file_b = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.epochs_delay_ms.store(25, Ordering::SeqCst);

    let (ka, kb) = tokio::join!(
        d.ring.of(Arc::new(KeyFileOf(file_a.clone(), "remote-a".into())), true),
        d.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true),
    );
    let (ka, kb) = (ka.unwrap(), kb.unwrap());
    let stored = d.secrets.secret_key.lock().unwrap().clone().expect("secret key stored");
    let sk = fl_lkc::secret_key::SecretKey::parse(&stored).unwrap();

    // Both remotes must be openable with the ONE stored secret key.
    let raw_a = file_a.file.lock().unwrap().clone().unwrap().0;
    let raw_b = file_b.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_a, &sk.combine_passphrase("pw")).unwrap().is_some());
    assert!(crate::key::open_with_password(&raw_b, &sk.combine_passphrase("pw")).unwrap().is_some());

    // Both remotes' epochs & 2fa markers must be preserved (no lost update).
    let epochs = d.secrets.epochs.lock().unwrap();
    assert_eq!(epochs.get("remote-a"), Some(&0));
    assert_eq!(epochs.get("2fa:remote-a"), Some(&1));
    assert_eq!(epochs.get("remote-b"), Some(&0));
    assert_eq!(epochs.get("2fa:remote-b"), Some(&1));
    assert_eq!(ka.open(&ka.seal(b"a").unwrap()).unwrap(), b"a");
    assert_eq!(kb.open(&kb.seal(b"b").unwrap()).unwrap(), b"b");
}

#[tokio::test]
async fn candidate_secret_key_is_recovered_after_set_secret_key_failure() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);

    // Remote write commits, then `set_secret_key` fails: candidate key must stay staged.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert!(file.file.lock().unwrap().is_some());
    assert!(d.secrets.secret_key.lock().unwrap().is_none());
    let staged = d.secrets.pending_secret_key.lock().unwrap().clone().expect("candidate staged");

    // Once keychain recovers, retry opens the remote with the staged candidate,
    // persists it to `secret_key`, and clears the staging slot.
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert_eq!(k.open(&k.seal(b"recovered").unwrap()).unwrap(), b"recovered");
}

#[tokio::test]
async fn default_set_pending_secret_key_rejects_some_and_allows_none() {
    struct BareSecrets;
    impl Secrets for BareSecrets {
        fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn set_secret_key(&self, _: String) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn kept(&self, _: String) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn set_kept(&self, _: String, _: String) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
            Box::pin(async { Ok(HashMap::new()) })
        }
        fn set_epochs(&self, _: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
            Box::pin(async { Ok(HashMap::new()) })
        }
        fn set_pending(&self, _: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
    }

    let s = BareSecrets;
    assert!(s.set_pending_secret_key(None).await.is_ok());
    assert!(matches!(s.set_pending_secret_key(Some("SK-123".into())).await, Err(Error::Host(_))));
}

#[tokio::test]
async fn open_rechecks_active_secret_key_before_refusing_as_missing() {
    // A remote already sealed with a secret key; `secret_key()` returns None on
    // the first call and Some(sk) on the recheck before refusal.
    let file = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw");
    let kw = writer.key(&file).await.unwrap();
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();

    struct LateKeySecrets {
        inner: Arc<MemSecrets>,
        sk: String,
        reads: AtomicU64,
    }
    impl Secrets for LateKeySecrets {
        fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.password()
        }
        fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            let n = self.reads.fetch_add(1, Ordering::SeqCst);
            let sk = if n == 0 { None } else { Some(self.sk.clone()) };
            Box::pin(async move { Ok(sk) })
        }
        fn set_secret_key(&self, key: String) -> BoxFuture<'_, Result<()>> {
            self.inner.set_secret_key(key)
        }
        fn pending_secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.pending_secret_key()
        }
        fn set_pending_secret_key(&self, key: Option<String>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_pending_secret_key(key)
        }
        fn kept(&self, id: String) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.kept(id)
        }
        fn set_kept(&self, id: String, identities: String) -> BoxFuture<'_, Result<()>> {
            self.inner.set_kept(id, identities)
        }
        fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
            self.inner.epochs()
        }
        fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_epochs(epochs)
        }
        fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
            self.inner.pending()
        }
        fn set_pending(&self, pending: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_pending(pending)
        }
    }

    let inner = MemSecrets::with("pw");
    *inner.secret_key.lock().unwrap() = None;
    let ring = KeyRing::new(Arc::new(LateKeySecrets { inner, sk, reads: AtomicU64::new(0) }), "Test sync key");
    let kr = ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), false).await.unwrap();
    assert!(ring.secret_key_missing().borrow().is_empty());
    assert_eq!(kr.open(&kw.seal(b"late-key").unwrap()).unwrap(), b"late-key");
}

#[tokio::test]
async fn staged_secret_key_recovers_pending_password_change_even_when_upgraded_2fa() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("old-pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);

    // Remote write commits under ("old-pw", staged), then set_secret_key fails.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    let staged = d.secrets.pending_secret_key.lock().unwrap().clone().expect("candidate staged");
    let staged_sk = fl_lkc::secret_key::SecretKey::parse(&staged).unwrap();

    // Simulate upgraded_2fa already recorded + password changed from "old-pw" to "new-pw".
    d.secrets.epochs.lock().unwrap().insert("2fa:account".into(), 1);
    *d.secrets.password.lock().unwrap() = Some("new-pw".into());
    d.ring.password_changed(Some("old-pw".into())).await.unwrap();

    // While set_secret_key still fails, reseal writes under ("new-pw", staged),
    // clears stale "old-pw" from pending, updates epoch, and retains staged.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert_eq!(d.secrets.pending_secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending.lock().unwrap().get("account").is_none());

    // A second password change ("new-pw" -> "third-pw") while set_secret_key
    // previously failed MUST record "new-pw" (matching the committed file),
    // never retaining stale "old-pw".
    *d.secrets.password.lock().unwrap() = Some("third-pw".into());
    d.ring.password_changed(Some("new-pw".into())).await.unwrap();
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("new-pw"));

    // Once keychain recovers, retry opens with ("new-pw", staged), reseals to
    // ("third-pw", staged) using the same staged key (no new key generated).
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &staged_sk.combine_passphrase("third-pw")).unwrap().is_some());
    assert_eq!(k.open(&k.seal(b"resealed").unwrap()).unwrap(), b"resealed");
}

#[tokio::test]
async fn log_append_persist_failure_advances_checkpoint_without_resending() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Create 20 records with ~40 KiB incompressible hex payloads each (< 64 KiB
    // INLINE_MAX, ~400 KiB compressed > 250 KiB BATCH_MAX) so first join splits
    // into 2 batches.
    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key.clone());
    log.fail_persist_append.store(true, Ordering::SeqCst);
    // First-join batch 1 commits remotely (seq 1), local watermark save fails -> Host error.
    let err = sync.sync().await.unwrap_err();
    assert!(matches!(err, Error::Host(_)));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert_eq!(log.lock().batches.len(), 1);
    assert!(d.host.state(vec!["log.join_sent".into()]).await.unwrap()[0].is_some(), "non-final first-join batch must record join_sent");

    // Next sync MUST NOT resend committed batch 1; it appends only uncommitted batch 2.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    // Subsequent idle sync sends nothing (join complete).
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    // Steady-state append with local watermark save failure also advances checkpoint without resending.
    d.host.edit("servers", "steady", Some(json!({ "name": "box2" })));
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 3);
    assert_eq!(log.lock().batches.len(), 3);

    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 3);
    assert_eq!(log.lock().batches.len(), 3);

    // A second device sees all 21 committed records cleanly.
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    let sync2 = LogSync::new(d2.host.clone(), log.clone(), k2);
    sync2.sync().await.unwrap();
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn same_hlc_first_join_batches_do_not_drop_records_on_partial_failure() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Seed 20 adopted/legacy records sharing the exact same Hlc::ZERO so first
    // join splits them across 2 batches with identical HLCs.
    let zero = Hlc::ZERO;
    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.lock().records.insert(("servers".into(), format!("s{i:02}")), (zero, Some(json!({ "blob": payload }))));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);

    // Next sync resumes strictly after `(h, c, id)` of batch 1's last record,
    // sending all remaining Hlc::ZERO records in batch 2 without dropping any.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values().len(), 20);
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn recreated_log_does_not_mark_joined_from_stale_unanswered_batch() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i:02}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    // Batch 1 commits on log-1; simulate batch 2 failing with a lost answer
    // after batch 1 commits by first failing persist on batch 1, then losing
    // the answer on batch 2.
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.lock().batches.len(), 1);

    log.lose_answer.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Remote(_))));

    // Server recreates the log as "log-2" (empty).
    {
        let mut s = log.lock();
        s.log = "log-2".into();
        s.batches.clear();
        s.dropped = 0;
        s.snapshot = None;
    }

    // Next sync pulls Compacted(log-2), retries unanswered batch 2 on log-2,
    // MUST NOT mark log-2 as JOINED from batch 2 alone, and sends all records
    // (including batch 1's) onto log-2.
    sync.sync().await.unwrap();
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values().len(), 20);
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn concurrent_password_change_during_key_write_is_not_clobbered() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // Wrap key file so during write("pw2"), a concurrent password change
    // "pw2" -> "pw3" occurs before write returns.
    struct RaceWriteKeyFile {
        inner: Arc<MemKeyFile>,
        secrets: Arc<MemSecrets>,
        ring: KeyRing,
        fired: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for RaceWriteKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                let next = {
                    let mut f = self.inner.file.lock().unwrap();
                    if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                        return Ok(None);
                    }
                    let next = format!("vr{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                    *f = Some((body, next.clone()));
                    next
                };
                if !self.fired.swap(true, Ordering::SeqCst) {
                    *self.secrets.password.lock().unwrap() = Some("pw3".into());
                    self.ring.password_changed(Some("pw2".into())).await?;
                }
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    // First password change: pw1 -> pw2, triggering concurrent pw2 -> pw3 mid-write.
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    let raced = Arc::new(RaceWriteKeyFile {
        inner: file.clone(),
        secrets: d.secrets.clone(),
        ring: d.ring.clone(),
        fired: AtomicBool::new(false),
        next: AtomicU64::new(0),
    });
    let kb = d.ring.of(raced, true).await.unwrap();
    kb.check(true, true).await.unwrap();

    // Remote file MUST end up sealed under "pw3" without PasswordMismatch.
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());
    assert_eq!(kb.open(&ka.seal(b"concurrent-ok").unwrap()).unwrap(), b"concurrent-ok");
}

#[tokio::test]
async fn snapshot_persist_failure_retries_without_resending_and_sweeps_blobs() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct SnapshotTestKeeper {
        saved: Mutex<String>,
        fail_snapshot: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for SnapshotTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            let has_snap = serde_json::from_str::<Value>(&json).ok().is_some_and(|v| snapshot_signed(&v));
            if self.fail_snapshot.load(Ordering::SeqCst) && has_snap {
                return Box::pin(async { Err("snapshot watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    let snapshot_puts = Arc::new(AtomicU64::new(0));
    let deleted_blobs = Arc::new(Mutex::new(Vec::<String>::new()));
    let head = Arc::new(AtomicU64::new(0));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let snap_puts_srv = snapshot_puts.clone();
    let deleted_srv = deleted_blobs.clone();
    let head_srv = head.clone();
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let header_end = loop {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(pos + 4);
                }
            };
            let Some(header_end) = header_end else { continue };
            let head_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let first_line = head_str.lines().next().unwrap_or("");
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("");
            let full_path = parts.next().unwrap_or("");
            let path = full_path.split('?').next().unwrap_or(full_path);
            let content_len: usize = head_str
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok()).flatten()
                })
                .unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }

            let (status, extra_headers, body) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n",
                    json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } }).to_string(),
                ),
                ("GET", "/v2/sync/serverbox/log") => (
                    "200 OK",
                    "Content-Type: application/json\r\n",
                    json!({ "code": 0, "data": { "log": "6f1c", "batches": [], "head": head_srv.load(Ordering::SeqCst), "snapshot_seq": 0, "more": false } }).to_string(),
                ),
                ("POST", "/v2/sync/serverbox/log") => {
                    let seq = head_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n",
                        json!({ "code": 0, "data": { "log": "6f1c", "seq": seq, "live": { "batches": seq, "bytes": 4 }, "compact": true } }).to_string(),
                    )
                }
                ("PUT", "/v2/sync/serverbox/snapshot") => {
                    snap_puts_srv.fetch_add(1, Ordering::SeqCst);
                    ("204 No Content", "ETag: \"snap-e1\"\r\n", String::new())
                }
                ("GET", "/v2/sync/serverbox") => (
                    "200 OK",
                    "Content-Type: application/json\r\n",
                    json!({ "data": [{ "name": "op-old-dead.age", "etag": "b1", "size": 10, "updated_at": "2020-01-01T00:00:00Z" }] }).to_string(),
                ),
                ("DELETE", p) if p.starts_with("/v2/sync/serverbox/") => {
                    deleted_srv.lock().unwrap().push(p.trim_start_matches("/v2/sync/serverbox/").to_string());
                    ("204 No Content", "", String::new())
                }
                _ => ("404 Not Found", "", String::new()),
            };
            let resp = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(resp.as_bytes()).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let transport = Arc::new(crate::lkc::LkcLog(sync_client));
    let log_sync = LogSync::new(d.host.clone(), transport, key);

    // 1. Append commits seq 1 (compact=true) -> snapshot PUT commits remotely,
    //    then `record_snapshot_written` fails -> surfaces Host error, blobs NOT swept yet.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);
    assert!(deleted_blobs.lock().unwrap().is_empty());
    let before_retry: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert!(!snapshot_signed(&before_retry));

    // 2. While keeper STILL fails, retrying sync MUST preserve `Error::Host`
    //    (not misclassify as `Error::Remote`) and MUST NOT resend PUT /snapshot.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);
    assert!(deleted_blobs.lock().unwrap().is_empty());

    // 3. Keeper recovers -> next sync flushes `record_snapshot_written` WITHOUT
    //    resending PUT /snapshot, records snapshot seq, and sweeps the obsolete blob.
    keeper.fail_snapshot.store(false, Ordering::SeqCst);
    log_sync.sync().await.unwrap();
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1, "committed snapshot must not be resent");
    let saved_json = keeper.saved.lock().unwrap().clone();
    let parsed: Value = serde_json::from_str(&saved_json).unwrap();
    assert!(snapshot_signed(&parsed));
    assert_eq!(*deleted_blobs.lock().unwrap(), vec!["op-old-dead.age".to_string()]);

    server.abort();
}

#[tokio::test]
async fn password_changed_notification_before_password_update_during_key_write() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // During write("pw2"), caller notifies `password_changed(Some("pw2"))` BEFORE
    // updating `secrets.password` from "pw2" to "pw3" (the documented order).
    struct NotifyBeforeUpdateKeyFile {
        inner: Arc<MemKeyFile>,
        ring: KeyRing,
        fired: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for NotifyBeforeUpdateKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                let next = {
                    let mut f = self.inner.file.lock().unwrap();
                    if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                        return Ok(None);
                    }
                    let next = format!("vn{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                    *f = Some((body, next.clone()));
                    next
                };
                if !self.fired.swap(true, Ordering::SeqCst) {
                    // Notice: `secrets.password` is STILL "pw2" here!
                    self.ring.password_changed(Some("pw2".into())).await?;
                }
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    // Start pw1 -> pw2 reseal; mid-write `password_changed("pw2")` fires while
    // `secrets.password` is still "pw2".
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    let raced = Arc::new(NotifyBeforeUpdateKeyFile {
        inner: file.clone(),
        ring: d.ring.clone(),
        fired: AtomicBool::new(false),
        next: AtomicU64::new(0),
    });
    let kb = d.ring.of(raced, true).await.unwrap();
    kb.check(true, true).await.unwrap();
    // "pw2" MUST still be retained in `pending` because its notification is outstanding!
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("pw2"));

    // Now the caller finishes updating stored password to "pw3" and rechecks.
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    kb.check(true, true).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());
    assert_eq!(kb.open(&ka.seal(b"notify-before-update").unwrap()).unwrap(), b"notify-before-update");
}

#[tokio::test]
async fn write_intent_recovers_committed_reseal_when_set_epochs_fails_and_ignores_lost_cas() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // 1. Start pw1 -> pw2 reseal while `set_epochs` fails: remote commits "pw2"
    //    at epoch 1, then `set_epoch_2fa` fails -> write intent MUST stay durable.
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    d.secrets.fail_set_epochs.store(true, Ordering::SeqCst);
    assert!(matches!(ka.check(true, true).await, Err(Error::Host(_))));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:account"));

    // 2. Second password change pw2 -> pw3 while epochs still at 0 and pending still "pw1",
    //    then prefs recover. Inject a transient network failure on the first write
    //    attempt during WriteIntent recovery: the confirmed `(epoch=1, "pw2")` MUST
    //    already be persisted so retrying still succeeds without PasswordMismatch.
    struct FailOnceKeyFile {
        inner: Arc<MemKeyFile>,
        fail_next: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for FailOnceKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if self.fail_next.swap(false, Ordering::SeqCst) {
                    return Err(Error::Remote("transient drop before server".into()));
                }
                let mut f = self.inner.file.lock().unwrap();
                if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                    return Ok(None);
                }
                let next = format!("vw{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                *f = Some((body, next.clone()));
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    d.ring.password_changed(Some("pw2".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    d.secrets.fail_set_epochs.store(false, Ordering::SeqCst);
    let flaky = Arc::new(FailOnceKeyFile {
        inner: file.clone(),
        fail_next: AtomicBool::new(true),
        next: AtomicU64::new(0),
    });
    assert!(matches!(d.ring.of(flaky.clone(), true).await, Err(Error::Remote(_))));
    // Confirmed `(epoch=1, "pw2")` was already persisted before the failed new write.
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("pw2"));

    d.ring.of(flaky, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2));
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());

    // 3. Real lost CAS (`Ok(None)`) MUST clear the write intent and NOT treat the lost
    //    attempt as a committed reseal (another device's write winning the CAS triggers mismatch).
    let other = Device::new("pw3");
    let k_other = other.key(&file).await.unwrap();
    struct LostCasKeyFile {
        inner: Arc<MemKeyFile>,
        other_secrets: Arc<MemSecrets>,
        other_ring: KeyRing,
        other_key: Arc<crate::key::SyncKey>,
        raced: AtomicBool,
    }
    impl KeyFile for LostCasKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, _body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if !self.raced.swap(true, Ordering::SeqCst) {
                    // Right as `d` attempts its CAS write (after staging `intent:account`),
                    // `other` wins the race by resealing `file` to "other-pw" at epoch 3.
                    self.other_ring.password_changed(Some("pw3".into())).await?;
                    *self.other_secrets.password.lock().unwrap() = Some("other-pw".into());
                    self.other_key.check(true, true).await?;
                }
                Ok(None)
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let lost_cas = Arc::new(LostCasKeyFile {
        inner: file.clone(),
        other_secrets: other.secrets.clone(),
        other_ring: other.ring.clone(),
        other_key: k_other,
        raced: AtomicBool::new(false),
    });
    // Attach `lost_cas` to the existing key slot, then force a check for pw3 -> pw4.
    let ka = d.ring.of(lost_cas.clone(), true).await.unwrap();
    d.ring.password_changed(Some("pw3".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw4".into());
    assert!(matches!(ka.check(true, true).await, Err(Error::PasswordMismatch(_))));
    assert!(lost_cas.raced.load(Ordering::SeqCst), "must have entered KeyFile::write and lost CAS");
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2), "lost CAS must not advance epoch");
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:account"));
    assert!(ka.open(&ka.seal(b"still-valid").unwrap()).unwrap() == b"still-valid");
}

#[tokio::test]
async fn snapshot_recovery_defers_sweep_when_new_batches_follow_pending_seq() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct SnapshotTestKeeper {
        saved: Mutex<String>,
        fail_snapshot: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for SnapshotTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            let has_snap = serde_json::from_str::<Value>(&json).ok().is_some_and(|v| snapshot_signed(&v));
            if self.fail_snapshot.load(Ordering::SeqCst) && has_snap {
                return Box::pin(async { Err("snapshot watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    let auth_for_sign = Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key.clone(),
        fl_lkc::personal::PersonalVersions::default(),
        Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(false) }),
    ));

    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Prepare a remote batch seq 2 from another device referencing a >64 KiB
    // blob (named with Keyed naming so Device A's fresh snapshot at seq 2 keeps
    // referencing the exact same blob name) that was NOT in seq-1's snapshot.
    let mut b_clock = fl_sync::Clock::new(2);
    let b_hlc = b_clock.tick(now_ms() as u64);
    let live_blob_name = format!("op-{}.age", key.name_of(b_hlc.to_string().as_bytes()));
    let b_val = json!({ "big": "z".repeat(70 << 10) });
    let b_op = Op { c: "servers".into(), id: "from_b".into(), h: b_hlc, d: Some(json!({ "$blob": live_blob_name })) };
    let b_body = key.seal(&crate::engine::encode(&[b_op], serde_json::Map::new()).unwrap()).unwrap();
    let b_blob_plain = {
        use std::io::Write;
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(serde_json::to_vec(&b_val).unwrap().as_slice()).unwrap();
        enc.finish().unwrap()
    };
    let b_blob_sealed = key.seal(&b_blob_plain).unwrap();
    let b_idem = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let b_sig = auth_for_sign.sign_batch("serverbox", b_idem, &b_body).await;
    let b_digest = blake3::hash(&b_body).to_hex().to_string();
    let b_body_b64 = {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for c in b_body.chunks(3) {
            let n = ((c[0] as u32) << 16) | ((*c.get(1).unwrap_or(&0) as u32) << 8) | (*c.get(2).unwrap_or(&0) as u32);
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push(if c.len() > 1 { T[((n >> 6) & 63) as usize] as char } else { '=' });
            out.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
        }
        out
    };

    let snapshot_puts = Arc::new(AtomicU64::new(0));
    let deleted_blobs = Arc::new(Mutex::new(Vec::<String>::new()));
    let head = Arc::new(AtomicU64::new(0));
    let serve_seq2 = Arc::new(AtomicBool::new(false));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let snap_puts_srv = snapshot_puts.clone();
    let deleted_srv = deleted_blobs.clone();
    let head_srv = head.clone();
    let serve_seq2_srv = serve_seq2.clone();
    let pub_key_srv = pub_key.clone();
    let rec_srv = recipient.clone();
    let b_sig_str = b_sig.signature.clone();
    let live_blob_srv = live_blob_name.clone();
    let live_blob_path = format!("/v2/sync/serverbox/{live_blob_name}");
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let header_end = loop {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(pos + 4);
                }
            };
            let Some(header_end) = header_end else { continue };
            let head_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let first_line = head_str.lines().next().unwrap_or("");
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("");
            let full_path = parts.next().unwrap_or("");
            let (path, query) = full_path.split_once('?').unwrap_or((full_path, ""));
            let content_len: usize = head_str
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok()).flatten()
                })
                .unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }

            let after: i64 = query.split('&').find_map(|kv| kv.strip_prefix("after=")?.parse().ok()).unwrap_or(0);
            let (status, extra_headers, body_bytes): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pub_key_srv, "next_seq": 2, "prev_signing_key": pub_key_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/log") => {
                    let batches = if serve_seq2_srv.load(Ordering::SeqCst) && after < 2 {
                        vec![json!({
                            "seq": 2,
                            "body": b_body_b64,
                            "digest": b_digest,
                            "idempotency_key": b_idem,
                            "signer": "u1",
                            "signing_key": pub_key_srv,
                            "signature": b_sig_str,
                        })]
                    } else {
                        vec![]
                    };
                    let cur_head = if serve_seq2_srv.load(Ordering::SeqCst) { 2 } else { head_srv.load(Ordering::SeqCst) };
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "batches": batches, "head": cur_head, "snapshot_seq": 0, "more": false } })
                            .to_string()
                            .into_bytes(),
                    )
                }
                ("POST", "/v2/sync/serverbox/log") => {
                    let seq = head_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "seq": seq, "live": { "batches": seq, "bytes": 4 }, "compact": true } })
                            .to_string()
                            .into_bytes(),
                    )
                }
                ("PUT", "/v2/sync/serverbox/snapshot") => {
                    let n = snap_puts_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    ("204 No Content", format!("ETag: \"snap-e{n}\"\r\n"), Vec::new())
                }
                ("GET", "/v2/sync/serverbox") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": [
                        { "name": live_blob_srv, "etag": "b-live", "size": b_blob_sealed.len(), "updated_at": "2020-01-01T00:00:00Z" },
                        { "name": "op-truly-dead.age", "etag": "b-dead", "size": 10, "updated_at": "2020-01-01T00:00:00Z" }
                    ] })
                    .to_string()
                    .into_bytes(),
                ),
                ("GET", p) if p == live_blob_path => {
                    ("200 OK", "ETag: \"b-live\"\r\n".into(), b_blob_sealed.clone())
                }
                ("PUT", p) if p == live_blob_path => {
                    ("412 Precondition Failed", String::new(), Vec::new())
                }
                ("DELETE", p) if p.starts_with("/v2/sync/serverbox/") => {
                    deleted_srv.lock().unwrap().push(p.trim_start_matches("/v2/sync/serverbox/").to_string());
                    ("204 No Content", String::new(), Vec::new())
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body_bytes.len()
            );
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&body_bytes).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));
    let transport = Arc::new(crate::lkc::LkcLog(sync_client));
    let log_sync = LogSync::new(d.host.clone(), transport, key);

    // 1. Snapshot at seq 1 commits remotely, local save fails -> deferred.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);

    // 2. Meanwhile batch seq 2 arrives referencing `op-reused-live.age` (even with old timestamp).
    serve_seq2.store(true, Ordering::SeqCst);
    keeper.fail_snapshot.store(false, Ordering::SeqCst);

    // 3. Recovery sync: flushes seq 1 without resending seq-1 snapshot, reads seq 2,
    //    defers stale sweep, writes fresh snapshot at seq 2 (PUT #2), and sweeps ONLY
    //    `op-truly-dead.age` (NEVER deleting `op-reused-live.age`!).
    log_sync.sync().await.unwrap();
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 2);
    assert_eq!(d.host.value("servers", "from_b"), Some(b_val));
    let deleted = deleted_blobs.lock().unwrap().clone();
    assert_eq!(deleted, vec!["op-truly-dead.age".to_string()]);

    server.abort();
}

#[tokio::test]
async fn lkc_key_file_persist_failure_reconciles_and_retries_without_resending_put() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct KeyFileTestKeeper {
        saved: Mutex<String>,
        fail: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for KeyFileTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            if self.fail.load(Ordering::SeqCst) {
                return Box::pin(async { Err("key file watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    type StoredKeyFile = (Vec<u8>, String, String, String);
    let stored_file: Arc<Mutex<Option<StoredKeyFile>>> = Arc::new(Mutex::new(None));
    let puts = Arc::new(AtomicU64::new(0));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let file_srv = stored_file.clone();
    let puts_srv = puts.clone();
    let pub_srv = pub_key.clone();
    let rec_srv = recipient.clone();
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let header_end = loop {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(pos + 4);
                }
            };
            let Some(header_end) = header_end else { continue };
            let head_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let first_line = head_str.lines().next().unwrap_or("");
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("");
            let path = parts.next().unwrap_or("").split('?').next().unwrap_or("");
            let hdr = |name: &str| {
                head_str.lines().find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
                })
            };
            let content_len: usize = hdr("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }
            let body = buf[header_end..header_end + content_len].to_vec();

            let (status, extra_headers, resp_body): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pub_srv, "next_seq": 2, "prev_signing_key": pub_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/identity.age") => {
                    let guard = file_srv.lock().unwrap();
                    match guard.as_ref() {
                        Some((bytes, etag, ver, sig)) => (
                            "200 OK",
                            format!(
                                "ETag: \"{etag}\"\r\nX-Signer: u1\r\nX-Signing-Key: {pub_srv}\r\nX-Signature: {sig}\r\nX-Sync-Version: {ver}\r\n"
                            ),
                            bytes.clone(),
                        ),
                        None => ("404 Not Found", String::new(), Vec::new()),
                    }
                }
                ("PUT", "/v2/sync/serverbox/identity.age") => {
                    let n = puts_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    let mut guard = file_srv.lock().unwrap();
                    let ok = if hdr("if-none-match").as_deref() == Some("*") {
                        guard.is_none()
                    } else if let Some(im) = hdr("if-match") {
                        guard.as_ref().is_some_and(|(_, e, _, _)| format!("\"{e}\"") == im)
                    } else {
                        true
                    };
                    if !ok {
                        ("412 Precondition Failed", String::new(), Vec::new())
                    } else {
                        let etag = format!("kf-e{n}");
                        let ver = hdr("x-sync-version").unwrap_or_else(|| "1".into());
                        let sig = hdr("x-signature").unwrap_or_default();
                        *guard = Some((body, etag.clone(), ver, sig));
                        ("204 No Content", format!("ETag: \"{etag}\"\r\n"), Vec::new())
                    }
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                resp_body.len()
            );
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&resp_body).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(KeyFileTestKeeper { saved: Mutex::new(String::new()), fail: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    let kf = Arc::new(crate::lkc::LkcKeyFile { client: sync_client, account: "u1".into() });
    let d = Device::new("pw1");

    // 1. Create identity.age: remote PUT commits, local signing watermark fails ->
    //    surfaces Host error, reconciles local epoch=0 + 2fa marker immediately.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 1);
    assert_eq!(d.secrets.epochs.lock().unwrap().get("u1"), Some(&0));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("2fa:u1"), Some(&1));
    assert!(keeper.saved.lock().unwrap().is_empty());

    // 2. Retrying while keeper still fails MUST NOT resend PUT.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 1);

    // 3. Keeper recovers -> retry flushes local watermark WITHOUT resending PUT
    //    and opens the key cleanly.
    keeper.fail.store(false, Ordering::SeqCst);
    let key = d.ring.of(kf.clone(), true).await.unwrap();
    assert_eq!(puts.load(Ordering::SeqCst), 1, "committed key-file PUT must not be resent");
    let saved: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(saved["files"]["serverbox/identity.age"], json!(1));
    assert_eq!(key.open(&key.seal(b"kf-ok").unwrap()).unwrap(), b"kf-ok");

    // 4. `rotate()` hitting `KeyFilePersistFailed` clears `opened`/`checked_at` so an
    //    immediate non-forced `check(false, true)` flushes the watermark WITHOUT
    //    being bypassed by the 60s cache and WITHOUT resending PUT.
    keeper.fail.store(true, Ordering::SeqCst);
    assert!(matches!(key.rotate().await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 2);
    assert!(matches!(key.check(false, true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 2);
    keeper.fail.store(false, Ordering::SeqCst);
    key.check(false, true).await.unwrap();
    assert_eq!(puts.load(Ordering::SeqCst), 2, "rotate retry must not resend PUT");
    let saved2: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(saved2["files"]["serverbox/identity.age"], json!(2));

    server.abort();
}

#[tokio::test]
async fn a_key_file_sealed_with_a_secret_key_is_told_without_writing() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    let none = Device::new("pw");
    *none.secrets.secret_key.lock().unwrap() = None;
    let probe = || Arc::new(KeyFileOf(file.clone(), "account".into())) as Arc<dyn KeyFile>;
    assert!(!none.ring.sealed_with_secret_key(probe()).await.unwrap());

    a.key(&file).await.unwrap();
    let before = file.file.lock().unwrap().clone();
    assert!(none.ring.sealed_with_secret_key(probe()).await.unwrap());
    assert!(none.ring.secret_key_missing().borrow().contains("account"));
    assert_eq!(*file.file.lock().unwrap(), before);
    assert!(none.secrets.secret_key.lock().unwrap().is_none());

    // Asked again once a key is stored.
    none.ring.recheck().await;
    assert!(none.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn two_factor_key_file_rejects_epoch_rollback_and_allows_equal_or_newer() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw1");
    let sk = a.secrets.secret_key.lock().unwrap().clone().unwrap();
    let ka = a.key(&file).await.unwrap();

    // Advance epoch from 0 -> 1 via password change, then save epoch 0 snapshot.
    let epoch0_body = file.file.lock().unwrap().clone().unwrap().0;
    a.ring.password_changed(Some("pw1".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("pw2".into());
    ka.check(true, true).await.unwrap();
    assert_eq!(a.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // Change back to pw1 (epoch 2) so epoch0_body opens with current (pw1, sk)
    // but carries stale epoch 0 < recorded floor 2.
    a.ring.password_changed(Some("pw2".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("pw1".into());
    ka.check(true, true).await.unwrap();
    assert_eq!(a.secrets.epochs.lock().unwrap().get("account"), Some(&2));
    let epoch2_body = file.file.lock().unwrap().clone().unwrap().0;

    // Server replays epoch 0 file -> MUST be rejected as Untrusted.
    *file.file.lock().unwrap() = Some((epoch0_body, "v-rollback".into()));
    let err = ka.check(true, true).await.unwrap_err();
    assert!(matches!(err, Error::Untrusted(_)), "expected Untrusted, got {err:?}");

    // Equal epoch (epoch 2) from another device merges cleanly.
    let b = Device::new("pw1");
    *b.secrets.secret_key.lock().unwrap() = Some(sk);
    *file.file.lock().unwrap() = Some((epoch2_body, "v-equal".into()));
    b.key(&file).await.unwrap();
    ka.check(true, true).await.unwrap();
}

#[tokio::test]
async fn stale_probe_cannot_mark_missing_after_successful_open() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    let sk = a.secrets.secret_key.lock().unwrap().clone().unwrap();
    a.key(&file).await.unwrap();

    // Device starts without secret key; probe starts reading while another task
    // imports the secret key and opens the key file before the probe returns.
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = None;

    let read_started = Arc::new(tokio::sync::Notify::new());
    let release_read = Arc::new(tokio::sync::Notify::new());
    struct SlowProbeFile {
        inner: Arc<MemKeyFile>,
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowProbeFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(false) })
        }
    }

    let probe_ring = b.ring.clone();
    let probe_file = Arc::new(SlowProbeFile {
        inner: file.clone(),
        started: read_started.clone(),
        release: release_read.clone(),
    });
    let probe = tokio::spawn(async move { probe_ring.sealed_with_secret_key(probe_file).await.unwrap() });
    read_started.notified().await;

    // Import secret key and open successfully while probe is in flight.
    b.ring.store_secret_key(&sk).await.unwrap();
    b.key(&file).await.unwrap();
    assert!(b.ring.secret_key_missing().borrow().is_empty());

    release_read.notify_one();
    assert!(probe.await.unwrap());
    // Stale probe must NOT mark the opened key missing again.
    assert!(b.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn restore_retains_pending_write_after_legacy_upgrade_persist_failure() {
    let inner = Arc::new(MemKeyFile::default());
    // Seed a legacy passphrase-only key file (epoch 0).
    let legacy_id = {
        use age::secrecy::ExposeSecret;
        age::x25519::Identity::generate().to_string().expose_secret().to_string()
    };
    let legacy_body = crate::key::seal_with_password(format!("# test, epoch 0\n{legacy_id}").as_bytes(), "pw").unwrap();
    *inner.file.lock().unwrap() = Some((legacy_body, "v1".into()));

    struct FailFirstPersistKeyFile {
        inner: Arc<MemKeyFile>,
        writes: AtomicUsize,
        fail_persist: AtomicBool,
        committed_body: Mutex<Option<(Vec<u8>, Option<String>, String)>>,
    }
    impl KeyFile for FailFirstPersistKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                // Retry of already-committed body flushes local state without re-writing remote.
                if let Some((ref prev_body, ref prev_if, ref ver)) = *self.committed_body.lock().unwrap()
                    && prev_body == &body
                    && prev_if == &if_version
                {
                    if self.fail_persist.load(Ordering::SeqCst) {
                        return Err(Error::KeyFilePersistFailed { version: ver.clone(), detail: "still failing".into() });
                    }
                    return Ok(Some(ver.clone()));
                }
                self.writes.fetch_add(1, Ordering::SeqCst);
                let mut f = self.inner.file.lock().unwrap();
                if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                    return Ok(None);
                }
                let ver = "v2".to_string();
                *f = Some((body.clone(), ver.clone()));
                *self.committed_body.lock().unwrap() = Some((body, if_version, ver.clone()));
                if self.fail_persist.load(Ordering::SeqCst) {
                    return Err(Error::KeyFilePersistFailed { version: ver, detail: "watermark save failed".into() });
                }
                Ok(Some(ver))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let kf = Arc::new(FailFirstPersistKeyFile {
        inner: inner.clone(),
        writes: AtomicUsize::new(0),
        fail_persist: AtomicBool::new(true),
        committed_body: Mutex::new(None),
    });
    let d = Device::new("pw");

    // Restore (`create = false`) upgrades legacy file; PUT commits, local save fails.
    assert!(matches!(d.ring.of(kf.clone(), false).await, Err(Error::Host(_))));
    assert_eq!(kf.writes.load(Ordering::SeqCst), 1);

    // Local save recovers; next restore retries flush without resending PUT.
    kf.fail_persist.store(false, Ordering::SeqCst);
    let key = d.ring.of(kf.clone(), false).await.unwrap();
    assert_eq!(kf.writes.load(Ordering::SeqCst), 1);
    assert_eq!(key.open(&key.seal(b"restored").unwrap()).unwrap(), b"restored");
}

#[tokio::test]
async fn rotate_uses_verified_credential_across_concurrent_password_change() {
    let inner = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let key = d.key(&inner).await.unwrap();

    // Mutate the stored password immediately after `check_locked` validates the
    // remote version under `pw1` and BEFORE `rotate` seals the rotated file.
    let ring = d.ring.clone();
    let secrets = d.secrets.clone();
    key.rotate_after_check(move || {
        Box::pin(async move {
            ring.password_changed(Some("pw1".into())).await?;
            *secrets.password.lock().unwrap() = Some("pw2".into());
            Ok(())
        })
    })
    .await
    .unwrap();

    // Rotate sealed with pw1 (matching epoch 0 and pending["account"] = "pw1").
    let raw_after_rotate = inner.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_after_rotate, &sk.combine_passphrase("pw1")).unwrap().is_some());

    // Subsequent check migrates cleanly from pw1 -> pw2 at epoch 1, preserving the rotated key.
    let sealed_with_rotated = key.seal(b"after-rotate").unwrap();
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw_after_migrate = inner.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_after_migrate, &sk.combine_passphrase("pw2")).unwrap().is_some());
    assert_eq!(key.open(&sealed_with_rotated).unwrap(), b"after-rotate");
}

#[tokio::test]
async fn store_secret_key_rejects_conflicting_import_after_staged_commit() {
    let inner = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    // Simulate a remote write that committed staged key A, then failed
    // `set_secret_key` (leaving A staged + 2fa marker written).
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);
    assert!(d.key(&inner).await.is_err());
    let staged_a = d.secrets.pending_secret_key.lock().unwrap().clone().expect("staged key A must remain");
    assert!(d.secrets.secret_key.lock().unwrap().is_none());

    // Conflicting import B must be rejected and must NOT clear or replace staged key A.
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let key_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    assert!(d.ring.store_secret_key(&key_b).await.is_err());
    assert!(d.secrets.secret_key.lock().unwrap().is_none());
    assert_eq!(d.secrets.pending_secret_key.lock().unwrap().as_deref(), Some(staged_a.as_str()));

    // Recovery still promotes staged key A cleanly.
    let recovered = d.key(&inner).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged_a.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert_eq!(recovered.open(&recovered.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn join_retry_landing_on_new_log_does_not_mark_new_log_joined() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i:02}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    // Batch 1 commits on log-1; fail persist so join stops with join_sent recorded on log-1.
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(d.host.state(vec!["log.log".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert!(d.host.state(vec!["log.join_sent".into()]).await.unwrap()[0].is_some());

    // Transport wrapper: `read` still reports log-1 (no 410 yet), while the next
    // `append` (batch 2, selected from log-1's join_sent) lands on a newly
    // created log-2.
    struct SwitchOnAppendLog {
        inner: Arc<MemLog>,
        switched: AtomicBool,
    }
    impl BlobStore for SwitchOnAppendLog {
        async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
            self.inner.put_blob(name, body).await
        }
        async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
            self.inner.get_blob(name).await
        }
        async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
            self.inner.blobs(prefix).await
        }
        async fn delete_blob(&self, name: String) -> Result<()> {
            self.inner.delete_blob(name).await
        }
    }
    impl LogTransport for SwitchOnAppendLog {
        async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
            if self.switched.swap(false, Ordering::SeqCst) {
                let mut s = self.inner.lock();
                s.log = "log-2".into();
                s.batches.clear();
                s.dropped = 0;
                s.snapshot = None;
            }
            self.inner.append(key, body).await
        }
        async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
            self.inner.read(after, log).await
        }
        async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
            self.inner.put_snapshot(seq, body).await
        }
        async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
            self.inner.snapshot().await
        }
    }

    let switching = Arc::new(SwitchOnAppendLog { inner: log.clone(), switched: AtomicBool::new(true) });
    let sync_switch = LogSync::new(d.host.clone(), switching, d.key(&file).await.unwrap());
    // Sync sends batch 2 (which lands on log-2). log-2 MUST NOT be marked JOINED!
    sync_switch.sync().await.unwrap();
    assert_ne!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-2"));

    // Next sync discovers log-2 and completes a full join onto log-2 so another device sees all 20 records.
    sync_switch.sync().await.unwrap();
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-2"));
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn append_checkpoint_put_failure_retries_without_resending_batch() {
    struct FailOncePutHost {
        inner: Arc<MemHost>,
        fail_next_put: AtomicBool,
    }
    impl Host for FailOncePutHost {
        async fn device(&self) -> Result<u64> {
            self.inner.device().await
        }
        async fn stamp(&self) -> Result<()> {
            self.inner.stamp().await
        }
        async fn all(&self) -> Result<Vec<Stamped>> {
            self.inner.all().await
        }
        async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
            self.inner.pending(after).await
        }
        async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
            self.inner.read(ids).await
        }
        async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
            self.inner.apply(ops).await
        }
        async fn not_carried(&self) -> Result<HashSet<String>> {
            self.inner.not_carried().await
        }
        async fn after_read(&self, nc: HashSet<String>) -> Result<()> {
            self.inner.after_read(nc).await
        }
        async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
            self.inner.state(keys).await
        }
        async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
            self.inner.state_prefixed(prefix).await
        }
        async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
            if self.fail_next_put.swap(false, Ordering::SeqCst) {
                return Err(Error::Host("sqlite busy".into()));
            }
            self.inner.set_state(values).await
        }
        async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
            self.inner.clear_state(prefix, keep).await
        }
        async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
            self.inner.pass(engine, ops).await
        }
        async fn passed(&self, engine: String) -> Result<Vec<Op>> {
            self.inner.passed(engine).await
        }
        async fn forget_passed(&self, engine: String) -> Result<()> {
            self.inner.forget_passed(engine).await
        }
        fn warn(&self, message: String) {
            self.inner.warn(message);
        }
    }

    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let host = Arc::new(FailOncePutHost { inner: d.host.clone(), fail_next_put: AtomicBool::new(true) });
    let sync = LogSync::new(host, log.clone(), key);
    log.fail_persist_append.store(true, Ordering::SeqCst);

    // Remote append commits (AppendPersistFailed) AND local core.put(state) fails.
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].is_none());

    // Retry applies the retained checkpoint WITHOUT calling transport.append again,
    // advancing local state cleanly.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1, "retained checkpoint must be applied without resending batch");
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert_eq!(d.host.state(vec!["log.cursor".into()]).await.unwrap()[0].as_deref(), Some("1"));
}

#[tokio::test]
async fn external_commit_staging_validates_candidate_and_tracks_concurrent_writes() {
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let stale = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    // No active or staged key yet: staging a stale candidate MUST be rejected.
    assert!(d.ring.stage_external_secret_key_commit(&stale).await.is_err());

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    assert!(d.ring.stage_external_secret_key_commit(&stale).await.is_err());

    // Two unresolved external writes stage the same current candidate and get distinct identities.
    let stage1 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    let stage2 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    assert_ne!(stage1, stage2);

    // Clearing stage1 (even twice) MUST consume only stage1, keeping stage2 protected.
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage1)).await.unwrap();
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage1)).await.unwrap();
    let other = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    assert!(d.ring.store_secret_key(&other).await.is_err());
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));

    // An untokened recovery clear must NOT drop active stage2.
    d.ring.clear_external_secret_key_commit(&candidate, None).await.unwrap();
    assert!(d.ring.store_secret_key(&other).await.is_err());
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));

    // Clearing stage2 settles all unresolved writes, permitting import.
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage2)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    d.ring.store_secret_key(&other).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(other.as_str()));

    // Once active key is `other`, staging stale `candidate` is rejected while `other` succeeds.
    assert!(d.ring.stage_external_secret_key_commit(&candidate).await.is_err());
    let stage3 = d.ring.stage_external_secret_key_commit(&other).await.unwrap();
    d.ring.clear_external_secret_key_commit(&other, Some(&stage3)).await.unwrap();
}

#[tokio::test]
async fn external_commit_settlement_decrements_per_write_and_same_key_import_preserves_guard() {
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    let conflicting = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage two concurrent external writes for the same candidate.
    let stage1 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    let stage2 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();

    // Committing stage1 settles only stage1, keeping stage2 protected and the durable intent intact.
    d.ring.commit_secret_key(&candidate, Some(&stage1)).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(candidate.as_str()));
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Duplicate commit of stage1 must NOT consume stage2.
    d.ring.commit_secret_key(&candidate, Some(&stage1)).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // A same-key import while stage2 is still unsettled must preserve the stage and durable intent.
    d.ring.store_secret_key(&candidate).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Settling stage2 clears the durable intent and allows later replacement.
    d.ring.commit_secret_key(&candidate, Some(&stage2)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    d.ring.store_secret_key(&conflicting).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(conflicting.as_str()));
}

#[tokio::test]
async fn durable_external_intent_blocks_conflicting_import_after_restart_even_when_key_active() {
    let d1 = Device::new("pw");
    let active_a = d1.secrets.secret_key.lock().unwrap().clone().unwrap();
    let other_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage an external write for active key A, then simulate process restart with a fresh KeyRing
    // sharing the same durable secrets (in-memory `external_commits` is now empty).
    let _stage = d1.ring.stage_external_secret_key_commit(&active_a).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));

    let restarted = KeyRing::new(d1.secrets.clone(), "test");
    // Conflicting import B MUST be rejected even though `active_a` is active and in-memory stages are empty.
    assert!(restarted.store_secret_key(&other_b).await.is_err());
    assert_eq!(d1.secrets.secret_key.lock().unwrap().as_deref(), Some(active_a.as_str()));

    // Same-key import A is allowed and MUST NOT clear the durable external intent.
    restarted.store_secret_key(&active_a).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    assert!(restarted.store_secret_key(&other_b).await.is_err());

    // Only settling the protected write clears the durable intent and allows replacement.
    restarted.commit_secret_key(&active_a, None).await.unwrap();
    assert!(!d1.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    restarted.store_secret_key(&other_b).await.unwrap();
    assert_eq!(d1.secrets.secret_key.lock().unwrap().as_deref(), Some(other_b.as_str()));
}

#[tokio::test]
async fn internal_key_commit_does_not_clear_unsettled_external_write_guard() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    let conflicting = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    let stage = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();

    // An internal key-file write promotes the same staged candidate, but must
    // NOT settle the unrelated in-flight external write.
    d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(candidate.as_str()));
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Once the external write settles, the guard and intent clear.
    d.ring.commit_secret_key(&candidate, Some(&stage)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:lkc-account-key"));
    d.ring.store_secret_key(&conflicting).await.unwrap();
}

#[tokio::test]
async fn detached_handle_failures_return_errors_without_mutating_replacement_status() {
    let file_old = Arc::new(MemKeyFile::default());
    let file_new = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw-good");
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    writer.ring.of(Arc::new(KeyFileOf(file_new.clone(), "remote".into())), true).await.unwrap();

    // Seed file_old with another password/secret key so old_handle fails even while
    // device credentials remain healthy for replacement (`file_new`).
    let other_writer = Device::new("pw-other");
    let other_sk = other_writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    other_writer.ring.of(Arc::new(KeyFileOf(file_old.clone(), "remote".into())), true).await.unwrap();

    let d = Device::new("pw-other");
    *d.secrets.secret_key.lock().unwrap() = Some(other_sk);
    let old_handle = d.ring.of(Arc::new(KeyFileOf(file_old.clone(), "remote".into())), true).await.unwrap();

    // Switch credentials/remote to `file_new`: release old_handle and open healthy replacement.
    d.ring.release("remote");
    *d.secrets.password.lock().unwrap() = Some("pw-good".into());
    *d.secrets.secret_key.lock().unwrap() = Some(sk);
    let _replacement = d.ring.of(Arc::new(KeyFileOf(file_new.clone(), "remote".into())), true).await.unwrap();
    assert!(d.ring.mismatch().borrow().is_empty());
    assert!(d.ring.secret_key_missing().borrow().is_empty());

    // Detached old_handle against `file_old` fails with PasswordMismatch while replacement stays healthy.
    assert!(matches!(old_handle.check(true, true).await, Err(Error::PasswordMismatch(ref id)) if id == "remote"));
    assert!(d.ring.mismatch().borrow().is_empty(), "detached handle must not mark replacement mismatched");

    // Detached old_handle with missing secret key fails with SecretKeyMissing without mutating ring status.
    *d.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(old_handle.check(true, true).await, Err(Error::SecretKeyMissing)));
    assert!(d.ring.secret_key_missing().borrow().is_empty(), "detached handle must not mark replacement missing");
}

#[tokio::test]
async fn set_epoch_2fa_enforces_epoch_floor_under_lock_and_forget_clears_it() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let key = d.key(&file).await.unwrap();

    // Advance remote and stored floor to epoch 1 via password change.
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // Equal epoch (1) remains valid during rotate.
    key.rotate().await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // If stored floor advances to 2 while rotate is in flight at epoch 1,
    // persisting epoch 1 under `epochs_lock` must be rejected with Untrusted
    // and must NOT rewind the stored floor.
    let secrets = d.secrets.clone();
    let err = key
        .rotate_after_check(move || {
            Box::pin(async move {
                secrets.epochs.lock().unwrap().insert("account".into(), 2);
                Ok(())
            })
        })
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Untrusted(_)), "expected Untrusted on epoch floor rollback, got {err:?}");
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2));

    // Higher epoch (3) remains valid when sealed above the floor.
    d.ring.password_changed(Some("pw2".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let new_id = {
        use age::secrecy::ExposeSecret;
        age::x25519::Identity::generate().to_string().expose_secret().to_string()
    };
    let epoch3_body = crate::key::seal_with_password(format!("# test, epoch 3\n{new_id}").as_bytes(), &sk.combine_passphrase("pw3")).unwrap();
    *file.file.lock().unwrap() = Some((epoch3_body, "v-epoch3".into()));
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&3));

    // `forget` clears the stored floor, allowing a fresh epoch-0 file.
    d.ring.forget("account").await.unwrap();
    assert!(!d.secrets.epochs.lock().unwrap().contains_key("account"));
    *file.file.lock().unwrap() = None;
    let fresh = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert_eq!(fresh.open(&fresh.seal(b"fresh").unwrap()).unwrap(), b"fresh");
}

#[tokio::test]
async fn probe_invalidation_is_scoped_per_remote_and_stale_handle_cannot_clear_missing() {
    let file_a = Arc::new(MemKeyFile::default());
    let file_b = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw");
    writer.ring.of(Arc::new(KeyFileOf(file_a.clone(), "remote-a".into())), true).await.unwrap();
    writer.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true).await.unwrap();

    // Device has no secret key: probe remote-a while remote-b is released.
    let reader = Device::new("pw");
    *reader.secrets.secret_key.lock().unwrap() = None;

    let read_started = Arc::new(tokio::sync::Notify::new());
    let release_read = Arc::new(tokio::sync::Notify::new());
    struct SlowProbe {
        id: String,
        inner: Arc<MemKeyFile>,
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowProbe {
        fn id(&self) -> String {
            self.id.clone()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(false) })
        }
    }

    let r_probe = reader.ring.clone();
    let probe_file_a = Arc::new(SlowProbe {
        id: "remote-a".into(),
        inner: file_a.clone(),
        started: read_started.clone(),
        release: release_read.clone(),
    });
    let probe_a = tokio::spawn(async move { r_probe.sealed_with_secret_key(probe_file_a).await.unwrap() });
    read_started.notified().await;

    // Activity on unrelated remote-b MUST NOT suppress remote-a's said_missing.
    reader.ring.release("remote-b");
    release_read.notify_one();
    assert!(probe_a.await.unwrap());
    assert!(reader.ring.secret_key_missing().borrow().contains("remote-a"));

    // A stale handle opened after release must not clear missing status for the same id.
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    let owner = Device::new("pw");
    *owner.secrets.secret_key.lock().unwrap() = Some(sk);
    let old_handle = owner.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true).await.unwrap();
    owner.ring.release("remote-b");
    // Probe remote-b without SK to mark it missing under the new state.
    *owner.secrets.secret_key.lock().unwrap() = None;
    assert!(owner.ring.sealed_with_secret_key(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into()))).await.unwrap());
    assert!(owner.ring.secret_key_missing().borrow().contains("remote-b"));
    // Restore SK and reopen the detached old handle: it is no longer registered,
    // so it must not clear the ring's missing status.
    *owner.secrets.secret_key.lock().unwrap() = writer.secrets.secret_key.lock().unwrap().clone();
    old_handle.check(true, true).await.unwrap();
    assert!(owner.ring.secret_key_missing().borrow().contains("remote-b"));
}

#[tokio::test]
async fn rotate_checkpoints_pending_accepted_join_before_rekey_and_aborts_on_failure() {
    struct ToggleFailPutHost {
        inner: Arc<MemHost>,
        fail_put: AtomicBool,
    }
    impl Host for ToggleFailPutHost {
        async fn device(&self) -> Result<u64> {
            self.inner.device().await
        }
        async fn stamp(&self) -> Result<()> {
            self.inner.stamp().await
        }
        async fn all(&self) -> Result<Vec<Stamped>> {
            self.inner.all().await
        }
        async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
            self.inner.pending(after).await
        }
        async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
            self.inner.read(ids).await
        }
        async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
            self.inner.apply(ops).await
        }
        async fn not_carried(&self) -> Result<HashSet<String>> {
            self.inner.not_carried().await
        }
        async fn after_read(&self, nc: HashSet<String>) -> Result<()> {
            self.inner.after_read(nc).await
        }
        async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
            self.inner.state(keys).await
        }
        async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
            self.inner.state_prefixed(prefix).await
        }
        async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
            if self.fail_put.load(Ordering::SeqCst) {
                return Err(Error::Host("sqlite busy".into()));
            }
            self.inner.set_state(values).await
        }
        async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
            self.inner.clear_state(prefix, keep).await
        }
        async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
            self.inner.pass(engine, ops).await
        }
        async fn passed(&self, engine: String) -> Result<Vec<Op>> {
            self.inner.passed(engine).await
        }
        async fn forget_passed(&self, engine: String) -> Result<()> {
            self.inner.forget_passed(engine).await
        }
        fn warn(&self, message: String) {
            self.inner.warn(message);
        }
    }

    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let host = Arc::new(ToggleFailPutHost { inner: d.host.clone(), fail_put: AtomicBool::new(true) });
    let sync = LogSync::new(host.clone(), log.clone(), key.clone());

    // First join append is accepted remotely (seq 1), but checkpoint write fails.
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].is_none());

    // Calling rotate while checkpoint still fails MUST NOT run rekey or send rotation append.
    let rekey_called = Arc::new(AtomicBool::new(false));
    let rk = rekey_called.clone();
    assert!(matches!(
        sync.rotate(async move {
            rk.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await,
        Err(Error::Host(_))
    ));
    assert!(!rekey_called.load(Ordering::SeqCst), "rekey must not run if checkpointing accepted join fails");
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);

    // Once storage recovers, rotate checkpoints the accepted join first without resending it,
    // then proceeds with rekey, rotation append, and snapshot.
    host.fail_put.store(false, Ordering::SeqCst);
    let key_c = key.clone();
    sync.rotate(async move { key_c.rotate().await }).await.unwrap();
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2, "only the rotation append should be sent after checkpointing");
    assert!(log.lock().snapshot.is_some());
}
