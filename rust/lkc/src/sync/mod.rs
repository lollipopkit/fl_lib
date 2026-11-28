//! Homebase's sync (`/v2/sync/{app}/{name}`): one app's files of a person.
//!
//! Every write names the version it read (`If-Match`), or `If-None-Match: *`
//! for a new file, and homebase takes it only when that is still the file's
//! version: a write that lost the race is [`Kind::Changed`], and the caller
//! reads, merges and writes again. The bodies are age files, encrypted before
//! they get here; homebase keeps them as they come.
//!
//! Each app also has a log (`/v2/sync/{app}/log`): batches homebase numbers
//! in the order they commit, read from a cursor, and a snapshot covering it up
//! to a seq ([`SyncClient::append`], [`SyncClient::read_log`],
//! [`SyncClient::put_snapshot`], [`SyncClient::download_snapshot`]).
//!
//! Homebase refuses a request it takes no token for as a `200` carrying
//! `{"code": 2}`, not as a `401`: a file's own answers always carry an
//! `ETag`, and one without it is that refusal only when a body says so.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, Weak};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::{Stream, StreamExt};
use reqwest::{Method, StatusCode, header};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex as AsyncMutex;

use crate::personal::{LogObserver, PersonalAuth, RETAINED_MISMATCH, RetainedBinding};
use crate::session::{Session, Store};
use crate::team::{canonical, team_bytes};
use crate::{Failure, now_ms, unreachable};

mod batches;
mod commits;
mod files;
mod http;
mod live;
mod snapshot;
use files::*;
use http::*;

/// Up to this a file is sent in one request; above it, straight to the store.
pub const DIRECT_MAX: u64 = 1 << 20;
/// The largest file any plan keeps (Cloud Basic's): each plan's own limit is
/// homebase's to say (`413 sync_file_too_large`).
pub const MAX_BYTES: u64 = 256 << 20;
/// What a download is read up to, held in memory: a snapshot is held to no
/// file's limit, but a phone holds no more than this of it.
const MAX_READ: u64 = MAX_BYTES;
/// What a JSON answer may be.
const MAX_JSON: usize = 1 << 20;
/// What a page of the log may be: homebase fills one while the batches
/// before the last come to under 1 MiB, so up to 1 MiB plus a batch, as
/// base64 (4/3) in JSON (up to 1000 batches' fields).
const MAX_LOG_PAGE: usize = 3 << 20;
/// The largest log batch homebase takes.
pub const BATCH_MAX: usize = 256 << 10;
/// The longest `Retry-After` a `503` is waited out for, once.
const RETRY_AFTER_MAX: Duration = Duration::from_secs(5);
/// How often a completion the store has not yet seen is asked again.
const COMPLETE_TRIES: u32 = 8;
/// The longest wait between two connections of [`SyncClient::events`].
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// Clock samples kept: the one sent and answered quickest is believed.
const SAMPLES: usize = 16;

/// Why a sync request did not go through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// Another version is there now (`412`): read, merge, write again.
    Changed,
    /// No such file, version or upload (`404`).
    Missing,
    /// Larger than one request carries, or than any plan keeps (`413`
    /// without a reason). Over the plan's own limit is
    /// `Refused("sync_file_too_large")`.
    TooLarge,
    /// Not an age file (`415`).
    NotAge,
    /// Homebase's `reason`: `sync_unavailable` (the plan has no sync),
    /// `sync_quota` or `sync_daily_limit` (`403`); `sync_file_too_large` (`413`,
    /// over the plan's per-file limit); `sync_log_full` (a snapshot
    /// is due) or `sync_snapshot_stale` (`409`); `sync_key_reused` (`422`).
    Refused(String),
    /// Too many writes this minute, or uploads under way (`429`).
    Busy,
    /// A team's write under a replaced key (`409`): the current epoch.
    StaleEpoch(i64),
    /// A file's version not past the highest homebase knows of it (`409`):
    /// that highest.
    Version(i64),
    /// Not signed in, or homebase no longer takes the session.
    SignedOut,
    /// Nothing reached homebase, or no answer: worth trying later.
    Unreachable,
    /// An answer this cannot read.
    Invalid,
    /// A signature failed verification, was stripped, or a version rolled back.
    Untrusted,
}

/// Result of a remote write that succeeded before local watermark persistence
/// failed, retained on [`Error::committed`] so callers can inspect the
/// committed result (such as the new ETag) and retry local persistence without
/// resending the write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Committed {
    File { etag: String, version: i64 },
    Batch(Appended),
    Snapshot { etag: String, seq: i64, log: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub kind: Kind,
    /// For logs; never a token.
    pub detail: String,
    /// Present when a remote write already committed before local persistence
    /// failed.
    pub committed: Option<Committed>,
}

impl Error {
    pub(crate) fn new(kind: Kind, detail: impl Into<String>) -> Self {
        Self { kind, detail: detail.into(), committed: None }
    }

    pub(crate) fn with_committed(mut self, committed: Committed) -> Self {
        self.committed = Some(committed);
        self
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.detail)
    }
}

impl std::error::Error for Error {}

/// What a write expects the file to be.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Condition {
    /// At this version.
    Match(String),
    /// Not there.
    Absent,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct File {
    pub name: String,
    pub etag: String,
    pub size: u64,
    /// RFC 3339.
    pub updated_at: String,
    /// A team's: the key epoch it was written under.
    #[serde(default)]
    pub epoch: Option<i64>,
    /// Its writer's signature, when signed.
    #[serde(flatten)]
    pub signed: Option<Signed>,
}

/// A write's signature as homebase keeps it: [signer] (a user id) under
/// [signing_key], [signature] (both base64), a file's [version].
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Signed {
    pub signer: String,
    pub signing_key: String,
    pub signature: String,
    #[serde(default)]
    pub version: Option<i64>,
}

impl Signed {
    fn of(response: &reqwest::Response) -> Option<Self> {
        let header = |name: &str| response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
        Some(Self {
            signer: header("x-signer")?,
            signing_key: header("x-signing-key")?,
            signature: header("x-signature")?,
            version: header("x-sync-version").and_then(|v| v.parse().ok()),
        })
    }
}

/// What a signed write sends: the signature (base64) and a file's version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteSig {
    pub signature: String,
    pub version: Option<i64>,
}

fn signed_by(request: reqwest::RequestBuilder, sig: Option<&WriteSig>) -> reqwest::RequestBuilder {
    match sig {
        None => request,
        Some(s) => {
            let request = request.header("x-signature", &s.signature);
            match s.version {
                Some(v) => request.header("x-sync-version", v),
                None => request,
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Version {
    pub etag: String,
    pub size: u64,
    /// RFC 3339.
    pub written_at: String,
    /// RFC 3339.
    pub replaced_at: String,
}

/// What a download did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fetched {
    Missing,
    /// The version named is the file's.
    Unchanged,
    /// Written to the path asked, at this version.
    Saved(String),
}

/// A batch appended to the log.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Appended {
    /// The log's id: a log made anew numbers from 1 again.
    pub log: String,
    pub seq: i64,
    pub live: Live,
    /// A snapshot is due.
    pub compact: bool,
}

/// What no snapshot covers yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Live {
    pub batches: i64,
    pub bytes: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub seq: i64,
    /// The age file, its digest checked.
    pub body: Vec<u8>,
    /// A team's: the key epoch it was sealed under.
    pub epoch: Option<i64>,
    /// What it was appended once by: its signature covers it.
    pub idempotency_key: Option<String>,
    /// Its writer's signature, when signed.
    pub signed: Option<Signed>,
}

/// Where the log is after a read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogRead {
    Page {
        /// `None` before the log's first batch.
        log: Option<String>,
        batches: Vec<Batch>,
        head: i64,
        snapshot_seq: i64,
        /// More batches follow the last: read again after it.
        more: bool,
    },
    /// The batches after the cursor are gone, or the cursor is of another
    /// log: load the snapshot, then read on from its seq.
    Compacted { log: Option<String>, snapshot_seq: i64 },
}

/// A snapshot downloaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub log: String,
    /// The seq it covers the log up to.
    pub seq: i64,
    /// Its writer's signature, when signed.
    pub signed: Option<Signed>,
}

#[derive(Deserialize)]
struct WireBatch {
    seq: i64,
    digest: String,
    body: String,
    #[serde(default)]
    epoch: Option<i64>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(flatten)]
    signed: Option<Signed>,
}

#[derive(Deserialize)]
struct WirePage {
    log: Option<String>,
    batches: Vec<WireBatch>,
    head: i64,
    snapshot_seq: i64,
    more: bool,
}

/// What [`SyncClient::events`] says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Listening (again): anything written while not was not heard.
    Connected,
    /// [name] is now at [etag], or removed (`None`), by another device.
    Changed { name: String, etag: Option<String> },
    /// The log reached [seq] (this device's own appends too): read on from
    /// the cursor.
    Log { seq: i64 },
    /// A team's members or key changed (`key`, `members`, `rotation_needed`,
    /// …): its keys are read again ([`SyncClient::team_events`]).
    Team { change: String },
    /// Not listening: a connection failed or ended, and is tried again after
    /// a wait. For logs; never a token.
    Lost(String),
}

#[derive(Deserialize)]
struct Begun {
    id: String,
    url: String,
}

/// This side's clock against homebase's, from `X-Server-Time`.
#[derive(Default)]
struct Clock {
    /// `(round trip, offset)` in milliseconds.
    samples: Mutex<VecDeque<(i64, i64)>>,
}

impl Clock {
    fn record(&self, sent: i64, received: i64, response: &reqwest::Response) {
        let server = response.headers().get("x-server-time").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<i64>().ok());
        let Some(server) = server else { return };
        let trip = received - sent;
        if trip < 0 {
            return;
        }
        let mut samples = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        if samples.len() == SAMPLES {
            samples.pop_front();
        }
        samples.push_back((trip, server - (sent + received) / 2));
    }

    fn offset_ms(&self) -> i64 {
        let samples = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        samples.iter().min_by_key(|(trip, _)| *trip).map_or(0, |(_, offset)| *offset)
    }
}

/// A team's space (`/v2/teams/{team}/sync`): every request names the key
/// epoch its writes are sealed under (`X-Team-Epoch`).
struct TeamSpace {
    id: String,
    epoch: AtomicI64,
}

#[derive(Default)]
struct PersonalSlot {
    auth: Option<Arc<PersonalAuth>>,
    generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum UploadMode {
    File,
    Blob,
}

struct FileMutationTracker {
    seq: u64,
    active: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum SnapshotLogBinding {
    /// Bound directly by a `Sync-Log` response header or `/snapshot` reconciliation.
    Confirmed(String),
    /// PUT response carried no `Sync-Log`; inferred from `signed_log_id` around the PUT.
    Assumed(String),
    /// Log identifier was unknown at commit time (or an `Assumed` binding differed from a
    /// newly observed log): neither a cache match nor proof of replacement until reconciled.
    Unknown,
}

type FileCommitKey = (String, Condition, [u8; 32], UploadMode);
type FileCommitEntry = (u64, String, i64);
type BatchCommitKey = (String, [u8; 32]);
type SnapshotCommitKey = (i64, [u8; 32]);
type SnapshotCommitEntry = (u64, SnapshotLogBinding, String);

#[derive(Default)]
struct PendingCommits {
    /// Matches [`PersonalSlot::generation`] so stale in-flight writes from a previous
    /// auth cannot insert or reuse recovery entries after `set_personal`.
    generation: u64,
    next_commit_id: u64,
    files: HashMap<FileCommitKey, FileCommitEntry>,
    next_mutation_seq: u64,
    /// Per-file mutation tracker retained only while at least one in-flight
    /// `upload_bytes` / `upload_blob_bytes` is between remote PUT commit and
    /// local watermark persistence and could still insert a recovery entry.
    file_mutations: HashMap<String, FileMutationTracker>,
    batches: HashMap<BatchCommitKey, (u64, Appended)>,
    /// Cached snapshot commits keyed by `(seq, digest)`, storing
    /// `(entry_id, log_binding, etag)` so a confirmed log replacement invalidates
    /// stale entries while an unknown log is reconciled before reuse or removal.
    snapshots: HashMap<SnapshotCommitKey, SnapshotCommitEntry>,
    /// Log identifier already observed and recorded under this `generation`,
    /// used to order live observations ahead of detached snapshot recovery.
    observed_log: Option<String>,
}

impl PendingCommits {
    fn next_id(&mut self) -> u64 {
        self.next_commit_id = self.next_commit_id.wrapping_add(1);
        self.next_commit_id
    }

    fn bump_if_tracked(&mut self, name: &str) {
        if let Some(entry) = self.file_mutations.get_mut(name) {
            self.next_mutation_seq = self.next_mutation_seq.wrapping_add(1);
            entry.seq = self.next_mutation_seq;
        }
    }

    /// Drops cached batch and confirmed-snapshot recovery entries belonging to a
    /// different log once [observed_log] is seen, while keeping unknown-log
    /// snapshot entries until they are reconciled against `/snapshot`.
    fn retain_for_log(&mut self, observed_log: &str) {
        self.batches.retain(|_, (_, appended)| appended.log == observed_log);
        self.snapshots.retain(|_, (_, binding, _)| match binding {
            SnapshotLogBinding::Confirmed(k) => k == observed_log,
            SnapshotLogBinding::Assumed(_) | SnapshotLogBinding::Unknown => true,
        });
        for (_, binding, _) in self.snapshots.values_mut() {
            if let SnapshotLogBinding::Assumed(k) = binding
                && k != observed_log
            {
                *binding = SnapshotLogBinding::Unknown;
            }
        }
    }
}

struct FileRecoveryToken<'a> {
    pending: &'a Mutex<PendingCommits>,
    name: String,
    auth_gen: u64,
    seq: u64,
}

impl Drop for FileRecoveryToken<'_> {
    fn drop(&mut self) {
        let mut guard = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation == self.auth_gen
            && let Some(entry) = guard.file_mutations.get_mut(&self.name)
        {
            entry.active = entry.active.saturating_sub(1);
            if entry.active == 0 {
                guard.file_mutations.remove(&self.name);
            }
        }
    }
}

/// [`LogObserver`] over [`PendingCommits::observed_log`] of one auth generation.
struct PendingLogObserver<'a, S: Store> {
    client: &'a SyncClient<S>,
    auth_gen: u64,
}

impl<S: Store> PendingLogObserver<'_, S> {
    fn with_pending<T>(&self, f: impl FnOnce(&mut PendingCommits) -> T) -> Result<T, Error> {
        let changed = || Error::new(Kind::SignedOut, "personal signing auth changed during write");
        let slot = self.client.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation != self.auth_gen || slot.auth.is_none() {
            return Err(changed());
        }
        let mut guard = self.client.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation != self.auth_gen {
            return Err(changed());
        }
        Ok(f(&mut guard))
    }
}

impl<S: Store> LogObserver for PendingLogObserver<'_, S> {
    fn commit(&self, log: &str) -> Result<bool, Error> {
        self.with_pending(|p| {
            if p.observed_log.as_deref().is_some_and(|obs| obs != log) {
                return false;
            }
            p.observed_log = Some(log.to_string());
            p.retain_for_log(log);
            true
        })
    }

    fn confirm(&self, log: &str) -> Result<bool, Error> {
        self.with_pending(|p| p.observed_log.as_deref() == Some(log))
    }
}

/// One app's sync, on a signed-in [`Session`]: the person's own files, or a
/// team's (`SyncClient::for_team`).
pub struct SyncClient<S: Store> {
    session: Arc<Session<S>>,
    app: String,
    team: Option<TeamSpace>,
    /// Personal-space Ed25519 signer/verifier and monotonic version tracker.
    personal: Mutex<PersonalSlot>,
    clock: Clock,
    /// The version each name was last written at by this device, so its own
    /// writes heard back on [`SyncClient::events`] are not taken for another's.
    written: Mutex<HashMap<String, String>>,
    /// Per-file async ordering locks serializing PUT response/ETag commits and
    /// DELETE completion for the same name.
    file_locks: Mutex<HashMap<String, Weak<AsyncMutex<()>>>>,
    /// Committed remote writes whose local watermark save failed, keyed so a
    /// retry flushes local persistence and returns the committed result without
    /// resending the remote write.
    pending_commits: Mutex<PendingCommits>,
    #[cfg(test)]
    after_verify_before_rename: Mutex<Option<TestPostVerifyHook>>,
    #[cfg(test)]
    before_file_lock: Mutex<Option<Arc<tokio::sync::Notify>>>,
}

#[cfg(test)]
type TestPostVerifyHook = Arc<dyn Fn() -> Pin<Box<dyn std::future::Future<Output = ()> + Send>> + Send + Sync>;

/// An event stream's body as it arrives.
type Body = Pin<Box<dyn Stream<Item = reqwest::Result<bytes::Bytes>> + Send>>;

impl<S: Store> SyncClient<S> {
    /// [app]: `serverbox`, `gptbox`, … (`[a-z0-9._-]`, not starting with `.`).
    pub fn new(session: Arc<Session<S>>, app: &str) -> Self {
        Self {
            session,
            app: app.to_string(),
            team: None,
            personal: Mutex::new(PersonalSlot::default()),
            clock: Clock::default(),
            written: Mutex::new(HashMap::new()),
            file_locks: Mutex::new(HashMap::new()),
            pending_commits: Mutex::new(PendingCommits::default()),
            #[cfg(test)]
            after_verify_before_rename: Mutex::new(None),
            #[cfg(test)]
            before_file_lock: Mutex::new(None),
        }
    }

    /// Attaches or clears personal-space signing and rollback protection.
    /// Ignored on team clients (which sign through [`crate::team::TeamSpace`]).
    /// Changing or detaching auth advances the auth generation and clears
    /// cached per-account commit recovery state and SSE own-write markers so
    /// another auth instance or in-flight write from a previous auth never
    /// inherits or pollutes them.
    pub fn set_personal(&self, auth: Option<Arc<PersonalAuth>>) {
        if self.team.is_none() {
            let mut slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            let same = match (&slot.auth, &auth) {
                (Some(a), Some(b)) => Arc::ptr_eq(a, b),
                (None, None) => true,
                _ => false,
            };
            if !same {
                // Keep `personal` locked while updating `pending_commits` and
                // `written` (strict lock order: personal -> pending_commits ->
                // written) so concurrent `set_personal` calls cannot rewind
                // `pending.generation` or race with writes on the new auth.
                slot.generation = slot.generation.wrapping_add(1);
                slot.auth = auth;
                let mut pending = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                pending.generation = slot.generation;
                pending.files.clear();
                pending.file_mutations.clear();
                pending.batches.clear();
                pending.snapshots.clear();
                pending.observed_log = None;
                drop(pending);
                self.written.lock().unwrap_or_else(|e| e.into_inner()).clear();
            }
        }
    }

    fn personal_generation(&self) -> u64 {
        self.personal.lock().unwrap_or_else(|e| e.into_inner()).generation
    }

    fn personal_auth_with_gen(&self) -> Option<(u64, Arc<PersonalAuth>)> {
        if self.team.is_some() {
            return None;
        }
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        slot.auth.as_ref().map(|a| (slot.generation, a.clone()))
    }

    fn ensure_personal_gen(&self, expected_gen: u64) -> Result<(), Error> {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        match (&slot.auth, slot.generation == expected_gen) {
            (Some(_), true) => Ok(()),
            (None, _) => Err(Error::new(Kind::SignedOut, "personal signing auth detached during write")),
            (Some(_), false) => Err(Error::new(Kind::SignedOut, "personal signing auth changed during write")),
        }
    }

    /// [to]'s lock, one per destination in the process (whichever client
    /// downloads there): its `.part` staging, verification and rename go
    /// under it, so a download neither overwrites another's staged bytes nor
    /// puts an older version over a newer one.
    fn dest_lock(&self, to: &Path) -> Arc<AsyncMutex<()>> {
        static DEST_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Weak<AsyncMutex<()>>>>> = LazyLock::new(Default::default);
        let mut map = DEST_LOCKS.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = map.get(to).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(AsyncMutex::new(()));
        map.insert(to.to_path_buf(), Arc::downgrade(&lock));
        lock
    }

    /// Per-name lock serializing PUT response/ETag commits and DELETE
    /// completion for [name], pruned automatically when no holders remain.
    fn file_lock(&self, name: &str) -> Arc<AsyncMutex<()>> {
        let mut map = self.file_locks.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = map.get(name).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(AsyncMutex::new(()));
        map.insert(name.to_string(), Arc::downgrade(&lock));
        lock
    }

    /// [app]'s files of team [team] (its id), written under key [epoch].
    pub(crate) fn for_team(session: Arc<Session<S>>, team: &str, app: &str, epoch: i64) -> Self {
        // Canonical, so homebase's events name it alike however it was given.
        let team = Some(TeamSpace { id: canonical(team).unwrap_or_else(|_| team.to_string()), epoch: AtomicI64::new(epoch) });
        Self {
            session,
            app: app.to_string(),
            team,
            personal: Mutex::new(PersonalSlot::default()),
            clock: Clock::default(),
            written: Mutex::new(HashMap::new()),
            file_locks: Mutex::new(HashMap::new()),
            pending_commits: Mutex::new(PendingCommits::default()),
            #[cfg(test)]
            after_verify_before_rename: Mutex::new(None),
            #[cfg(test)]
            before_file_lock: Mutex::new(None),
        }
    }

    /// Whether personal-space signing is currently attached on this client.
    pub fn has_personal_auth(&self) -> bool {
        self.personal_auth_with_gen().is_some()
    }

    /// The key epoch a team's writes now name; after a rotation, or a
    /// [`Kind::StaleEpoch`].
    pub(crate) fn set_epoch(&self, epoch: i64) {
        if let Some(t) = &self.team {
            t.epoch.store(epoch, Ordering::Release);
        }
    }

    /// The epoch writes name; `None` for the person's own files.
    pub(crate) fn epoch(&self) -> Option<i64> {
        self.team.as_ref().map(|t| t.epoch.load(Ordering::Acquire))
    }

    pub fn session(&self) -> &Arc<Session<S>> {
        &self.session
    }

    /// Homebase's clock minus this one's, in milliseconds; 0 before any answer.
    pub fn offset_ms(&self) -> i64 {
        self.clock.offset_ms()
    }
}

enum ReconciledSnapshot {
    Hit(String, String),
    Replaced(u64),
    Gone,
    /// `/snapshot` is on a log other than the one observed under the auth
    /// generation: nothing is settled.
    Conflicted,
}

enum DetachedReconcile {
    Recovered(String),
    Conflicted,
    Gone,
}

/// Which snapshot recovery entries a persisted watermark settles.
#[derive(Clone)]
enum Settle {
    Nothing,
    /// The entry under this key, if it still has this id.
    Entry(SnapshotCommitKey, u64),
    /// Entries at or below this seq of this log (of no known log for `None`).
    Covered(Option<String>, i64),
}

#[derive(Clone, Copy)]
enum DownloadVerify<'a> {
    File,
    BlobStrict,
    BlobRetained(RetainedBinding<'a>),
}

/// Where a download goes.
enum Target<'a> {
    File(&'a Path),
    /// Exclusively creates a unique temporary file beside the destination and
    /// streams into it while computing its blake3 digest; caller verifies
    /// signatures before renaming that same file into place.
    FileHashed(&'a Path, &'a mut Option<PartGuard>, &'a mut [u8; 32]),
    /// Streams response bytes only to compute their blake3 digest without
    /// allocating or touching disk.
    HashOnly(&'a mut [u8; 32]),
    Memory(&'a mut Vec<u8>),
}

#[cfg(test)]
mod tests;
