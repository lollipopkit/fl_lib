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

use crate::personal::{LogObserver, PersonalAuth};
use crate::session::{Session, Store};
use crate::team::{canonical, team_bytes};
use crate::{Failure, now_ms, unreachable};

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
/// team's ([`SyncClient::for_team`]).
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

    /// Persists the local signing watermark for a file write that already
    /// committed remotely at [version] under [expected_user], without resending
    /// a conditional PUT even if [`Self::set_personal`] has since replaced the
    /// [`PersonalAuth`] instance for the same account.
    pub async fn flush_committed_file(&self, expected_user: &str, name: &str, version: i64) -> Result<(), Error> {
        const MAX_AUTH_REBIND_RETRIES: usize = 4;
        if version <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed file version {version}")));
        }
        for _ in 0..MAX_AUTH_REBIND_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            auth.record_file_version(&self.app, name, version).await?;
            let lock = self.file_lock(name);
            let _file_guard = lock.lock().await;
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if slot.generation == auth_gen && slot.auth.is_some() {
                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                if guard.generation == auth_gen {
                    guard.files.retain(|(file_name, _, _, mode), (_, _, entry_ver)| {
                        !(file_name == name && *mode == UploadMode::File && *entry_ver <= version)
                    });
                }
                return Ok(());
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during file watermark flush"))
    }

    /// Persists the local signing watermark for a snapshot write that already
    /// committed remotely at [seq] under [expected_user] (on [log], when known,
    /// or resolved from [body]'s recovery entry / `/snapshot` when [log] is
    /// `None`), without resending `PUT /snapshot`. Returns `(compatible, resolved_log)`.
    pub async fn flush_committed_snapshot_bytes(
        &self,
        expected_user: &str,
        log: Option<&str>,
        seq: i64,
        body: &[u8],
    ) -> Result<(bool, Option<String>), Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        if seq <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed snapshot seq {seq}")));
        }
        let commit_key = (seq, *blake3::hash(body).as_bytes());
        for _ in 0..MAX_CACHE_FLUSH_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before snapshot watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            let current_log = auth.signed_log_id(&self.app).await;
            enum FlushAction {
                Direct(String),
                Reconcile(u64, String),
                Missing,
            }
            let action = {
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        match guard.snapshots.get(&commit_key) {
                            Some((_, SnapshotLogBinding::Confirmed(k), _)) => FlushAction::Direct(k.clone()),
                            Some((id, SnapshotLogBinding::Assumed(_) | SnapshotLogBinding::Unknown, etag)) => {
                                FlushAction::Reconcile(*id, etag.clone())
                            }
                            None => FlushAction::Missing,
                        }
                    } else {
                        continue;
                    }
                } else {
                    continue;
                }
            };
            match action {
                FlushAction::Direct(resolved_log) => {
                    let compatible = self.flush_committed_snapshot(expected_user, Some(&resolved_log), seq).await?;
                    return Ok((compatible, compatible.then_some(resolved_log)));
                }
                FlushAction::Reconcile(entry_id, expected_etag) => {
                    match self.reconcile_snapshot_commit(&auth, auth_gen, commit_key, entry_id, &expected_etag).await? {
                        ReconciledSnapshot::Hit(_, resolved_log) => return Ok((true, Some(resolved_log))),
                        ReconciledSnapshot::Replaced(_) => continue,
                        ReconciledSnapshot::Gone => {
                            self.flush_gone_snapshot(expected_user, &auth, auth_gen, log, seq).await?;
                            return Ok((false, None));
                        }
                    }
                }
                FlushAction::Missing => {
                    let observed_conflicts = log.is_some_and(|target_log| {
                        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                        if slot.generation != auth_gen {
                            return false;
                        }
                        let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                        guard.generation == auth_gen
                            && guard.observed_log.as_deref().is_some_and(|obs| obs != target_log)
                    });
                    match log {
                        Some(target_log)
                            if !observed_conflicts
                                && (current_log.is_none() || current_log.as_deref() == Some(target_log)) =>
                        {
                            let compatible = self.flush_committed_snapshot(expected_user, Some(target_log), seq).await?;
                            return Ok((compatible, compatible.then(|| target_log.to_string())));
                        }
                        _ => match self.reconcile_detached_snapshot(&auth, auth_gen, commit_key).await? {
                            DetachedReconcile::Recovered(resolved_log) => return Ok((true, Some(resolved_log))),
                            DetachedReconcile::Conflicted => return Ok((false, None)),
                            DetachedReconcile::Gone => {
                                self.flush_gone_snapshot(expected_user, &auth, auth_gen, log, seq).await?;
                                return Ok((false, None));
                            }
                        },
                    }
                }
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during snapshot watermark flush"))
    }

    /// Records a committed snapshot `/snapshot` no longer serves: on a known
    /// [log] through [`Self::flush_committed_snapshot`], which records only the
    /// signed-snapshot marker once [log] is superseded; on an unknown one only
    /// the marker, as [seq] belongs to no known log floor.
    async fn flush_gone_snapshot(&self, expected_user: &str, auth: &PersonalAuth, auth_gen: u64, log: Option<&str>, seq: i64) -> Result<(), Error> {
        match log {
            Some(l) => self.flush_committed_snapshot(expected_user, Some(l), seq).await.map(drop),
            None => {
                auth.record_snapshot_seen(&self.app).await?;
                self.ensure_personal_gen(auth_gen)?;
                self.prune_committed_snapshots(auth_gen, None, seq);
                Ok(())
            }
        }
    }

    async fn reconcile_detached_snapshot(
        &self,
        auth: &PersonalAuth,
        auth_gen: u64,
        commit_key: (i64, [u8; 32]),
    ) -> Result<DetachedReconcile, Error> {
        let (seq, ref expected_digest) = commit_key;
        let mut digest = [0u8; 32];
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), Target::HashOnly(&mut digest), None, |response| {
                found = header_non_empty(response, "sync-log")
                    .zip(header_non_empty(response, "sync-seq").and_then(|v| v.parse().ok()))
                    .map(|(log, s)| Snapshot { log, seq: s, signed: Signed::of(response) });
            })
            .await?;
        self.ensure_personal_gen(auth_gen)?;
        match fetched {
            Fetched::Missing => Ok(DetachedReconcile::Gone),
            Fetched::Saved(_) => {
                let Some(snap) = found else {
                    return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                };
                let same_snapshot = snap.seq == seq && &digest == expected_digest;
                if snap.signed.is_none() {
                    if same_snapshot {
                        return Err(Error::new(
                            Kind::Untrusted,
                            format!("{}/snapshot seq {}: server stripped signature", self.app, snap.seq),
                        ));
                    }
                    auth.verify_snapshot_digest(&self.app, &snap, &digest).await?;
                    self.ensure_personal_gen(auth_gen)?;
                    return Ok(DetachedReconcile::Gone);
                }
                // Any log observed under `auth_gen` or recorded on this
                // `PersonalAuth` takes precedence over a detached recovery
                // probe for a different log.
                let recorded = auth
                    .verify_snapshot_digest_for_detached(&self.app, &snap, &digest, &PendingLogObserver { client: self, auth_gen })
                    .await?;
                self.ensure_personal_gen(auth_gen)?;
                if !recorded {
                    return Ok(DetachedReconcile::Conflicted);
                }
                Ok(if same_snapshot {
                    DetachedReconcile::Recovered(snap.log)
                } else {
                    DetachedReconcile::Gone
                })
            }
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }
    /// Persists the local signing watermark for a snapshot write that already
    /// committed remotely at [seq] under [expected_user] (on [log], when known),
    /// without resending `PUT /snapshot`. Returns `false` if another log
    /// superseded [log], including one observed while its binding was saved.
    pub async fn flush_committed_snapshot(&self, expected_user: &str, log: Option<&str>, seq: i64) -> Result<bool, Error> {
        const MAX_AUTH_REBIND_RETRIES: usize = 4;
        if seq <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed snapshot seq {seq}")));
        }
        for _ in 0..MAX_AUTH_REBIND_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before snapshot watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            let compatible = match auth
                .record_snapshot_if_log_compatible(&self.app, log, seq, &PendingLogObserver { client: self, auth_gen })
                .await
            {
                Ok(compatible) => compatible,
                Err(e) if e.kind == Kind::SignedOut && self.ensure_personal_gen(auth_gen).is_err() => continue,
                Err(e) => return Err(e),
            };
            if self.prune_committed_snapshots(auth_gen, log, seq) {
                return Ok(compatible);
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during snapshot watermark flush"))
    }

    /// Drops pending snapshot commits at or below [seq] of [log] (of no
    /// known log for `None`); false when the signing auth changed.
    fn prune_committed_snapshots(&self, auth_gen: u64, log: Option<&str>, seq: i64) -> bool {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation != auth_gen || slot.auth.is_none() {
            return false;
        }
        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation == auth_gen {
            guard.snapshots.retain(|(entry_seq, _), (_, binding, _)| {
                if *entry_seq > seq {
                    return true;
                }
                match (log, binding) {
                    (Some(l), SnapshotLogBinding::Confirmed(k) | SnapshotLogBinding::Assumed(k)) => k != l,
                    (Some(_), SnapshotLogBinding::Unknown) => true,
                    (None, SnapshotLogBinding::Confirmed(_) | SnapshotLogBinding::Assumed(_)) => true,
                    (None, SnapshotLogBinding::Unknown) => false,
                }
            });
        }
        true
    }

    fn retain_log_commits(&self, auth_gen: u64, observed_log: Option<&str>) {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation == auth_gen {
            let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
            if guard.generation == auth_gen {
                match observed_log {
                    Some(log_id) => {
                        guard.observed_log = Some(log_id.to_string());
                        guard.retain_for_log(log_id);
                    }
                    None => {
                        guard.batches.clear();
                        guard.snapshots.clear();
                    }
                }
            }
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

    /// [name]'s version, `None` when there is no such file.
    pub async fn head(&self, name: &str) -> Result<Option<String>, Error> {
        let response = self.send(Method::HEAD, &self.file_path(name)?, |r| r).await?;
        match response.status() {
            StatusCode::OK => match self.etag(&response) {
                Some(etag) => Ok(Some(etag)),
                None => Err(self.without_version().await),
            },
            StatusCode::NOT_FOUND => Ok(None),
            _ => Err(refusal(response).await),
        }
    }

    /// [name] written to [to], unless its version is [known].
    pub async fn download(&self, name: &str, to: &Path, known: Option<&str>) -> Result<Fetched, Error> {
        self.fetch_file(&self.file_path(name)?, name, to, known, true).await
    }

    /// [name]'s bytes, version and its writer's signature (when signed);
    /// `None` when there is no such file.
    pub async fn download_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        self.download_bytes_inner(name, DownloadVerify::File).await.0
    }

    /// Write-once log blob variant of [`Self::download_bytes`]: verifies the
    /// signature without recording a per-file version watermark.
    pub async fn download_blob_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        self.download_bytes_inner(name, DownloadVerify::BlobStrict).await.0
    }

    /// Like [`Self::download_blob_bytes`], also returning whether personal auth
    /// was attached and verified this download.
    pub async fn download_blob_bytes_checked(&self, name: &str) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        self.download_bytes_inner(name, DownloadVerify::BlobStrict).await
    }

    /// Like [`Self::download_blob_bytes`] for a blob bound to a pre-signing
    /// reference retained by a batch or snapshot: allows an unsigned response
    /// only when [name] was never previously seen or written signed.
    pub async fn download_retained_blob_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        self.download_bytes_inner(name, DownloadVerify::BlobRetained).await.0
    }

    /// Like [`Self::download_retained_blob_bytes`], also returning whether
    /// personal auth was attached and verified this download.
    pub async fn download_retained_blob_bytes_checked(&self, name: &str) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        self.download_bytes_inner(name, DownloadVerify::BlobRetained).await
    }

    async fn download_bytes_inner(&self, name: &str, verify: DownloadVerify) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        let auth = self.personal_auth_with_gen();
        let has_auth = auth.is_some();
        let res = async {
            let mut body = Vec::new();
            let mut signed = None;
            match self.fetch_with(&self.file_path(name)?, Target::Memory(&mut body), None, |r| signed = Signed::of(r)).await? {
                Fetched::Saved(etag) => {
                    if let Some((auth_gen, auth)) = auth {
                        self.ensure_personal_gen(auth_gen)?;
                        match verify {
                            DownloadVerify::File => auth.verify_file(&self.app, name, &body, signed.as_ref(), true).await?,
                            DownloadVerify::BlobStrict => auth.verify_blob(&self.app, name, &body, signed.as_ref()).await?,
                            DownloadVerify::BlobRetained => auth.verify_retained_blob(&self.app, name, &body, signed.as_ref()).await?,
                        }
                        self.ensure_personal_gen(auth_gen)?;
                    }
                    Ok(Some((body, etag, signed)))
                }
                Fetched::Missing => {
                    if let Some((auth_gen, _)) = auth {
                        self.ensure_personal_gen(auth_gen)?;
                    }
                    Ok(None)
                }
                Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a file answered 304")),
            }
        }
        .await;
        (res, has_auth)
    }

    /// A kept version of [name] ([`SyncClient::versions`]) written to [to].
    pub async fn download_version(&self, name: &str, etag: &str, to: &Path) -> Result<Fetched, Error> {
        if !etag.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::new(Kind::Invalid, "not a version"));
        }
        self.fetch_file(&format!("{}/versions/{etag}", self.file_path(name)?), name, to, None, false).await
    }

    /// [from] as [name]'s new version, if [condition] still holds. Answers the
    /// new version.
    pub async fn upload(&self, name: &str, from: &Path, condition: Condition) -> Result<String, Error> {
        self.upload_bytes(name, read_file(from).await?, condition).await
    }

    /// [body] as [name]'s new version, if [condition] still holds.
    /// When personal signing is attached, signs the write and advances the
    /// monotonic file version automatically.
    pub async fn upload_bytes(&self, name: &str, body: Vec<u8>, condition: Condition) -> Result<String, Error> {
        self.upload_bytes_inner(name, body, condition, false).await.0
    }

    /// Write-once log blob upload (`Condition::Absent`): signs the write when
    /// personal signing is attached, and records blob signing without adding a
    /// per-file version watermark.
    pub async fn upload_blob_bytes(&self, name: &str, body: Vec<u8>) -> Result<String, Error> {
        self.upload_bytes_inner(name, body, Condition::Absent, true).await.0
    }

    /// Like [`Self::upload_blob_bytes`], also returning whether personal
    /// signing was attached for this upload attempt.
    pub async fn upload_blob_bytes_checked(&self, name: &str, body: Vec<u8>) -> (Result<String, Error>, bool) {
        self.upload_bytes_inner(name, body, Condition::Absent, true).await
    }

    async fn upload_bytes_inner(&self, name: &str, body: Vec<u8>, condition: Condition, write_once_blob: bool) -> (Result<String, Error>, bool) {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return (self.upload_signed(name, body, condition, None).await, false);
        };
        let res = async {
            let body = bytes::Bytes::from(body);
            let mode = if write_once_blob { UploadMode::Blob } else { UploadMode::File };
            let commit_key = (name.to_string(), condition.clone(), *blake3::hash(&body).as_bytes(), mode);
            let mut expected_id = {
                let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                (guard.generation == auth_gen)
                    .then(|| guard.files.get(&commit_key).map(|(id, _, _)| *id))
                    .flatten()
            };
            if expected_id.is_some() {
                for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                    let Some(entry_id) = expected_id else { break };
                    let flushed = auth.flush_pending_versions().await;
                    let lock = self.file_lock(name);
                    let _file_guard = lock.lock().await;
                    match flushed {
                        Ok(()) => {
                            enum CacheCheck {
                                Hit(String),
                                Replaced(u64),
                                Gone,
                            }
                            let check = {
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.files.get(&commit_key) {
                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                let (_, etag, _) = guard.files.remove(&commit_key).expect("entry present");
                                                CacheCheck::Hit(etag)
                                            }
                                            Some((cur_id, _, _)) => CacheCheck::Replaced(*cur_id),
                                            None => CacheCheck::Gone,
                                        }
                                    } else {
                                        CacheCheck::Gone
                                    }
                                } else {
                                    CacheCheck::Gone
                                }
                            };
                            match check {
                                CacheCheck::Hit(etag) => return Ok(etag),
                                CacheCheck::Replaced(next_id) => {
                                    expected_id = Some(next_id);
                                    continue;
                                }
                                CacheCheck::Gone => break,
                            }
                        }
                        Err(e) => {
                            if e.kind == Kind::Invalid {
                                let still_valid = {
                                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                    if slot.generation == auth_gen {
                                        let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                        (guard.generation == auth_gen)
                                            .then(|| {
                                                guard.files.get(&commit_key).and_then(|(cur_id, etag, version)| {
                                                    (*cur_id == entry_id).then(|| (etag.clone(), *version))
                                                })
                                            })
                                            .flatten()
                                    } else {
                                        None
                                    }
                                };
                                if let Some((etag, version)) = still_valid {
                                    return Err(e.with_committed(Committed::File { etag, version }));
                                }
                            }
                            return Err(e);
                        }
                    }
                }
                self.ensure_personal_gen(auth_gen)?;
            }
            auth.flush_pending_versions().await?;
            self.ensure_personal_gen(auth_gen)?;
            auth.ensure_published(&self.session, false).await?;
            self.ensure_personal_gen(auth_gen)?;
            let mut version = if write_once_blob { 1 } else { auth.next_file_version(&self.app, name).await? };
            let mut republished = false;
            let mut version_retried = false;
            loop {
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_file(&self.app, name, version, &body).await;
                match self.upload_signed_bytes(name, body.clone(), condition.clone(), Some(&sig), auth_gen, true).await {
                    Ok((etag, recovery)) => {
                        let recorded = if write_once_blob {
                            auth.record_named_blob_written(&self.app, name).await
                        } else {
                            auth.record_file_version(&self.app, name, version).await
                        };
                        if let Err(e) = recorded {
                            if e.kind == Kind::Invalid {
                                if let Some(ref token) = recovery {
                                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                    if slot.generation == auth_gen {
                                        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                        if guard.generation == auth_gen
                                            && guard.file_mutations.get(name).map(|m| m.seq) == Some(token.seq)
                                        {
                                            let id = guard.next_id();
                                            guard.files.insert(commit_key, (id, etag.clone(), version));
                                        }
                                    }
                                }
                                return Err(e.with_committed(Committed::File { etag, version }));
                            }
                            return Err(e);
                        }
                        return Ok(etag);
                    }
                    Err(e) if !version_retried && matches!(e.kind, Kind::Version(_)) => {
                        let Kind::Version(highest) = e.kind else { unreachable!() };
                        if highest < version {
                            return Err(Error::new(Kind::Untrusted, format!("server sync_version {highest} is below attempted {version}")));
                        }
                        version = highest.checked_add(1).ok_or_else(|| Error::new(Kind::Untrusted, "server sync_version overflow"))?;
                        version_retried = true;
                    }
                    Err(e) if !republished && matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                        self.ensure_personal_gen(auth_gen)?;
                        auth.ensure_published(&self.session, true).await?;
                        republished = true;
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        .await;
        (res, true)
    }

    /// [upload_bytes], signed by its writer ([sig]): a team's every write is.
    pub async fn upload_signed(&self, name: &str, body: Vec<u8>, condition: Condition, sig: Option<&WriteSig>) -> Result<String, Error> {
        let start_gen = self.personal_generation();
        self.upload_signed_bytes(name, bytes::Bytes::from(body), condition, sig, start_gen, false).await.map(|(etag, _)| etag)
    }

    async fn upload_signed_bytes(
        &self,
        name: &str,
        bytes: bytes::Bytes,
        condition: Condition,
        sig: Option<&WriteSig>,
        expected_gen: u64,
        track_recovery: bool,
    ) -> Result<(String, Option<FileRecoveryToken<'_>>), Error> {
        let path = self.file_path(name)?;
        let size = bytes.len() as u64;
        if size > MAX_BYTES {
            return Err(Error::new(Kind::TooLarge, format!("{size} bytes")));
        }
        let start_session = self
            .session
            .identity()
            .ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?;
        let (start_gen, start_personal_attached) = if track_recovery {
            (expected_gen, true)
        } else {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            (slot.generation, slot.auth.is_some())
        };
        #[cfg(test)]
        if let Some(notify) = self.before_file_lock.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            notify.notify_one();
        }
        let lock = self.file_lock(name);
        let _file_guard = lock.lock().await;
        if self.session.identity() != Some(start_session) {
            return Err(Error::new(Kind::SignedOut, "session changed before upload"));
        }
        let (active_gen, active_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if start_personal_attached && (slot.generation != start_gen || slot.auth.is_none()) {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed before upload"));
            }
            (slot.generation, slot.auth.is_some())
        };
        let bound = Some((start_session, active_gen, active_personal_attached));
        let etag = if size <= DIRECT_MAX {
            let response = self
                .send_for(bound, Method::PUT, &path, |r| {
                    signed_by(condition_on(r, &condition), sig)
                        .header(header::CONTENT_TYPE, "application/octet-stream")
                        .header(header::CONTENT_LENGTH, size)
                        .body(bytes.clone())
                })
                .await?;
            self.written_version_for(Some(start_session), response).await?
        } else {
            let response = self
                .send_for(bound, Method::POST, &format!("{path}/uploads"), |r| {
                    signed_by(condition_on(r, &condition), sig).json(&serde_json::json!({ "size": size }))
                })
                .await?;
            let begun: Begun = self.json_for(Some(start_session), response, MAX_JSON).await?;
            if self.session.identity() != Some(start_session)
                || (active_personal_attached && self.personal_generation() != active_gen)
            {
                return Err(Error::new(Kind::SignedOut, "session changed during multipart upload"));
            }
            self.store_upload(&begun.url, bytes).await?;
            self.complete_for(bound, &path, &begun.id).await?
        };
        let recovery = if self.session.identity() == Some(start_session) {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if slot.generation == active_gen {
                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                let token = if guard.generation == active_gen {
                    guard.files.retain(|(file_name, _, _, _), _| file_name != name);
                    if track_recovery {
                        guard.next_mutation_seq = guard.next_mutation_seq.wrapping_add(1);
                        let seq = guard.next_mutation_seq;
                        let entry = guard.file_mutations.entry(name.to_string()).or_insert(FileMutationTracker { seq: 0, active: 0 });
                        entry.seq = seq;
                        entry.active += 1;
                        Some(FileRecoveryToken { pending: &self.pending_commits, name: name.to_string(), auth_gen: active_gen, seq })
                    } else {
                        guard.bump_if_tracked(name);
                        None
                    }
                } else {
                    None
                };
                drop(guard);
                self.written.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), etag.clone());
                token
            } else {
                None
            }
        } else {
            None
        };
        Ok((etag, recovery))
    }

    /// [bytes] to an upload's presigned [url]: the store's own address, so no
    /// token goes there.
    async fn store_upload(&self, url: &str, bytes: bytes::Bytes) -> Result<(), Error> {
        let put = self
            .session
            .client()
            .transfer()
            .put(url)
            .header(header::CONTENT_LENGTH, bytes.len())
            .body(bytes)
            .send()
            .await
            .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
        if !put.status().is_success() {
            return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", put.status())));
        }
        Ok(())
    }

    /// Records an upload, asked again while the store has not seen it.
    /// Completing twice is answered alike, so a completion whose answer was
    /// lost is simply asked again.
    async fn complete_for(&self, bound: Option<(u64, u64, bool)>, path: &str, id: &str) -> Result<String, Error> {
        self.complete_with_log_for(bound, path, id).await.map(|(etag, _)| etag)
    }

    async fn complete_with_log(&self, path: &str, id: &str) -> Result<(String, Option<String>), Error> {
        self.complete_with_log_for(None, path, id).await
    }

    async fn complete_with_log_for(&self, bound: Option<(u64, u64, bool)>, path: &str, id: &str) -> Result<(String, Option<String>), Error> {
        let mut wait = Duration::from_millis(500);
        for _ in 0..COMPLETE_TRIES {
            let response = self.send_for(bound, Method::POST, &format!("{path}/uploads/{id}/complete"), |r| r).await?;
            // A bare `409` is the store not showing the upload yet; one with a
            // reason (a snapshot gone stale) is a refusal.
            if response.status() == StatusCode::CONFLICT {
                if let Some(current) = stale_epoch(&response, self.epoch()) {
                    return Err(Error::new(Kind::StaleEpoch(current), "HTTP 409 team_epoch_stale"));
                }
                let highest_version = response.headers().get("x-sync-version").and_then(|v| v.to_str().ok()).and_then(|s| s.parse::<i64>().ok());
                let body = read_limited(response, MAX_JSON).await?;
                if let Some(reason) = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)) {
                    if reason == "sync_version"
                        && let Some(highest) = highest_version
                    {
                        return Err(Error::new(Kind::Version(highest), format!("HTTP 409 sync_version {highest}")));
                    }
                    return Err(Error::new(Kind::Refused(reason.clone()), format!("HTTP 409 {reason}")));
                }
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(Duration::from_secs(8));
                continue;
            }
            let sync_log = header_non_empty(&response, "sync-log");
            return self.written_version_for(bound.map(|(s, _, _)| s), response).await.map(|etag| (etag, sync_log));
        }
        Err(Error::new(Kind::Unreachable, "the store never showed the upload"))
    }

    /// Removes [name], if [if_match] (when given) is its version. `false`
    /// when there was no such file.
    pub async fn delete(&self, name: &str, if_match: Option<&str>) -> Result<bool, Error> {
        let path = self.file_path(name)?;
        let start_session = self
            .session
            .identity()
            .ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?;
        let (start_gen, start_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            (slot.generation, slot.auth.is_some())
        };
        #[cfg(test)]
        if let Some(notify) = self.before_file_lock.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            notify.notify_one();
        }
        let lock = self.file_lock(name);
        let _file_guard = lock.lock().await;
        if self.session.identity() != Some(start_session) {
            return Err(Error::new(Kind::SignedOut, "session changed before delete"));
        }
        let (active_gen, active_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if start_personal_attached && slot.generation != start_gen {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed before delete"));
            }
            (slot.generation, slot.auth.is_some())
        };
        let response = self
            .send_for(
                Some((start_session, active_gen, active_personal_attached)),
                Method::DELETE,
                &path,
                |r| match if_match {
                    Some(etag) => r.header(header::IF_MATCH, quote(etag)),
                    None => r,
                },
            )
            .await?;
        match response.status() {
            StatusCode::NO_CONTENT | StatusCode::NOT_FOUND => {
                if self.session.identity() == Some(start_session) {
                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                    if slot.generation == active_gen {
                        let mut pending = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                        if pending.generation == active_gen {
                            pending.files.retain(|(file_name, _, _, _), _| file_name != name);
                            pending.bump_if_tracked(name);
                        }
                        drop(pending);
                        self.written.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                    }
                }
                Ok(response.status() == StatusCode::NO_CONTENT)
            }
            StatusCode::OK => Err(self.json_for::<Value>(Some(start_session), response, MAX_JSON).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a delete answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    pub async fn list(&self) -> Result<Vec<File>, Error> {
        let response = self.send(Method::GET, &self.app_path()?, |r| r).await?;
        self.json(response).await
    }

    /// [name]'s kept versions, the newest first.
    pub async fn versions(&self, name: &str) -> Result<Vec<Version>, Error> {
        let response = self.send(Method::GET, &format!("{}/versions", self.file_path(name)?), |r| r).await?;
        self.json(response).await
    }

    /// Appends [body] (an age file, up to [`BATCH_MAX`]) to the log, once per
    /// [key] (16 to 64 of `[A-Za-z0-9_-]`): a retry is answered the seq given.
    pub async fn append(&self, key: &str, body: Vec<u8>) -> Result<Appended, Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.append_signed(key, body, None).await;
        };
        let body = bytes::Bytes::from(body);
        let commit_key = (key.to_string(), *blake3::hash(&body).as_bytes());
        let mut expected_id = {
            let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
            (guard.generation == auth_gen)
                .then(|| guard.batches.get(&commit_key).map(|(id, _)| *id))
                .flatten()
        };
        if expected_id.is_some() {
            for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                let Some(entry_id) = expected_id else { break };
                let flushed = auth.flush_pending_versions().await;
                let current_log = auth.signed_log_id(&self.app).await;
                match flushed {
                    Ok(()) => {
                        enum CacheCheck {
                            Hit(Appended),
                            Replaced(u64),
                            Gone,
                        }
                        let check = {
                            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                            if slot.generation == auth_gen {
                                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                if guard.generation == auth_gen {
                                    match guard.batches.get(&commit_key) {
                                        Some((cur_id, appended))
                                            if *cur_id == entry_id && current_log.as_deref() == Some(appended.log.as_str()) =>
                                        {
                                            let (_, appended) = guard.batches.remove(&commit_key).expect("entry present");
                                            CacheCheck::Hit(appended)
                                        }
                                        Some((cur_id, appended))
                                            if current_log.as_deref() == Some(appended.log.as_str()) =>
                                        {
                                            CacheCheck::Replaced(*cur_id)
                                        }
                                        Some((cur_id, _)) if *cur_id == entry_id => {
                                            guard.batches.remove(&commit_key);
                                            CacheCheck::Gone
                                        }
                                        _ => CacheCheck::Gone,
                                    }
                                } else {
                                    CacheCheck::Gone
                                }
                            } else {
                                CacheCheck::Gone
                            }
                        };
                        match check {
                            CacheCheck::Hit(appended) => return Ok(appended),
                            CacheCheck::Replaced(next_id) => {
                                expected_id = Some(next_id);
                                continue;
                            }
                            CacheCheck::Gone => break,
                        }
                    }
                    Err(e) => {
                        if e.kind == Kind::Invalid {
                            let still_valid = {
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.batches.get(&commit_key) {
                                            Some((cur_id, appended))
                                                if *cur_id == entry_id && current_log.as_deref() == Some(appended.log.as_str()) =>
                                            {
                                                Some(appended.clone())
                                            }
                                            Some((cur_id, _)) if *cur_id == entry_id => {
                                                guard.batches.remove(&commit_key);
                                                None
                                            }
                                            _ => None,
                                        }
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                }
                            };
                            if let Some(appended) = still_valid {
                                return Err(e.with_committed(Committed::Batch(appended)));
                            }
                        }
                        return Err(e);
                    }
                }
            }
            self.ensure_personal_gen(auth_gen)?;
        }
        auth.flush_pending_versions().await?;
        self.ensure_personal_gen(auth_gen)?;
        auth.ensure_published(&self.session, false).await?;
        self.ensure_personal_gen(auth_gen)?;
        let sig = auth.sign_batch(&self.app, key, &body).await;
        let res = match self.append_signed_bytes(key, body.clone(), Some(&sig)).await {
            Err(e) if matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                self.ensure_personal_gen(auth_gen)?;
                auth.ensure_published(&self.session, true).await?;
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_batch(&self.app, key, &body).await;
                self.append_signed_bytes(key, body, Some(&sig)).await?
            }
            other => other?,
        };
        self.retain_log_commits(auth_gen, Some(&res.log));
        if let Err(e) = auth.record_batch_written(&self.app, &res.log, res.seq).await {
            if e.kind == Kind::Invalid {
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        let id = guard.next_id();
                        guard.batches.insert(commit_key, (id, res.clone()));
                    }
                }
                return Err(e.with_committed(Committed::Batch(res)));
            }
            return Err(e);
        }
        Ok(res)
    }

    /// [append], signed by its writer ([sig], no version).
    pub async fn append_signed(&self, key: &str, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<Appended, Error> {
        self.append_signed_bytes(key, bytes::Bytes::from(body), sig).await
    }

    async fn append_signed_bytes(&self, key: &str, body: bytes::Bytes, sig: Option<&WriteSig>) -> Result<Appended, Error> {
        if !(16..=64).contains(&key.len()) || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err(Error::new(Kind::Invalid, "not an idempotency key"));
        }
        if body.len() > BATCH_MAX {
            return Err(Error::new(Kind::TooLarge, format!("{} bytes", body.len())));
        }
        let path = format!("{}/log", self.app_path()?);
        let response = self
            .send(Method::POST, &path, |r| {
                signed_by(r, sig)
                    .header("idempotency-key", key)
                    .header(header::CONTENT_TYPE, "application/octet-stream")
                    .header(header::CONTENT_LENGTH, body.len())
                    .body(body.clone())
            })
            .await?;
        self.json(response).await
    }

    /// The log's batches after [after] of [log] (needed past 0), up to
    /// [limit] (homebase's default when `None`).
    pub async fn read_log(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<LogRead, Error> {
        let mut query = format!("after={after}");
        if let Some(log) = log {
            if !valid_log_id(log) {
                return Err(Error::new(Kind::Invalid, "not a log id"));
            }
            query.push_str(&format!("&log={log}"));
        }
        if let Some(limit) = limit {
            query.push_str(&format!("&limit={limit}"));
        }
        let auth = self.personal_auth_with_gen();
        let response = self.send(Method::GET, &format!("{}/log?{query}", self.app_path()?), |r| r).await?;
        if response.status() == StatusCode::GONE {
            // Validated before anything is invalidated: a malformed 410 must
            // not drop recovery entries.
            let compacted_log = header_non_empty(&response, "sync-log");
            if compacted_log.as_deref().is_some_and(|l| !valid_log_id(l)) {
                return Err(Error::new(Kind::Invalid, "a 410 with a malformed Sync-Log"));
            }
            let snapshot_seq = header_non_empty(&response, "sync-snapshot-seq")
                .and_then(|v| v.parse::<i64>().ok())
                .filter(|seq| *seq >= 0)
                .ok_or_else(|| Error::new(Kind::Invalid, "a 410 without a valid Sync-Snapshot-Seq"))?;
            if let Some((auth_gen, auth)) = &auth {
                self.ensure_personal_gen(*auth_gen)?;
                if let Some(ref log_id) = compacted_log {
                    self.retain_log_commits(*auth_gen, Some(log_id));
                }
                auth.flush_pending_versions().await?;
                self.ensure_personal_gen(*auth_gen)?;
            }
            return Ok(LogRead::Compacted { log: compacted_log, snapshot_seq });
        }
        let page: WirePage = self.json_within(response, MAX_LOG_PAGE).await?;
        let mut batches = Vec::with_capacity(page.batches.len());
        for b in page.batches {
            let body = BASE64.decode(&b.body).map_err(|e| Error::new(Kind::Invalid, format!("batch {}: {e}", b.seq)))?;
            if blake3::hash(&body).to_hex().as_str() != b.digest {
                return Err(Error::new(Kind::Invalid, format!("batch {}: digest mismatch", b.seq)));
            }
            batches.push(Batch { seq: b.seq, body, epoch: b.epoch, idempotency_key: b.idempotency_key, signed: b.signed });
        }
        if let Some((auth_gen, auth)) = &auth {
            self.ensure_personal_gen(*auth_gen)?;
            auth.verify_batches(&self.app, page.log.as_deref(), &batches).await?;
            self.ensure_personal_gen(*auth_gen)?;
            self.retain_log_commits(*auth_gen, page.log.as_deref());
        }
        Ok(LogRead::Page { log: page.log, batches, head: page.head, snapshot_seq: page.snapshot_seq, more: page.more })
    }

    /// [from] as the log's snapshot up to [seq]: further than the last, up to
    /// the head. Answers its version.
    pub async fn put_snapshot(&self, seq: i64, from: &Path) -> Result<String, Error> {
        self.put_snapshot_bytes(seq, read_file(from).await?).await
    }

    /// [body] as the log's snapshot up to [seq].
    pub async fn put_snapshot_bytes(&self, seq: i64, body: Vec<u8>) -> Result<String, Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.put_snapshot_signed(seq, body, None).await;
        };
        let body = bytes::Bytes::from(body);
        let commit_key = (seq, *blake3::hash(&body).as_bytes());
        let mut expected_id = {
            let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
            (guard.generation == auth_gen)
                .then(|| guard.snapshots.get(&commit_key).map(|(id, _, _)| *id))
                .flatten()
        };
        if expected_id.is_some() {
            for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                let Some(entry_id) = expected_id else { break };
                let flushed = auth.flush_pending_versions().await;
                let current_log = auth.signed_log_id(&self.app).await;
                match flushed {
                    Ok(()) => {
                        enum CacheCheck {
                            Hit(String),
                            HitAndRecordLog(String, String),
                            NeedReconcile(String),
                            Replaced(u64),
                            Gone,
                        }
                        let check = {
                            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                            if slot.generation == auth_gen {
                                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                if guard.generation == auth_gen {
                                    match guard.snapshots.get(&commit_key) {
                                        Some((cur_id, _, _)) if *cur_id != entry_id => CacheCheck::Replaced(*cur_id),
                                        Some((_, SnapshotLogBinding::Confirmed(k), _)) => match current_log.as_deref() {
                                            Some(cur) if cur == k => {
                                                let (_, _, etag) = guard.snapshots.remove(&commit_key).expect("entry present");
                                                CacheCheck::Hit(etag)
                                            }
                                            Some(_) => {
                                                guard.snapshots.remove(&commit_key);
                                                CacheCheck::Gone
                                            }
                                            None => {
                                                let k = k.clone();
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                CacheCheck::HitAndRecordLog(k, etag)
                                            }
                                        },
                                        Some((_, SnapshotLogBinding::Assumed(k), _)) => {
                                            if current_log.as_deref() == Some(k.as_str()) {
                                                let (_, _, etag) = guard.snapshots.remove(&commit_key).expect("entry present");
                                                CacheCheck::Hit(etag)
                                            } else {
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                CacheCheck::NeedReconcile(etag)
                                            }
                                        }
                                        Some((_, SnapshotLogBinding::Unknown, etag)) => {
                                            CacheCheck::NeedReconcile(etag.clone())
                                        }
                                        None => CacheCheck::Gone,
                                    }
                                } else {
                                    CacheCheck::Gone
                                }
                            } else {
                                CacheCheck::Gone
                            }
                        };
                        match check {
                            CacheCheck::Hit(etag) => return Ok(etag),
                            CacheCheck::HitAndRecordLog(log_id, etag) => {
                                let compatible = match auth
                                    .record_snapshot_if_log_compatible(&self.app, Some(&log_id), seq, &PendingLogObserver { client: self, auth_gen })
                                    .await
                                {
                                    Ok(compatible) => compatible,
                                    Err(e) => {
                                        if e.kind == Kind::Invalid {
                                            let cur_now = auth.signed_log_id(&self.app).await;
                                            let still_valid = {
                                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                                if slot.generation == auth_gen {
                                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                                    if guard.generation == auth_gen {
                                                        match guard.snapshots.get(&commit_key) {
                                                            Some((cur_id, _, _))
                                                                if *cur_id == entry_id
                                                                    && cur_now.as_deref().is_none_or(|c| c == log_id) =>
                                                            {
                                                                Some(etag)
                                                            }
                                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                                guard.snapshots.remove(&commit_key);
                                                                None
                                                            }
                                                            _ => None,
                                                        }
                                                    } else {
                                                        None
                                                    }
                                                } else {
                                                    None
                                                }
                                            };
                                            if let Some(valid_etag) = still_valid {
                                                return Err(e.with_committed(Committed::Snapshot {
                                                    etag: valid_etag,
                                                    seq,
                                                    log: Some(log_id),
                                                }));
                                            }
                                        }
                                        return Err(e);
                                    }
                                };
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.snapshots.get(&commit_key) {
                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                guard.snapshots.remove(&commit_key);
                                                if compatible {
                                                    return Ok(etag);
                                                }
                                                break;
                                            }
                                            Some((cur_id, _, _)) => {
                                                expected_id = Some(*cur_id);
                                                continue;
                                            }
                                            None => break,
                                        }
                                    }
                                }
                                break;
                            }
                            CacheCheck::NeedReconcile(expected_etag) => {
                                self.ensure_personal_gen(auth_gen)?;
                                match self
                                    .reconcile_snapshot_commit(&auth, auth_gen, commit_key, entry_id, &expected_etag)
                                    .await?
                                {
                                    ReconciledSnapshot::Hit(etag, _) => return Ok(etag),
                                    ReconciledSnapshot::Replaced(next_id) => {
                                        expected_id = Some(next_id);
                                        continue;
                                    }
                                    ReconciledSnapshot::Gone => break,
                                }
                            }
                            CacheCheck::Replaced(next_id) => {
                                expected_id = Some(next_id);
                                continue;
                            }
                            CacheCheck::Gone => break,
                        }
                    }
                    Err(e) => {
                        if e.kind == Kind::Invalid {
                            let still_valid = {
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.snapshots.get(&commit_key) {
                                            Some((cur_id, SnapshotLogBinding::Confirmed(k), _))
                                                if *cur_id == entry_id && current_log.as_deref().is_some_and(|cur| cur != k) =>
                                            {
                                                guard.snapshots.remove(&commit_key);
                                                None
                                            }
                                            Some((cur_id, binding, etag)) if *cur_id == entry_id => {
                                                let confirmed_log = match binding {
                                                    SnapshotLogBinding::Confirmed(k) => Some(k.clone()),
                                                    SnapshotLogBinding::Assumed(_) | SnapshotLogBinding::Unknown => None,
                                                };
                                                Some((etag.clone(), confirmed_log))
                                            }
                                            _ => None,
                                        }
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                }
                            };
                            if let Some((etag, log)) = still_valid {
                                return Err(e.with_committed(Committed::Snapshot { etag, seq, log }));
                            }
                        }
                        return Err(e);
                    }
                }
            }
            self.ensure_personal_gen(auth_gen)?;
        }
        auth.flush_pending_versions().await?;
        self.ensure_personal_gen(auth_gen)?;
        auth.ensure_published(&self.session, false).await?;
        self.ensure_personal_gen(auth_gen)?;
        let log_before = auth.signed_log_id(&self.app).await;
        let sig = auth.sign_snapshot(&self.app, seq, &body).await;
        let (etag, resp_log) = match self.put_snapshot_signed_bytes(seq, body.clone(), Some(&sig)).await {
            Err(e) if matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                self.ensure_personal_gen(auth_gen)?;
                auth.ensure_published(&self.session, true).await?;
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_snapshot(&self.app, seq, &body).await;
                self.put_snapshot_signed_bytes(seq, body, Some(&sig)).await?
            }
            other => other?,
        };
        if let Some(ref log_id) = resp_log {
            self.retain_log_commits(auth_gen, Some(log_id));
        }
        if let Err(e) = auth.record_snapshot_written_on(&self.app, resp_log.as_deref(), seq).await {
            if e.kind == Kind::Invalid {
                let committed_log = resp_log.clone();
                let binding = match resp_log {
                    Some(log_id) => SnapshotLogBinding::Confirmed(log_id),
                    None => {
                        let log_after = auth.signed_log_id(&self.app).await;
                        match (log_before, log_after) {
                            (Some(before), Some(after)) if before == after => SnapshotLogBinding::Assumed(before),
                            _ => SnapshotLogBinding::Unknown,
                        }
                    }
                };
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        let id = guard.next_id();
                        guard.snapshots.insert(commit_key, (id, binding, etag.clone()));
                    }
                }
                return Err(e.with_committed(Committed::Snapshot { etag, seq, log: committed_log }));
            }
            return Err(e);
        }
        Ok(etag)
    }

    /// Reconciles an uncommitted-log snapshot recovery entry against `/snapshot`
    /// before reusing or removing it. Network or persistence errors retain the
    /// recovery entry so the committed snapshot remains recoverable on retry.
    async fn reconcile_snapshot_commit(
        &self,
        auth: &PersonalAuth,
        auth_gen: u64,
        commit_key: (i64, [u8; 32]),
        entry_id: u64,
        expected_etag: &str,
    ) -> Result<ReconciledSnapshot, Error> {
        let (seq, ref expected_digest) = commit_key;
        let mut digest = [0u8; 32];
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), Target::HashOnly(&mut digest), None, |response| {
                found = header_non_empty(response, "sync-log")
                    .zip(header_non_empty(response, "sync-seq").and_then(|v| v.parse().ok()))
                    .map(|(log, s)| Snapshot { log, seq: s, signed: Signed::of(response) });
            })
            .await?;
        self.ensure_personal_gen(auth_gen)?;
        match fetched {
            Fetched::Missing => {
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        match guard.snapshots.get(&commit_key) {
                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                guard.snapshots.remove(&commit_key);
                            }
                            Some((cur_id, _, _)) => return Ok(ReconciledSnapshot::Replaced(*cur_id)),
                            None => {}
                        }
                    }
                } else {
                    drop(slot);
                    self.ensure_personal_gen(auth_gen)?;
                }
                Ok(ReconciledSnapshot::Gone)
            }
            Fetched::Saved(remote_etag) => {
                let Some(snap) = found else {
                    return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                };
                let same_snapshot = remote_etag == expected_etag && snap.seq == seq && &digest == expected_digest;
                if let Err(e) = auth.verify_snapshot_digest(&self.app, &snap, &digest).await {
                    self.ensure_personal_gen(auth_gen)?;
                    if e.kind == Kind::Invalid && same_snapshot {
                        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                        if slot.generation == auth_gen && slot.auth.is_some() {
                            let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                            if guard.generation == auth_gen
                                && let Some((cur_id, binding, _)) = guard.snapshots.get_mut(&commit_key)
                                && *cur_id == entry_id
                            {
                                // Keep the entry in `Unknown` until persisting the verified log ID
                                // succeeds so a mismatch with the still-unpersisted `PersonalAuth`
                                // log ID cannot discard the recovery entry on the next retry.
                                *binding = SnapshotLogBinding::Unknown;
                                return Err(e.with_committed(Committed::Snapshot {
                                    etag: expected_etag.to_string(),
                                    seq,
                                    log: Some(snap.log),
                                }));
                            }
                        } else {
                            drop(slot);
                            self.ensure_personal_gen(auth_gen)?;
                        }
                    }
                    return Err(e);
                }
                self.ensure_personal_gen(auth_gen)?;
                self.retain_log_commits(auth_gen, Some(&snap.log));
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        return Ok(match guard.snapshots.get(&commit_key) {
                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                guard.snapshots.remove(&commit_key);
                                if same_snapshot {
                                    ReconciledSnapshot::Hit(expected_etag.to_string(), snap.log)
                                } else {
                                    ReconciledSnapshot::Gone
                                }
                            }
                            Some((cur_id, _, _)) => ReconciledSnapshot::Replaced(*cur_id),
                            None => ReconciledSnapshot::Gone,
                        });
                    }
                }
                drop(slot);
                self.ensure_personal_gen(auth_gen)?;
                Ok(ReconciledSnapshot::Gone)
            }
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }

    /// [put_snapshot_bytes], signed by its writer ([sig], no version).
    pub async fn put_snapshot_signed(&self, seq: i64, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<String, Error> {
        self.put_snapshot_signed_bytes(seq, bytes::Bytes::from(body), sig).await.map(|(etag, _)| etag)
    }

    async fn put_snapshot_signed_bytes(&self, seq: i64, bytes: bytes::Bytes, sig: Option<&WriteSig>) -> Result<(String, Option<String>), Error> {
        let path = format!("{}/snapshot", self.app_path()?);
        let size = bytes.len() as u64;
        if size <= DIRECT_MAX {
            let response = self
                .send(Method::PUT, &format!("{path}?seq={seq}"), |r| {
                    signed_by(r, sig).header(header::CONTENT_TYPE, "application/octet-stream").header(header::CONTENT_LENGTH, size).body(bytes.clone())
                })
                .await?;
            let sync_log = header_non_empty(&response, "sync-log");
            return self.written_version(response).await.map(|etag| (etag, sync_log));
        }
        let response = self.send(Method::POST, &format!("{path}/uploads?seq={seq}"), |r| signed_by(r, sig).json(&serde_json::json!({ "size": size }))).await?;
        let begun: Begun = self.json(response).await?;
        self.store_upload(&begun.url, bytes).await?;
        self.complete_with_log(&path, &begun.id).await
    }

    /// The log's snapshot written to [to]; `None` before there is one.
    pub async fn download_snapshot(&self, to: &Path) -> Result<Option<Snapshot>, Error> {
        if let Some((auth_gen, auth)) = self.personal_auth_with_gen() {
            let lock = self.dest_lock(to);
            let _guard = lock.lock().await;
            let mut part = None;
            let mut found = None;
            let mut digest = [0u8; 32];
            let fetched = self
                .fetch_with(&format!("{}/snapshot", self.app_path()?), Target::FileHashed(to, &mut part, &mut digest), None, |response| {
                    found = header_non_empty(response, "sync-log")
                        .zip(header_non_empty(response, "sync-seq").and_then(|v| v.parse().ok()))
                        .map(|(log, seq)| Snapshot { log, seq, signed: Signed::of(response) });
                })
                .await?;
            return match fetched {
                Fetched::Missing => {
                    self.ensure_personal_gen(auth_gen)?;
                    Ok(None)
                }
                Fetched::Saved(_) => {
                    self.ensure_personal_gen(auth_gen)?;
                    let Some(snap) = found else {
                        return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                    };
                    auth.verify_snapshot_digest(&self.app, &snap, &digest).await?;
                    self.ensure_personal_gen(auth_gen)?;
                    self.retain_log_commits(auth_gen, Some(&snap.log));
                    let mut staged = part.ok_or_else(|| Error::new(Kind::Invalid, "missing staged snapshot file"))?;
                    tokio::fs::rename(staged.path(), to).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", to.display())))?;
                    staged.disarm();
                    Ok(Some(snap))
                }
                Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
            };
        }
        self.snapshot_into(Target::File(to)).await
    }

    /// The log's snapshot and its bytes; `None` before there is one.
    pub async fn download_snapshot_bytes(&self) -> Result<Option<(Snapshot, Vec<u8>)>, Error> {
        let mut body = Vec::new();
        let auth = self.personal_auth_with_gen();
        let Some(snap) = self.snapshot_into(Target::Memory(&mut body)).await? else {
            if let Some((auth_gen, _)) = auth {
                self.ensure_personal_gen(auth_gen)?;
            }
            return Ok(None);
        };
        if let Some((auth_gen, auth)) = auth {
            self.ensure_personal_gen(auth_gen)?;
            auth.verify_snapshot(&self.app, &snap, &body).await?;
            self.ensure_personal_gen(auth_gen)?;
            self.retain_log_commits(auth_gen, Some(&snap.log));
        }
        Ok(Some((snap, body)))
    }

    async fn snapshot_into(&self, into: Target<'_>) -> Result<Option<Snapshot>, Error> {
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), into, None, |response| {
                found = header_non_empty(response, "sync-log")
                    .zip(header_non_empty(response, "sync-seq").and_then(|v| v.parse().ok()))
                    .map(|(log, seq)| Snapshot { log, seq, signed: Signed::of(response) });
            })
            .await?;
        match fetched {
            Fetched::Missing => Ok(None),
            Fetched::Saved(_) => found.map(Some).ok_or_else(|| Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq")),
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }

    /// What other devices write, as long as it is read: connected again after
    /// a drop, waiting longer each time up to a minute. Ends when signed out.
    pub fn events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("sync")
    }

    /// A team's changes of members and key ([Event::Team]), as [events].
    pub fn team_events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("team")
    }

    fn events_on(self: Arc<Self>, chan: &'static str) -> impl Stream<Item = Event> + Send + 'static {
        struct Listen<S: Store> {
            chan: &'static str,
            sync: Arc<SyncClient<S>>,
            body: Option<Body>,
            buffer: Vec<u8>,
            wait: Duration,
            /// Waited before the next connection, once [Event::Lost] is out.
            retry: Option<Duration>,
        }
        let start = Listen { chan, sync: self, body: None, buffer: Vec::new(), wait: Duration::from_secs(1), retry: None };
        futures_util::stream::unfold(start, |mut st| async move {
            if let Some(wait) = st.retry.take() {
                tokio::time::sleep(wait).await;
            }
            loop {
                if let Some(event) = take_event(&mut st.buffer) {
                    if let Some(event) = st.sync.heard(&event) {
                        return Some((event, st));
                    }
                    continue;
                }
                let Some(body) = st.body.as_mut() else {
                    match st.sync.listen(st.chan).await {
                        Ok(body) => {
                            st.body = Some(body);
                            st.buffer.clear();
                            st.wait = Duration::from_secs(1);
                            return Some((Event::Connected, st));
                        }
                        Err(e) if e.kind == Kind::SignedOut => return None,
                        Err(e) => {
                            let wait = st.wait;
                            st.wait = (st.wait * 2).min(MAX_BACKOFF);
                            st.retry = Some(wait);
                            return Some((Event::Lost(e.to_string()), st));
                        }
                    }
                };
                let lost = match body.next().await {
                    Some(Ok(chunk)) => {
                        st.buffer.extend_from_slice(&chunk);
                        continue;
                    }
                    Some(Err(e)) => format!("the event stream failed: {e}"),
                    None => "the event stream ended".to_string(),
                };
                st.body = None;
                let wait = st.wait;
                st.wait = (st.wait * 2).min(MAX_BACKOFF);
                st.retry = Some(wait);
                return Some((Event::Lost(lost), st));
            }
        })
    }

    async fn listen(&self, chan: &str) -> Result<Body, Error> {
        let response = self.send(Method::GET, &format!("/sse/listen?chan={chan}"), |r| r.header(header::ACCEPT, "text/event-stream")).await?;
        let stream = response.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|v| v.starts_with("text/event-stream"));
        if response.status() != StatusCode::OK {
            return Err(refusal(response).await);
        }
        if !stream {
            // `{"code": 2}`, or another refusal as JSON.
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "not an event stream")));
        }
        Ok(Box::pin(response.bytes_stream()))
    }

    /// An event of this app (of this team, or of none) written by another
    /// device.
    fn heard(&self, value: &Value) -> Option<Event> {
        let team = value["team"].as_str().map(|t| canonical(t).unwrap_or_default());
        if team.as_deref() != self.team.as_ref().map(|t| t.id.as_str()) {
            return None;
        }
        if value["event"] == "team" {
            return value["change"].as_str().map(|c| Event::Team { change: c.to_string() });
        }
        if value["app"] != self.app.as_str() {
            return None;
        }
        if value["event"] == "log" {
            return value["seq"].as_i64().map(|seq| Event::Log { seq });
        }
        if value["event"] != "sync" {
            return None;
        }
        let name = value["name"].as_str()?.to_string();
        let etag = value["etag"].as_str().map(str::to_string);
        let own = etag.is_some() && self.written.lock().unwrap_or_else(|e| e.into_inner()).get(&name) == etag.as_ref();
        (!own).then_some(Event::Changed { name, etag })
    }

    async fn fetch_file(&self, path: &str, name: &str, to: &Path, known: Option<&str>, enforce_monotonic: bool) -> Result<Fetched, Error> {
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.fetch_with(path, Target::File(to), known, |_| {}).await;
        };
        let lock = self.dest_lock(to);
        let _guard = lock.lock().await;
        let mut part = None;
        let mut signed = None;
        let mut digest = [0u8; 32];
        let fetched = self.fetch_with(path, Target::FileHashed(to, &mut part, &mut digest), known, |r| signed = Signed::of(r)).await?;
        self.ensure_personal_gen(auth_gen)?;
        if let Fetched::Saved(_) = &fetched {
            auth.verify_file_digest(&self.app, name, &digest, signed.as_ref(), enforce_monotonic).await?;
            self.ensure_personal_gen(auth_gen)?;
            #[cfg(test)]
            {
                let hook = self.after_verify_before_rename.lock().unwrap_or_else(|e| e.into_inner()).clone();
                if let Some(h) = hook {
                    h().await;
                }
            }
            let mut staged = part.ok_or_else(|| Error::new(Kind::Invalid, "missing staged file"))?;
            tokio::fs::rename(staged.path(), to).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", to.display())))?;
            staged.disarm();
        }
        Ok(fetched)
    }

    /// [fetch_file], [answered] shown homebase's answer before its body is read.
    async fn fetch_with(&self, path: &str, into: Target<'_>, known: Option<&str>, answered: impl FnOnce(&reqwest::Response)) -> Result<Fetched, Error> {
        let response = self
            .send(Method::GET, path, |r| match known {
                Some(etag) => r.header(header::IF_NONE_MATCH, quote(etag)),
                None => r,
            })
            .await?;
        let status = response.status();
        if status == StatusCode::NOT_MODIFIED {
            return Ok(Fetched::Unchanged);
        }
        if status == StatusCode::NOT_FOUND {
            return Ok(Fetched::Missing);
        }
        if status != StatusCode::OK && status != StatusCode::FOUND {
            return Err(refusal(response).await);
        }
        let Some(etag) = self.etag(&response) else {
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a file without its version")));
        };
        answered(&response);
        let body = if status == StatusCode::FOUND {
            let location = response
                .headers()
                .get(header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| Error::new(Kind::Invalid, "a redirect without Location"))?
                .to_string();
            // The store's own address: no token goes there.
            let stored = self
                .session
                .client()
                .transfer()
                .get(&location)
                .send()
                .await
                .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
            if !stored.status().is_success() {
                return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", stored.status())));
            }
            stored
        } else {
            response
        };
        match into {
            Target::File(to) => {
                let lock = self.dest_lock(to);
                let _guard = lock.lock().await;
                save(body, to).await?
            }
            Target::FileHashed(to, part, digest) => {
                let (file, guard) = create_part(to).await?;
                let part_path = guard.path().to_path_buf();
                *part = Some(guard);
                *digest = save_hashed(body, file, &part_path).await?;
            }
            Target::HashOnly(digest) => *digest = hash_stream(body).await?,
            Target::Memory(buffer) => *buffer = read_limited(body, MAX_READ as usize).await?,
        }
        Ok(Fetched::Saved(etag))
    }

    /// The version a write's `204` names.
    async fn written_version(&self, response: reqwest::Response) -> Result<String, Error> {
        self.written_version_for(None, response).await
    }

    async fn written_version_for(&self, expected_session: Option<u64>, response: reqwest::Response) -> Result<String, Error> {
        match response.status() {
            StatusCode::NO_CONTENT => self.etag(&response).ok_or_else(|| Error::new(Kind::Invalid, "a write without its version")),
            StatusCode::OK => Err(self.json_for::<Value>(expected_session, response, MAX_JSON).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a write answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    async fn json<T: DeserializeOwned>(&self, response: reqwest::Response) -> Result<T, Error> {
        self.json_within(response, MAX_JSON).await
    }

    async fn json_within<T: DeserializeOwned>(&self, response: reqwest::Response, max: usize) -> Result<T, Error> {
        self.json_for(None, response, max).await
    }

    async fn json_for<T: DeserializeOwned>(
        &self,
        expected_session: Option<u64>,
        response: reqwest::Response,
        max: usize,
    ) -> Result<T, Error> {
        let status = response.status();
        if !status.is_success() {
            return Err(refusal(response).await);
        }
        let url = response.url().path().to_string();
        let body = read_limited(response, max).await?;
        match crate::unwrap(&url, status.as_u16(), &body) {
            Ok(data) => serde_json::from_value(data).map_err(|e| Error::new(Kind::Invalid, format!("{url}: {e}"))),
            Err(e) if e.failure == Failure::Rejected => {
                self.session.forget_for(expected_session, format!("homebase refused the session at {url}: {}", e.detail)).await;
                Err(Error::new(Kind::SignedOut, e.detail))
            }
            Err(e) if e.failure == Failure::Unreachable => Err(Error::new(Kind::Unreachable, e.detail)),
            Err(e) => Err(Error::new(Kind::Refused(String::new()), e.detail)),
        }
    }

    /// Sends a request; a `503` homebase asks to be retried shortly
    /// (`Retry-After` up to [`RETRY_AFTER_MAX`]) is sent once more, when the
    /// request may be: any but a `POST` without an `Idempotency-Key`.
    async fn send(
        &self,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        self.send_for(None, method, path, build).await
    }

    async fn send_for(
        &self,
        bound: Option<(u64, u64, bool)>,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        let client = self.session.client();
        let url = client.api_url(path);
        let mut again = true;
        loop {
            if let Some((expected_session, expected_personal_gen, personal_was_attached)) = bound
                && (self.session.identity() != Some(expected_session)
                    || (personal_was_attached && self.personal_generation() != expected_personal_gen))
            {
                return Err(Error::new(Kind::SignedOut, "session changed during request"));
            }
            let token_res = match bound {
                Some((expected_session, _, _)) => self.session.access_token_for(expected_session).await,
                None => self.session.access_token().await,
            };
            let token = token_res.map_err(|e| match e.failure {
                Failure::Rejected => Error::new(Kind::SignedOut, e.detail),
                _ => Error::new(Kind::Unreachable, e.detail),
            })?;
            if let Some((_, expected_personal_gen, true)) = bound
                && self.personal_generation() != expected_personal_gen
            {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed during request"));
            }
            let mut request = build(client.transfer().request(method.clone(), &url).bearer_auth(token));
            if let Some(epoch) = self.epoch() {
                request = request.header("x-team-epoch", epoch);
            }
            let retryable = method != Method::POST || request.try_clone().and_then(|r| r.build().ok()).is_some_and(|r| r.headers().contains_key("idempotency-key"));
            let sent = now_ms();
            let response = request.send().await.map_err(|e| Error::new(Kind::Unreachable, unreachable(&url, e).detail))?;
            self.clock.record(sent, now_ms(), &response);
            let wait = (response.status() == StatusCode::SERVICE_UNAVAILABLE)
                .then(|| response.headers().get(header::RETRY_AFTER)?.to_str().ok()?.parse::<u64>().ok())
                .flatten()
                .map(Duration::from_secs)
                .filter(|w| *w <= RETRY_AFTER_MAX);
            match wait {
                Some(wait) if again && retryable => {
                    again = false;
                    tokio::time::sleep(wait).await;
                }
                _ => return Ok(response),
            }
        }
    }

    fn etag(&self, response: &reqwest::Response) -> Option<String> {
        let tag = response.headers().get(header::ETAG)?.to_str().ok()?;
        Some(tag.trim_matches('"').to_string()).filter(|t| !t.is_empty())
    }

    /// A bodiless `200` without the `ETag` every file answer carries: homebase
    /// refusing the session, or something in front of it (a captive portal, a
    /// proxy). Only homebase's own word, read from a body, signs out.
    async fn without_version(&self) -> Error {
        match self.list().await {
            Err(e) => e,
            Ok(_) => Error::new(Kind::Unreachable, "an answer without its version"),
        }
    }

    fn app_segment(&self) -> Result<&str, Error> {
        valid(&self.app, 64, false).then_some(self.app.as_str()).ok_or_else(|| Error::new(Kind::Invalid, "not an app name"))
    }

    fn app_path(&self) -> Result<String, Error> {
        let app = self.app_segment()?;
        match &self.team {
            None => Ok(format!("/v2/sync/{app}")),
            Some(t) if team_bytes(&t.id).is_ok() => Ok(format!("/v2/teams/{}/sync/{app}", t.id)),
            Some(_) => Err(Error::new(Kind::Invalid, "not a team id")),
        }
    }

    fn file_path(&self, name: &str) -> Result<String, Error> {
        if !valid(name, 128, true) {
            return Err(Error::new(Kind::Invalid, "not a file name"));
        }
        Ok(format!("{}/{name}", self.app_path()?))
    }
}

/// Homebase's names: `[a-z0-9._-]` for an app, uppercase too for a file, not
/// starting with a dot.
fn valid(s: &str, max: usize, upper: bool) -> bool {
    !s.is_empty()
        && s.len() <= max
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-') || (upper && b.is_ascii_uppercase()))
}

fn valid_log_id(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

fn quote(etag: &str) -> String {
    format!("\"{etag}\"")
}

fn header_non_empty(response: &reqwest::Response, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn condition_on(request: reqwest::RequestBuilder, condition: &Condition) -> reqwest::RequestBuilder {
    match condition {
        Condition::Match(etag) => request.header(header::IF_MATCH, quote(etag)),
        Condition::Absent => request.header(header::IF_NONE_MATCH, "*"),
    }
}

/// A refusal by its status; a `403` by homebase's `reason`.
async fn refusal(response: reqwest::Response) -> Error {
    let status = response.status();
    let kind = match status {
        StatusCode::PRECONDITION_FAILED => Kind::Changed,
        StatusCode::NOT_FOUND => Kind::Missing,
        StatusCode::UNSUPPORTED_MEDIA_TYPE => Kind::NotAge,
        StatusCode::TOO_MANY_REQUESTS => Kind::Busy,
        StatusCode::UNAUTHORIZED => Kind::SignedOut,
        StatusCode::FORBIDDEN | StatusCode::CONFLICT | StatusCode::UNPROCESSABLE_ENTITY | StatusCode::PAYLOAD_TOO_LARGE => {
            let current = response.headers().get("x-team-epoch").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok());
            let highest = response.headers().get("x-sync-version").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok());
            let body = read_limited(response, MAX_JSON).await.unwrap_or_default();
            let reason = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)).unwrap_or_default();
            if let (STALE_EPOCH, Some(current)) = (reason.as_str(), current) {
                return Error::new(Kind::StaleEpoch(current), format!("HTTP {status} {STALE_EPOCH}"));
            }
            if let ("sync_version", Some(highest)) = (reason.as_str(), highest) {
                return Error::new(Kind::Version(highest), format!("HTTP {status} sync_version"));
            }
            // A bare 413: over what one request carries, not the plan's.
            if status == StatusCode::PAYLOAD_TOO_LARGE && reason.is_empty() {
                return Error::new(Kind::TooLarge, format!("HTTP {status}"));
            }
            return Error::new(Kind::Refused(reason.clone()), format!("HTTP {status} {reason}"));
        }
        s if s.is_server_error() => Kind::Unreachable,
        _ => Kind::Invalid,
    };
    Error::new(kind, format!("HTTP {status}"))
}

/// Homebase's reason for a team's write under a replaced key.
const STALE_EPOCH: &str = "team_epoch_stale";

/// The current epoch a team's `409` names (`X-Team-Epoch`), when it names
/// one other than the request's: a write under a replaced key.
fn stale_epoch(response: &reqwest::Response, sent: Option<i64>) -> Option<i64> {
    let current = response.headers().get("x-team-epoch")?.to_str().ok()?.parse().ok()?;
    (Some(current) != sent).then_some(current)
}

enum ReconciledSnapshot {
    Hit(String, String),
    Replaced(u64),
    Gone,
}

enum DetachedReconcile {
    Recovered(String),
    Conflicted,
    Gone,
}

#[derive(Clone, Copy)]
enum DownloadVerify {
    File,
    BlobStrict,
    BlobRetained,
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

/// Exclusively creates a unique temporary file in [to]'s directory and arms a
/// [`PartGuard`] only after creation succeeds.
async fn create_part(to: &Path) -> Result<(tokio::fs::File, PartGuard), Error> {
    let dir = to.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    let base = to.file_name().and_then(|n| n.to_str()).unwrap_or("download");
    for _ in 0..16 {
        let mut rnd = [0u8; 8];
        getrandom::fill(&mut rnd).map_err(|e| Error::new(Kind::Invalid, format!("random temp name: {e}")))?;
        let mut suffix = String::with_capacity(16);
        for b in rnd {
            use std::fmt::Write as _;
            let _ = write!(suffix, "{b:02x}");
        }
        let path = dir.join(format!(".{base}.{suffix}.part"));
        match tokio::fs::OpenOptions::new().write(true).create_new(true).open(&path).await {
            Ok(file) => return Ok((file, PartGuard::new(path))),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(Error::new(Kind::Invalid, format!("{}: {e}", path.display()))),
        }
    }
    Err(Error::new(Kind::Invalid, format!("{}: could not allocate unique temp file", to.display())))
}

async fn read_file(from: &Path) -> Result<Vec<u8>, Error> {
    tokio::fs::read(from).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", from.display())))
}

async fn read_limited(mut response: reqwest::Response, max: usize) -> Result<Vec<u8>, Error> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))? {
        body.extend_from_slice(&chunk);
        if body.len() > max {
            return Err(Error::new(Kind::Invalid, "answer too large"));
        }
    }
    Ok(body)
}

/// Removes an exclusively created temporary file on drop (error or
/// cancellation) unless disarmed after its atomic rename succeeds.
struct PartGuard(Option<PathBuf>);

impl PartGuard {
    fn new(path: PathBuf) -> Self {
        Self(Some(path))
    }

    fn path(&self) -> &Path {
        self.0.as_deref().expect("part guard armed")
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for PartGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// [response]'s body into [to], through a unique file beside it renamed into
/// place: a download cut short leaves the old file and removes the temp file.
async fn save(response: reqwest::Response, to: &Path) -> Result<(), Error> {
    let (file, mut part) = create_part(to).await?;
    let part_path = part.path().to_path_buf();
    save_hashed(response, file, &part_path).await?;
    tokio::fs::rename(part.path(), to).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", to.display())))?;
    part.disarm();
    Ok(())
}

/// Streams [response]'s body into an already-created [file] at [part] and
/// returns its blake3 digest.
async fn save_hashed(response: reqwest::Response, mut file: tokio::fs::File, part: &Path) -> Result<[u8; 32], Error> {
    let io = |e: std::io::Error| Error::new(Kind::Invalid, format!("{}: {e}", part.display()));
    let mut stream = response.bytes_stream();
    let mut hasher = blake3::Hasher::new();
    let mut written = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))?;
        written += chunk.len() as u64;
        if written > MAX_READ {
            return Err(Error::new(Kind::TooLarge, "the file outgrew homebase's limit"));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await.map_err(io)?;
    }
    file.flush().await.map_err(io)?;
    Ok(*hasher.finalize().as_bytes())
}

async fn hash_stream(response: reqwest::Response) -> Result<[u8; 32], Error> {
    let mut stream = response.bytes_stream();
    let mut hasher = blake3::Hasher::new();
    let mut read_bytes = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))?;
        read_bytes += chunk.len() as u64;
        if read_bytes > MAX_READ {
            return Err(Error::new(Kind::TooLarge, "the file outgrew homebase's limit"));
        }
        hasher.update(&chunk);
    }
    Ok(*hasher.finalize().as_bytes())
}

/// The next complete event in [buffer] (its `data:` lines as JSON), taken
/// out; comments (`: ping`) and other fields are skipped.
fn take_event(buffer: &mut Vec<u8>) -> Option<Value> {
    loop {
        let end = buffer.windows(2).position(|w| w == b"\n\n")?;
        let block: Vec<u8> = buffer.drain(..end + 2).collect();
        let text = String::from_utf8_lossy(&block);
        let data: String = text.lines().filter_map(|l| l.strip_prefix("data:")).map(str::trim_start).collect::<Vec<_>>().join("\n");
        if data.is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str(&data) {
            return Some(value);
        }
    }
}

#[cfg(test)]
mod tests;
