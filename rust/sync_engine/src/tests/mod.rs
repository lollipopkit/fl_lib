//! An in-memory host, LK Cloud log, folder, key file and keychain: devices
//! syncing with each other through them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use fl_sync::{Clock, Hlc, Op};
use serde_json::{Value, json};

use crate::key::{BoxFuture, KeyFile, KeyRing, Secrets, SyncKey, Versioned};
use crate::log::{Appended, LogSync, LogTransport, Page, SnapshotBody};
use crate::segment::{Files, SegmentSync};
use crate::{BlobStore, Error, Host, Listed, Read, Result, Seal, Stamped, now_ms};

mod intents;
mod key;
mod lkc;
mod log;
mod secret_key;
mod segment;
mod snapshot;

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
        Ok(self.lock().blobs.iter().filter(|(n, _)| n.starts_with(&prefix)).map(|(n, (_, at))| Listed { name: n.clone(), at: Some(*at), signed: false }).collect())
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
        Ok(Page::Batches { log: Some(s.log.clone()), batches: next.into_iter().take(self.page).map(|(seq, _, b)| (*seq, b.clone(), false)).collect(), more })
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
        Ok(s.snapshot.as_ref().map(|(seq, body)| SnapshotBody { log: s.log.clone(), seq: *seq, body: body.clone(), signed: false }))
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
        Ok(self.files.lock().unwrap().iter().filter(|(n, _)| n.starts_with(&prefix)).map(|(n, (_, at))| Listed { name: n.clone(), at: Some(*at), signed: false }).collect())
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

    fn orders_writes(&self) -> bool {
        !self.0.unordered
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
    /// Runs after each `set_pending`, with what was saved.
    on_set_pending: Mutex<Option<PendingHook>>,
}

type PendingHook = Box<dyn Fn(&HashMap<String, String>) + Send + Sync>;

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
            *self.pending.lock().unwrap() = pending.clone();
            if let Some(hook) = self.on_set_pending.lock().unwrap().as_ref() {
                hook(&pending);
            }
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

