//! Signed personal LK Cloud sync: reuses the user's [`AccountKey`] Ed25519
//! signing key so a compromised homebase cannot forge writes, strip
//! signatures or roll a file back to an older version.
//!
//! Log batches and snapshots need no replay or rollback watermark: every op
//! in them carries its HLC inside the signed body and is applied only where
//! it wins, so a batch or snapshot sent again (or an older one) changes
//! nothing a newer op set. Homebase may make a log anew from seq 1 (a lapsed
//! plan's sync removed); nothing here depends on its seqs going on.

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, RwLock};

use crate::session::{Session, Store};
use crate::sync::{Batch, Error, Kind, Signed, Snapshot, WriteSig};
use crate::team::crypto::{self, KEY_LEN};
use crate::team::identity::AccountKey;
use crate::team::{TeamClient, TeamError};

const VERSIONS_FORMAT: u32 = 2;
/// The sync key file, signed though not an app file.
const KEY_FILE: &str = "identity.age";
/// Legacy v1 log-blob prefix, used ONLY when migrating v1 persisted JSON.
// TODO(migration): remove once v1 personal versions JSON is no longer present.
const LEGACY_BLOB_PREFIX: &str = "op-";
/// How long after reading the account key file it is not read again for a
/// signature this key does not know.
const KEY_REFRESH_EVERY: Duration = Duration::from_secs(30);

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Persists [`PersonalVersions`] JSON locally before any accepted write or
/// verified read advances what it records.
pub trait VersionKeeper: Send + Sync + 'static {
    fn save(&self, json: String) -> BoxFuture<'_, Result<(), String>>;
}

/// The account key as its file holds it now, read again when another device
/// may have rotated it; `None` when it cannot be read.
pub trait KeySource: Send + Sync + 'static {
    fn fetch(&self) -> BoxFuture<'_, Option<AccountKey>>;
}

/// Live log observations a snapshot's log binding is ordered against, called
/// synchronously while the versions lock is held.
pub trait LogObserver {
    /// Records [log] as the one observed; `false` when a different log already is.
    fn commit(&self, log: &str) -> Result<bool, Error>;
    /// Whether [log] is still the one observed.
    fn confirm(&self, log: &str) -> Result<bool, Error>;
}

/// What this device has seen signed in one personal LK Cloud account, kept
/// on-device: what an unsigned answer is refused for, and each file's
/// highest version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalVersions {
    v: u32,
    /// Highest verified or written version per `"{app}/{name}"`, of app files
    /// and the sync key file; 0 for one seen signed only in its history.
    files: BTreeMap<String, i64>,
    /// Apps an app file (not the sync key file, not a log blob) was seen or
    /// written signed in: an unsigned answer for any of their files is
    /// refused.
    signed_apps: BTreeSet<String>,
    /// Apps a log blob was seen or written signed in.
    signed_blobs: BTreeSet<String>,
    /// Lowest log seq a signed batch or snapshot was seen or written at, per
    /// app: unsigned ones at or past it are refused, legacy ones before it
    /// stay readable during migration, in that log only.
    signed_log_from: BTreeMap<String, i64>,
    /// The log [signed_log_from] counts in, per app: a log made anew after
    /// signing began holds no unsigned batch.
    signed_log_ids: BTreeMap<String, String>,
    /// Apps a signed snapshot was seen or written in.
    signed_snapshots: BTreeSet<String>,
}

/// [`PersonalVersions`] as stored, also as earlier builds wrote it.
#[derive(Deserialize)]
struct Stored {
    v: u32,
    #[serde(default)]
    files: BTreeMap<String, i64>,
    #[serde(default)]
    signed_apps: BTreeSet<String>,
    #[serde(default)]
    signed_blobs: BTreeSet<String>,
    #[serde(default)]
    signed_log_from: BTreeMap<String, i64>,
    #[serde(default)]
    signed_snapshots: BTreeSet<String>,
    #[serde(default)]
    signed_log_ids: BTreeMap<String, String>,
    // TODO(migration): remove the fields below once devices have saved their
    // versions again (each save drops them).
    #[serde(default)]
    signed_files: BTreeSet<String>,
    #[serde(default)]
    signed_logs: BTreeSet<String>,
    #[serde(default)]
    snapshots: BTreeMap<String, i64>,
}

impl Default for PersonalVersions {
    fn default() -> Self {
        Self {
            v: VERSIONS_FORMAT,
            files: BTreeMap::new(),
            signed_apps: BTreeSet::new(),
            signed_blobs: BTreeSet::new(),
            signed_log_from: BTreeMap::new(),
            signed_log_ids: BTreeMap::new(),
            signed_snapshots: BTreeSet::new(),
        }
    }
}

impl PersonalVersions {
    pub fn from_json(json: &str) -> Result<Self, Error> {
        if json.trim().is_empty() {
            return Ok(Self::default());
        }
        let stored: Stored = serde_json::from_str(json).map_err(|e| Error::new(Kind::Invalid, format!("personal versions: {e}")))?;
        if stored.v != 1 && stored.v != VERSIONS_FORMAT {
            return Err(Error::new(Kind::Invalid, format!("personal versions: unsupported version {}", stored.v)));
        }
        let mut out = Self {
            v: VERSIONS_FORMAT,
            files: BTreeMap::new(),
            signed_apps: stored.signed_apps,
            signed_blobs: stored.signed_blobs,
            signed_log_from: stored.signed_log_from,
            signed_log_ids: stored.signed_log_ids,
            signed_snapshots: stored.signed_snapshots,
        };
        if stored.v == 1 {
            // TODO(migration): drop v1 migration branch once devices have saved v2.
            for (key, version) in stored.files {
                out.take_legacy_file(key, version);
            }
            for key in stored.signed_files {
                out.take_legacy_file(key, 0);
            }
        } else {
            out.files = stored.files;
        }
        for app in stored.signed_logs {
            let from = out.signed_log_from.entry(app).or_insert(1);
            *from = (*from).min(1);
        }
        out.signed_snapshots.extend(stored.snapshots.into_keys());
        Ok(out)
    }

    /// An entry of a v1 build's `files` or `signed_files`, which did not
    /// separate write-once log blobs from ordinary mutable files.
    // TODO(migration): remove once v1 personal versions JSON is no longer present.
    fn take_legacy_file(&mut self, key: String, version: i64) {
        if !self.files.contains_key(&key)
            && let Some((app, name)) = key.split_once('/')
            && name.starts_with(LEGACY_BLOB_PREFIX)
            && matches!(classify_legacy_op_file(name, version), LegacyOpKind::Blob)
        {
            self.signed_blobs.insert(app.to_string());
            return;
        }
        let entry = self.files.entry(key).or_insert(0);
        *entry = (*entry).max(version);
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("plain JSON")
    }

    pub fn file_version(&self, app: &str, name: &str) -> i64 {
        self.files.get(&file_key(app, name)).copied().unwrap_or(0)
    }

    /// Whether an unsigned answer for ordinary mutable file [name] of [app] is
    /// refused here; with no [name], for the app's files in general.
    pub fn requires_signature(&self, app: &str, name: Option<&str>) -> bool {
        let Some(name) = name else {
            return self.signed_apps.contains(app);
        };
        // Signing the sync key file or a log blob does not lock out the
        // app's earlier unsigned backups, while a signed app file locks out
        // every unsigned one.
        self.signed_apps.contains(app) || self.files.contains_key(&file_key(app, name))
    }

    /// Whether an unsigned answer on the write-once log-blob path of [app] is
    /// refused here.
    pub fn blob_requires_signature(&self, app: &str) -> bool {
        self.signed_apps.contains(app) || self.signed_blobs.contains(app)
    }

    /// Ordinary mutable file [name] of [app] seen or written signed, at
    /// [version] (0: only in its history, which leaves the highest where it is).
    fn saw_file(&mut self, app: &str, name: &str, version: i64) {
        // The sync key file signed during migration must not lock out the
        // app's earlier unsigned backups; an app file does.
        if name != KEY_FILE {
            self.signed_apps.insert(app.to_string());
        }
        let entry = self.files.entry(file_key(app, name)).or_insert(0);
        *entry = (*entry).max(version);
    }

    /// A write-once log blob of [app] seen or written signed: skips per-file
    /// version watermarks so `files` stays bounded.
    fn saw_blob(&mut self, app: &str) {
        self.signed_blobs.insert(app.to_string());
    }

    fn log_signed_from(&self, app: &str) -> Option<i64> {
        self.signed_log_from.get(app).copied()
    }

    /// A signed batch or snapshot at [seq] of [log] (`None`: the log the
    /// last one was of).
    fn mark_log_signed_at(&mut self, app: &str, log: Option<&str>, seq: i64) {
        let entry = self.signed_log_from.entry(app.to_string()).or_insert(seq);
        *entry = (*entry).min(seq);
        let Some(log) = log else { return };
        match self.signed_log_ids.get(app) {
            Some(known) if known == log => {}
            // Made anew since signing began: nothing in it is legacy.
            Some(_) => {
                self.signed_log_from.insert(app.to_string(), 1);
                self.signed_log_ids.insert(app.to_string(), log.to_string());
            }
            None => {
                self.signed_log_ids.insert(app.to_string(), log.to_string());
            }
        }
    }

    /// Whether an unsigned batch or snapshot at [seq] of [log] is refused.
    fn log_requires_signature(&self, app: &str, log: Option<&str>, seq: i64) -> bool {
        let Some(from) = self.log_signed_from(app) else { return false };
        let other_log = matches!((self.signed_log_ids.get(app), log), (Some(known), Some(log)) if known != log);
        seq >= from || other_log
    }

    fn saw_snapshot(&mut self, app: &str, log: Option<&str>, seq: i64) {
        self.mark_log_signed_at(app, log, seq);
        self.signed_snapshots.insert(app.to_string());
    }

    fn snapshot_requires_signature(&self, app: &str, log: &str, seq: i64) -> bool {
        self.signed_snapshots.contains(app) || self.log_requires_signature(app, Some(log), seq)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refresh {
    Rotated,
    Unchanged,
    /// Read too recently, or could not be.
    NotRead,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LegacyOpKind {
    Blob,
    Mutable,
}

/// Classifies a v1 `op-*` entry where v1 did not distinguish write-once log
/// blobs from ordinary mutable files.
///
/// Write-once log blobs are written once (`version <= 1`) and named
/// `op-<hex>.age` (keyed blake3 digest) or `op-<hex>-<hex>.age` (device/HLC
/// hex). Entries with `version > 1` or a non-hex stem (e.g. `op-notes.age`)
/// are classified as ordinary mutable files so their version watermarks are
/// preserved.
// TODO(migration): remove once v1 personal versions JSON is no longer present.
fn classify_legacy_op_file(name: &str, version: i64) -> LegacyOpKind {
    if version > 1 {
        return LegacyOpKind::Mutable;
    }
    let Some(stem) = name.strip_prefix(LEGACY_BLOB_PREFIX).and_then(|s| s.strip_suffix(".age")) else {
        return LegacyOpKind::Mutable;
    };
    let is_hex = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit());
    let is_blob_stem = match stem.split_once('-') {
        Some((a, b)) => is_hex(a) && is_hex(b),
        None => is_hex(stem),
    };
    if is_blob_stem { LegacyOpKind::Blob } else { LegacyOpKind::Mutable }
}

fn file_key(app: &str, name: &str) -> String {
    format!("{app}/{name}")
}

fn digest(body: &[u8]) -> [u8; KEY_LEN] {
    *blake3::hash(body).as_bytes()
}

/// Said when an unsigned retained blob's bytes do not hold its binding.
pub const RETAINED_MISMATCH: &str = "retained pre-signing blob content mismatch";

/// What an unsigned pre-signing blob's bytes must hold before they are used:
/// a retained answer without one is never accepted.
#[derive(Clone, Copy)]
pub enum RetainedBinding<'a> {
    /// The bytes' blake3, from a verified batch or snapshot.
    Digest([u8; KEY_LEN]),
    /// Whether the bytes hold the caller's locally known content.
    Content(&'a (dyn Fn(&[u8]) -> bool + Send + Sync)),
}

impl RetainedBinding<'_> {
    pub fn holds(&self, body: &[u8]) -> bool {
        match self {
            Self::Digest(d) => digest(body) == *d,
            Self::Content(matches) => matches(body),
        }
    }
}

fn untrusted(what: impl Into<String>) -> Error {
    Error::new(Kind::Untrusted, what)
}

fn not_saved(e: String) -> Error {
    Error::new(Kind::Invalid, format!("personal versions not saved: {e}"))
}

struct VersionState {
    data: PersonalVersions,
    /// True when a committed remote write advanced `data` in memory but
    /// `VersionKeeper::save` has not yet succeeded for it.
    dirty: bool,
    /// Write-once log blobs observed or written with a signature on this auth
    /// instance (`"{app}/{name}"`), kept in memory so `PersonalVersions` JSON
    /// stays bounded while blocking unsigned replacements of signed blobs.
    seen_signed_blobs: BTreeSet<String>,
    /// Log identifiers actively recorded or verified under this auth instance,
    /// per app, so a detached snapshot recovery probe cannot rewind a log
    /// binding already recorded under the same auth generation.
    recorded_log_ids: BTreeMap<String, String>,
}

/// Signs outgoing writes and verifies incoming reads for one user's personal
/// LK Cloud sync space (`epoch = 0`, `owner = account.user_id()`).
pub struct PersonalAuth {
    key: RwLock<AccountKey>,
    versions: AsyncMutex<VersionState>,
    keeper: Arc<dyn VersionKeeper>,
    published: AsyncMutex<bool>,
    source: Option<Arc<dyn KeySource>>,
    /// When [source] was last read; one read at a time.
    refreshed: AsyncMutex<Option<Instant>>,
}

impl PersonalAuth {
    pub fn new(key: AccountKey, versions: PersonalVersions, keeper: Arc<dyn VersionKeeper>) -> Self {
        Self {
            key: RwLock::new(key),
            versions: AsyncMutex::new(VersionState {
                data: versions,
                dirty: false,
                seen_signed_blobs: BTreeSet::new(),
                recorded_log_ids: BTreeMap::new(),
            }),
            keeper,
            published: AsyncMutex::new(false),
            source: None,
            refreshed: AsyncMutex::new(None),
        }
    }

    /// Where the account key is read again from when a signature or
    /// `/v2/keys` names a signing key this one does not know: another device
    /// rotated it.
    pub fn with_key_source(mut self, source: Arc<dyn KeySource>) -> Self {
        self.source = Some(source);
        self
    }

    /// Replaces the open account key (for example after another device rotated
    /// it), keeping what the versions record.
    ///
    /// Lock order matches [`Self::ensure_published`]: `published` before `key`.
    pub async fn update_key(&self, key: AccountKey) -> Result<(), Error> {
        let mut published = self.published.lock().await;
        let mut current = self.key.write().await;
        if key.user_id() != current.user_id() {
            return Err(untrusted("account key belongs to a different user"));
        }
        *current = key;
        *published = false;
        Ok(())
    }

    /// The account key read again from [`KeySource`], at most once per
    /// [`KEY_REFRESH_EVERY`]. Only a rotation of the key held is taken: an
    /// older key served again is not.
    async fn refresh_key(&self) -> Refresh {
        let Some(source) = &self.source else { return Refresh::Unchanged };
        let mut refreshed = self.refreshed.lock().await;
        if refreshed.is_some_and(|at| at.elapsed() < KEY_REFRESH_EVERY) {
            return Refresh::NotRead;
        }
        *refreshed = Some(Instant::now());
        let Some(fresh) = source.fetch().await else { return Refresh::NotRead };
        let mut published = self.published.lock().await;
        let mut current = self.key.write().await;
        let held = current.signing_public();
        if fresh.user_id() != current.user_id() || fresh.signing_public() == held || !fresh.signing_history().any(|k| k == held) {
            return Refresh::Unchanged;
        }
        *current = fresh;
        *published = false;
        Refresh::Rotated
    }

    pub async fn user_id(&self) -> String {
        self.key.read().await.user_id().to_string()
    }

    /// See [`PersonalVersions::requires_signature`].
    pub async fn requires_signature(&self, app: &str, name: Option<&str>) -> bool {
        self.versions.lock().await.data.requires_signature(app, name)
    }

    /// The last observed log identifier for [app], if any.
    pub async fn signed_log_id(&self, app: &str) -> Option<String> {
        self.versions.lock().await.data.signed_log_ids.get(app).cloned()
    }

    /// Retries persisting any committed write whose previous
    /// [`VersionKeeper::save`] failed, without re-sending remote writes.
    pub async fn flush_pending_versions(&self) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        Self::flush(&self.keeper, &mut held).await
    }

    async fn flush(keeper: &Arc<dyn VersionKeeper>, held: &mut VersionState) -> Result<(), Error> {
        if held.dirty {
            keeper.save(held.data.to_json()).await.map_err(not_saved)?;
            held.dirty = false;
        }
        Ok(())
    }

    /// Ensures the current signing public key is published on `/v2/keys` so
    /// homebase accepts `X-Signature` headers. Never performs an unchained
    /// reset when `/v2/keys` already holds a different signing key: the
    /// account key is read again first, as another device may have rotated
    /// it.
    pub async fn ensure_published<S: Store>(&self, session: &Arc<Session<S>>, force: bool) -> Result<(), Error> {
        match self.publish(session, force).await {
            Err(e) if e.kind == Kind::Untrusted && self.refresh_key().await == Refresh::Rotated => self.publish(session, true).await,
            other => other,
        }
    }

    async fn publish<S: Store>(&self, session: &Arc<Session<S>>, force: bool) -> Result<(), Error> {
        let mut done = self.published.lock().await;
        if *done && !force {
            return Ok(());
        }
        let key = self.key.read().await.clone();
        TeamClient::new(session.clone()).publish_no_reset(&key).await.map_err(|e| match e {
            TeamError::SignedOut => Error::new(Kind::SignedOut, e.to_string()),
            TeamError::Unreachable(d) => Error::new(Kind::Unreachable, d),
            TeamError::Refused(r) => Error::new(Kind::Refused(r), "publish signing key refused"),
            TeamError::Untrusted(d) => Error::new(Kind::Untrusted, d),
            other => Error::new(Kind::Invalid, format!("publish signing key: {other}")),
        })?;
        *done = true;
        Ok(())
    }

    pub async fn next_file_version(&self, app: &str, name: &str) -> Result<i64, Error> {
        self.versions
            .lock()
            .await
            .data
            .file_version(app, name)
            .checked_add(1)
            .ok_or_else(|| untrusted(format!("{app}/{name}: sync_version overflow")))
    }

    pub async fn sign_file(&self, app: &str, name: &str, version: i64, body: &[u8]) -> WriteSig {
        let key = self.key.read().await;
        let msg = crypto::sync_file_message(key.user_id(), app, name, 0, version, &digest(body));
        WriteSig { signature: BASE64.encode(crypto::sign(key.signing(), &msg)), version: Some(version) }
    }

    pub async fn sign_batch(&self, app: &str, idempotency_key: &str, body: &[u8]) -> WriteSig {
        let key = self.key.read().await;
        let msg = crypto::sync_batch_message(key.user_id(), app, 0, &digest(body), idempotency_key);
        WriteSig { signature: BASE64.encode(crypto::sign(key.signing(), &msg)), version: None }
    }

    pub async fn sign_snapshot(&self, app: &str, seq: i64, body: &[u8]) -> WriteSig {
        let key = self.key.read().await;
        let msg = crypto::sync_snapshot_message(key.user_id(), app, 0, seq, &digest(body));
        WriteSig { signature: BASE64.encode(crypto::sign(key.signing(), &msg)), version: None }
    }

    pub async fn record_file_version(&self, app: &str, name: &str, version: i64) -> Result<(), Error> {
        self.record_committed(|v| v.saw_file(app, name, version)).await
    }

    /// Records a committed signed write-once log blob without adding a per-file
    /// version watermark.
    pub async fn record_blob_written(&self, app: &str) -> Result<(), Error> {
        self.record_committed(|v| v.saw_blob(app)).await
    }

    /// Records a committed signed write-once log blob named [name], remembering
    /// [name] as signed on this auth instance without adding it to persisted
    /// per-file watermarks.
    pub async fn record_named_blob_written(&self, app: &str, name: &str) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        held.seen_signed_blobs.insert(file_key(app, name));
        let mut next = held.data.clone();
        next.saw_blob(app);
        if next != held.data {
            held.data = next;
            held.dirty = true;
        }
        Self::flush(&self.keeper, &mut held).await
    }

    /// Records a committed signed batch append at [seq] of [log].
    pub async fn record_batch_written(&self, app: &str, log: &str, seq: i64) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        held.recorded_log_ids.insert(app.to_string(), log.to_string());
        Self::record_committed_held(&self.keeper, &mut held, |v| v.mark_log_signed_at(app, Some(log), seq)).await
    }

    pub async fn record_snapshot_written(&self, app: &str, seq: i64) -> Result<(), Error> {
        self.record_snapshot_written_on(app, None, seq).await
    }

    pub async fn record_snapshot_written_on(&self, app: &str, log: Option<&str>, seq: i64) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        if let Some(l) = log {
            held.recorded_log_ids.insert(app.to_string(), l.to_string());
        }
        Self::record_committed_held(&self.keeper, &mut held, |v| v.saw_snapshot(app, log, seq)).await
    }

    /// Marks [app] as having seen a signed snapshot without altering its
    /// recorded log identifier or log signing floor.
    pub async fn record_snapshot_seen(&self, app: &str) -> Result<(), Error> {
        self.record_committed(|v| {
            v.signed_snapshots.insert(app.to_string());
        })
        .await
    }

    /// Records a previously committed signed snapshot without rewinding
    /// `signed_log_ids[app]` to [log] once a different log was recorded or
    /// [observer] saw one. Returns `false` (recording only
    /// `signed_snapshots[app]`) when [log] is superseded, also by an
    /// observation arriving while its binding is saved.
    pub async fn record_snapshot_if_log_compatible(&self, app: &str, log: Option<&str>, seq: i64, observer: &impl LogObserver) -> Result<bool, Error> {
        let mut held = self.versions.lock().await;
        let superseded = log.is_some_and(|target| held.data.signed_log_ids.get(app).is_some_and(|known| known != target));
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, log, seq, superseded, observer).await
    }

    /// Verifies a downloaded file's signature and monotonic version.
    ///
    /// When `enforce_monotonic` is false (explicitly fetching an older version
    /// from history via `download_version`), the signature is still verified
    /// against this account's own key history and recorded as signed without
    /// failing on an older version number or moving the current highest.
    pub async fn verify_file(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        self.verify_file_digest(app, name, &digest(body), signed, enforce_monotonic).await
    }

    /// Verifies a downloaded write-once log blob's signature without recording
    /// a per-file version watermark.
    pub async fn verify_blob(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>) -> Result<(), Error> {
        self.verify_blob_digest(app, name, &digest(body), signed).await
    }

    /// Verifies a downloaded write-once log blob bound to a pre-signing
    /// reference retained by a batch or snapshot: permits an unsigned response
    /// only when [name] has never been seen or written signed (whatever
    /// [app]'s `signed_apps` / `signed_blobs` policy) and its bytes hold
    /// [binding].
    pub async fn verify_retained_blob(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, binding: RetainedBinding<'_>) -> Result<(), Error> {
        self.verify_blob_digest_inner(app, name, &digest(body), signed, Some((binding, body))).await
    }

    /// Streaming variant of [`Self::verify_blob`] taking a precomputed blake3 digest.
    pub async fn verify_blob_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>) -> Result<(), Error> {
        self.verify_blob_digest_inner(app, name, body_digest, signed, None).await
    }

    /// [retained]: the binding and bytes of a retained answer; `None` on the
    /// strict path.
    async fn verify_blob_digest_inner(
        &self,
        app: &str,
        name: &str,
        body_digest: &[u8; KEY_LEN],
        signed: Option<&Signed>,
        retained: Option<(RetainedBinding<'_>, &[u8])>,
    ) -> Result<(), Error> {
        let key = file_key(app, name);
        let Some(s) = signed else {
            // TODO(migration): reject unsigned personal blobs unconditionally
            // once pre-signing uploads are no longer present.
            // A retained answer is bound to the digest a verified container
            // gives (signed, or an unsigned one accepted below the signing
            // floor) or to the caller's own content, so only a name seen signed
            // refuses it; `signed_apps` must not strand pre-signing blobs
            // before they are migrated.
            let refuses = |held: &VersionState| {
                held.seen_signed_blobs.contains(&key)
                    || held.data.files.contains_key(&key)
                    || (retained.is_none() && held.data.blob_requires_signature(app))
            };
            let stripped = || untrusted(format!("{app}/{name}: server stripped signature"));
            let mut held = self.versions.lock().await;
            if refuses(&held) {
                return Err(stripped());
            }
            if let Some((binding, body)) = retained {
                // Checked unlocked: a content binding opens and parses the bytes.
                drop(held);
                if !binding.holds(body) {
                    return Err(untrusted(format!("{app}/{name}: {RETAINED_MISMATCH}")));
                }
                held = self.versions.lock().await;
                // Seen signed meanwhile.
                if refuses(&held) {
                    return Err(stripped());
                }
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let version = s.version.ok_or_else(|| untrusted(format!("{app}/{name}: signed file missing version")))?;
        if version <= 0 {
            return Err(untrusted(format!("{app}/{name}: invalid version {version}")));
        }
        let owner = self.verify_own_key(s, &format!("{app}/{name}")).await?;
        let msg = crypto::sync_file_message(&owner, app, name, 0, version, body_digest);
        verify_sig(s, &msg, &format!("{app}/{name}"))?;
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        next.saw_blob(app);
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        held.seen_signed_blobs.insert(key);
        Ok(())
    }

    /// Streaming variant of [`Self::verify_file`] taking a precomputed blake3 digest.
    pub async fn verify_file_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        let Some(s) = signed else {
            // Checked under the versions lock against concurrent signed
            // writes and reads.
            // TODO(migration): reject unsigned personal files unconditionally
            // once pre-signing uploads are no longer present.
            let mut held = self.versions.lock().await;
            if held.data.requires_signature(app, Some(name)) {
                let seen = held.data.file_version(app, name);
                return Err(untrusted(format!("{app}/{name}: server stripped signature (expected version >= {seen})")));
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let version = s.version.ok_or_else(|| untrusted(format!("{app}/{name}: signed file missing version")))?;
        if version <= 0 {
            return Err(untrusted(format!("{app}/{name}: invalid version {version}")));
        }
        let owner = self.verify_own_key(s, &format!("{app}/{name}")).await?;
        let msg = crypto::sync_file_message(&owner, app, name, 0, version, body_digest);
        verify_sig(s, &msg, &format!("{app}/{name}"))?;
        self.persist_checked(|v| {
            if !enforce_monotonic {
                v.saw_file(app, name, 0);
                return Ok(());
            }
            let seen = v.file_version(app, name);
            if version < seen {
                return Err(untrusted(format!("{app}/{name}: version rollback ({version} < {seen})")));
            }
            v.saw_file(app, name, version);
            Ok(())
        })
        .await
    }

    /// Verifies a page of log batches and persists the log's signing marker
    /// in a single [`VersionKeeper::save`] call.
    pub async fn verify_batches(&self, app: &str, log: Option<&str>, batches: &[Batch]) -> Result<(), Error> {
        let mut first_signed: Option<i64> = None;
        let mut unsigned: Vec<i64> = Vec::new();
        for batch in batches {
            let what = format!("{app}/log batch {}", batch.seq);
            let Some(s) = batch.signed.as_ref() else {
                unsigned.push(batch.seq);
                continue;
            };
            let idem = batch.idempotency_key.as_deref().ok_or_else(|| untrusted(format!("{what}: missing idempotency key")))?;
            let owner = self.verify_own_key(s, &what).await?;
            let msg = crypto::sync_batch_message(&owner, app, 0, &digest(&batch.body), idem);
            verify_sig(s, &msg, &what)?;
            first_signed = Some(first_signed.map_or(batch.seq, |f| f.min(batch.seq)));
        }
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        if let Some(seq) = first_signed {
            next.mark_log_signed_at(app, log, seq);
        }
        if let Some(seq) = unsigned.iter().find(|&&seq| next.log_requires_signature(app, log, seq)) {
            return Err(untrusted(format!("{app}/log batch {seq}: server stripped signature")));
        }
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        if first_signed.is_some()
            && let Some(l) = log
        {
            held.recorded_log_ids.insert(app.to_string(), l.to_string());
        }
        Ok(())
    }

    /// Verifies a log snapshot's signature.
    pub async fn verify_snapshot(&self, app: &str, snapshot: &Snapshot, body: &[u8]) -> Result<(), Error> {
        self.verify_snapshot_digest(app, snapshot, &digest(body)).await
    }

    /// Verifies a signed snapshot's cryptographic signature without advancing
    /// persisted state; rejects unsigned snapshots.
    pub async fn verify_snapshot_signature_only(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let s = snapshot.signed.as_ref().ok_or_else(|| untrusted(format!("{what}: server stripped signature")))?;
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_snapshot_message(&owner, app, 0, snapshot.seq, body_digest);
        verify_sig(s, &msg, &what)
    }

    /// Verifies a signed snapshot for detached recovery and records its log
    /// binding unless a different log was recorded under this
    /// [`PersonalAuth`] instance or [observer] saw one, also while the binding
    /// is saved. Returns `false` in that case, recording only
    /// `signed_snapshots[app]`.
    pub async fn verify_snapshot_digest_for_detached(
        &self,
        app: &str,
        snapshot: &Snapshot,
        body_digest: &[u8; KEY_LEN],
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        self.verify_snapshot_signature_only(app, snapshot, body_digest).await?;
        let mut held = self.versions.lock().await;
        let superseded = held.recorded_log_ids.get(app).is_some_and(|existing| existing != &snapshot.log);
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, Some(&snapshot.log), snapshot.seq, superseded, observer).await
    }

    /// [`Self::verify_snapshot_digest`] ordered against [observer]: a signed
    /// snapshot on a log other than the one observed, or than the one this
    /// instance recorded while not the one observed, is refused (`Ok(false)`)
    /// before it changes the signing binding or floor; its signed-snapshot
    /// marker is recorded either way.
    pub async fn verify_snapshot_digest_observed(
        &self,
        app: &str,
        snapshot: &Snapshot,
        body_digest: &[u8; KEY_LEN],
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        if snapshot.signed.is_none() {
            return self.verify_snapshot_digest(app, snapshot, body_digest).await.map(|()| true);
        }
        self.verify_snapshot_signature_only(app, snapshot, body_digest).await?;
        let mut held = self.versions.lock().await;
        // A log observed live since takes the place of the one recorded.
        let superseded = held.recorded_log_ids.get(app).is_some_and(|known| known != &snapshot.log) && !observer.confirm(&snapshot.log)?;
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, Some(&snapshot.log), snapshot.seq, superseded, observer).await
    }

    /// Streaming variant of [`Self::verify_snapshot`] taking a precomputed blake3 digest.
    pub async fn verify_snapshot_digest(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let Some(s) = snapshot.signed.as_ref() else {
            // TODO(migration): reject unsigned personal snapshots
            // unconditionally once pre-signing snapshots are replaced.
            let mut held = self.versions.lock().await;
            if held.data.snapshot_requires_signature(app, &snapshot.log, snapshot.seq) {
                return Err(untrusted(format!("{what}: server stripped signature")));
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_snapshot_message(&owner, app, 0, snapshot.seq, body_digest);
        verify_sig(s, &msg, &what)?;
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        next.saw_snapshot(app, Some(&snapshot.log), snapshot.seq);
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        held.recorded_log_ids.insert(app.to_string(), snapshot.log.clone());
        Ok(())
    }

    /// The account's id when [s] is signed by a signing key it has had; the
    /// account key is read again once for one it does not know.
    async fn verify_own_key(&self, s: &Signed, what: &str) -> Result<String, Error> {
        if let Some(owner) = self.own_signer(s, what).await? {
            return Ok(owner);
        }
        let refresh = self.refresh_key().await;
        if let Some(owner) = self.own_signer(s, what).await? {
            return Ok(owner);
        }
        Err(match refresh {
            // Not read now: a rotation elsewhere may be what it is signed by.
            Refresh::NotRead => Error::new(Kind::Unreachable, format!("{what}: signing key not known yet; the account key is read again later")),
            Refresh::Rotated | Refresh::Unchanged => untrusted(format!("{what}: signing key not in account key history")),
        })
    }

    async fn own_signer(&self, s: &Signed, what: &str) -> Result<Option<String>, Error> {
        let key = self.key.read().await;
        if s.signer != key.user_id() {
            return Err(untrusted(format!("{what}: signed by {}, not {}", s.signer, key.user_id())));
        }
        Ok(key.signing_history().any(|k| k == s.signing_key).then(|| key.user_id().to_string()))
    }

    /// Read-path persistence: only advances in-memory state once `keeper.save`
    /// succeeds so an unpersisted read does not silently advance it.
    async fn persist_checked(&self, f: impl FnOnce(&mut PersonalVersions) -> Result<(), Error>) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        f(&mut next)?;
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        Ok(())
    }

    /// Write-path persistence: updates in-memory state immediately after the
    /// remote write has already committed, marking state dirty if `keeper.save`
    /// fails so persistence can be retried without resending the remote write.
    async fn record_committed(&self, f: impl FnOnce(&mut PersonalVersions)) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        Self::record_committed_held(&self.keeper, &mut held, f).await
    }

    async fn record_committed_held(
        keeper: &Arc<dyn VersionKeeper>,
        held: &mut VersionState,
        f: impl FnOnce(&mut PersonalVersions),
    ) -> Result<(), Error> {
        let mut next = held.data.clone();
        f(&mut next);
        if next != held.data {
            held.data = next;
            held.dirty = true;
        }
        Self::flush(keeper, held).await
    }

    /// Records a signed snapshot at [seq] of [log] in order with [observer].
    /// Only `signed_snapshots[app]` is persisted before [observer] accepts
    /// [log], so a log observed meanwhile never finds a binding to [log]
    /// persisted, even across a restart; once accepted, the binding is
    /// persisted before `true` is returned for a [log] still observed, and
    /// reverted when another log was observed meanwhile. The marker and the
    /// revert are marked dirty, so [`Self::flush_pending_versions`] retries
    /// them; the binding never is: a failed binding save leaves it out of
    /// memory, and the caller keeps its recovery entry and retries here, where
    /// [observer] is consulted again.
    async fn record_snapshot_ordered(
        keeper: &Arc<dyn VersionKeeper>,
        held: &mut VersionState,
        app: &str,
        log: Option<&str>,
        seq: i64,
        superseded: bool,
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        Self::record_committed_held(keeper, held, |v| {
            v.signed_snapshots.insert(app.to_string());
        })
        .await?;
        if superseded {
            return Ok(false);
        }
        Self::bind_snapshot_ordered(keeper, held, app, log, seq, observer).await
    }

    /// Binds [app]'s signing floor to [log] at [seq] once [observer] takes
    /// [log] as the one observed, and keeps it only while it still is once
    /// saved; `false` (nothing bound) otherwise.
    async fn bind_snapshot_ordered(
        keeper: &Arc<dyn VersionKeeper>,
        held: &mut VersionState,
        app: &str,
        log: Option<&str>,
        seq: i64,
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        if !log.map_or(Ok(true), |l| observer.commit(l))? {
            return Ok(false);
        }
        let mut bound = held.data.clone();
        bound.saw_snapshot(app, log, seq);
        if bound != held.data {
            keeper.save(bound.to_json()).await.map_err(not_saved)?;
        }
        let prior = std::mem::replace(&mut held.data, bound);
        let confirmed = log.map_or(Ok(true), |l| observer.confirm(l));
        if !matches!(confirmed, Ok(true)) {
            // Superseded, or the auth changed, while saved: nothing stays bound to [log].
            Self::record_committed_held(keeper, held, |v| *v = prior).await?;
            return confirmed.map(|_| false);
        }
        if let Some(l) = log {
            held.recorded_log_ids.insert(app.to_string(), l.to_string());
        }
        Ok(true)
    }
}

fn verify_sig(s: &Signed, msg: &[u8], what: &str) -> Result<(), Error> {
    let pk = BASE64.decode(&s.signing_key).map_err(|_| untrusted(format!("{what}: signing key not base64")))?;
    let sig = BASE64.decode(&s.signature).map_err(|_| untrusted(format!("{what}: signature not base64")))?;
    crypto::verify(&pk, msg, &sig, "a personal sync write").map_err(|e| untrusted(format!("{what}: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    struct MemKeeper {
        saved: Mutex<String>,
        fail: AtomicBool,
    }

    impl MemKeeper {
        fn new() -> Arc<Self> {
            Arc::new(Self { saved: Mutex::new(String::new()), fail: AtomicBool::new(false) })
        }
    }

    impl VersionKeeper for MemKeeper {
        fn save(&self, json: String) -> BoxFuture<'_, Result<(), String>> {
            if self.fail.load(Ordering::SeqCst) {
                return Box::pin(async { Err("disk full".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    struct MemSource {
        key: Mutex<Option<AccountKey>>,
        reads: AtomicUsize,
    }

    impl KeySource for MemSource {
        fn fetch(&self) -> BoxFuture<'_, Option<AccountKey>> {
            self.reads.fetch_add(1, Ordering::SeqCst);
            let key = self.key.lock().unwrap().clone();
            Box::pin(async move { key })
        }
    }

    fn auth_for(key: AccountKey) -> (PersonalAuth, Arc<MemKeeper>) {
        let keeper = MemKeeper::new();
        let auth = PersonalAuth::new(key, PersonalVersions::from_json("").unwrap(), keeper.clone());
        (auth, keeper)
    }

    fn signed(key: &AccountKey, signature: String, version: Option<i64>) -> Signed {
        Signed { signer: key.user_id().into(), signing_key: key.signing_public(), signature, version }
    }

    async fn signed_batch(auth: &PersonalAuth, key: &AccountKey, seq: i64, idem: &str, body: &[u8]) -> Batch {
        let sig = auth.sign_batch("serverbox", idem, body).await;
        Batch { seq, body: body.to_vec(), epoch: None, idempotency_key: Some(idem.into()), signed: Some(signed(key, sig.signature, None)) }
    }

    async fn signed_snapshot(auth: &PersonalAuth, key: &AccountKey, log: &str, seq: i64, body: &[u8]) -> Snapshot {
        let sig = auth.sign_snapshot("serverbox", seq, body).await;
        Snapshot { log: log.into(), seq, signed: Some(signed(key, sig.signature, None)) }
    }

    /// Accepts or refuses every log, remembering what was persisted when asked.
    struct TestObserver {
        accept: bool,
        keeper: Arc<MemKeeper>,
        observed: Mutex<Option<String>>,
        saved_at_commit: Mutex<Option<String>>,
    }

    impl TestObserver {
        fn new(accept: bool, keeper: &Arc<MemKeeper>) -> Self {
            Self { accept, keeper: keeper.clone(), observed: Mutex::new(None), saved_at_commit: Mutex::new(None) }
        }
    }

    impl LogObserver for TestObserver {
        fn commit(&self, log: &str) -> Result<bool, Error> {
            *self.saved_at_commit.lock().unwrap() = Some(self.keeper.saved.lock().unwrap().clone());
            if self.accept {
                *self.observed.lock().unwrap() = Some(log.into());
            }
            Ok(self.accept)
        }

        fn confirm(&self, log: &str) -> Result<bool, Error> {
            Ok(self.observed.lock().unwrap().as_deref() == Some(log))
        }
    }

    #[tokio::test]
    async fn detached_snapshot_binding_is_persisted_only_once_accepted() {
        let key = AccountKey::generate("u1");
        let saved = |keeper: &MemKeeper| PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();

        // Refused: only the marker is persisted, never the binding.
        let (auth, keeper) = auth_for(key.clone());
        let snap = signed_snapshot(&auth, &key, "log-a", 5, b"snap").await;
        let observer = TestObserver::new(false, &keeper);
        assert!(!auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap());
        let v = saved(&keeper);
        assert!(v.signed_snapshots.contains("serverbox"));
        assert!(v.signed_log_ids.is_empty() && v.signed_log_from.is_empty(), "{v:?}");
        assert_eq!(auth.signed_log_id("serverbox").await, None);

        // A failed marker save stays dirty and is retried by `flush_pending_versions`.
        let (auth, keeper) = auth_for(key.clone());
        let observer = TestObserver::new(true, &keeper);
        keeper.fail.store(true, Ordering::SeqCst);
        assert_eq!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap_err().kind, Kind::Invalid);
        assert!(observer.saved_at_commit.lock().unwrap().is_none(), "observer asked before the marker was saved");
        keeper.fail.store(false, Ordering::SeqCst);
        auth.flush_pending_versions().await.unwrap();
        assert!(saved(&keeper).signed_snapshots.contains("serverbox"));

        // Accepted: nothing bound to the log is on disk when the observer
        // decides; a failed binding save neither succeeds nor leaves the
        // binding for a generic flush.
        keeper.fail.store(true, Ordering::SeqCst);
        assert_eq!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap_err().kind, Kind::Invalid);
        let at_commit = observer.saved_at_commit.lock().unwrap().clone().unwrap();
        assert!(!at_commit.contains("log-a"), "{at_commit}");
        assert_eq!(auth.signed_log_id("serverbox").await, None);
        keeper.fail.store(false, Ordering::SeqCst);
        auth.flush_pending_versions().await.unwrap();
        assert!(!keeper.saved.lock().unwrap().contains("log-a"));

        // Retried while still observed: the binding is persisted.
        assert!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap());
        let v = saved(&keeper);
        assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
        assert_eq!(v.log_signed_from("serverbox"), Some(5));
    }

    #[tokio::test]
    async fn an_observed_snapshot_on_another_log_than_the_recorded_one_binds_nothing() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());
        let on_a = signed_snapshot(&auth, &key, "log-a", 5, b"a").await;
        auth.verify_snapshot_digest("serverbox", &on_a, &digest(b"a")).await.unwrap();
        let on_b = signed_snapshot(&auth, &key, "log-b", 9, b"b").await;
        let observer = TestObserver::new(true, &keeper);
        assert!(!auth.verify_snapshot_digest_observed("serverbox", &on_b, &digest(b"b"), &observer).await.unwrap());
        assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("log-a"));
        assert!(observer.observed.lock().unwrap().is_none(), "the observation is untouched");
        assert!(PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap().signed_snapshots.contains("serverbox"), "its marker is kept");

        // Once log B is observed live, it takes the recorded one's place.
        *observer.observed.lock().unwrap() = Some("log-b".into());
        assert!(auth.verify_snapshot_digest_observed("serverbox", &on_b, &digest(b"b"), &observer).await.unwrap());
        assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("log-b"));
    }

    #[tokio::test]
    async fn failed_binding_save_is_retried_against_the_observed_log() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key);
        auth.record_snapshot_seen("serverbox").await.unwrap();
        keeper.fail.store(true, Ordering::SeqCst);
        let accept = TestObserver::new(true, &keeper);
        assert_eq!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &accept).await.unwrap_err().kind, Kind::Invalid);
        keeper.fail.store(false, Ordering::SeqCst);
        auth.flush_pending_versions().await.unwrap();
        assert_eq!(auth.signed_log_id("serverbox").await, None);

        // Log B superseded A before the retry: the marker stays, A is never persisted.
        let refuse = TestObserver::new(false, &keeper);
        assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &refuse).await.unwrap());
        let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert!(v.signed_snapshots.contains("serverbox"));
        assert!(v.signed_log_ids.is_empty() && v.signed_log_from.is_empty(), "{v:?}");

        // A still observed: the retry persists its binding.
        assert!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &accept).await.unwrap());
        let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
        assert_eq!(v.log_signed_from("serverbox"), Some(5));
    }

    #[tokio::test]
    async fn snapshot_binding_yields_to_a_log_observed_while_saved() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key);
        // Observed something else by the time the binding is saved.
        struct Moved;
        impl LogObserver for Moved {
            fn commit(&self, _: &str) -> Result<bool, Error> {
                Ok(true)
            }
            fn confirm(&self, _: &str) -> Result<bool, Error> {
                Ok(false)
            }
        }
        assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &Moved).await.unwrap());
        let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert!(v.signed_snapshots.contains("serverbox"));
        assert_eq!(v.signed_log_ids.get("serverbox"), None, "nothing stays bound to a log superseded while saved");
        assert!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &TestObserver::new(true, &keeper)).await.unwrap());
        // A known different log records only the marker, leaving its floor.
        assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-b"), 1, &TestObserver::new(true, &keeper)).await.unwrap());
        let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
        assert_eq!(v.log_signed_from("serverbox"), Some(5));
    }

    #[tokio::test]
    async fn file_sign_verify_and_rollback_detection() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let body1 = b"age-cipher-1";
        let signed1 = signed(&key, auth.sign_file("serverbox", "bak", 1, body1).await.signature, Some(1));
        auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap();
        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 2);

        // Tampered body fails signature check.
        assert_eq!(auth.verify_file("serverbox", "bak", b"tampered", Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

        // Advance to version 2, then server attempts rollback to version 1.
        let body2 = b"age-cipher-2";
        let signed2 = signed(&key, auth.sign_file("serverbox", "bak", 2, body2).await.signature, Some(2));
        auth.verify_file("serverbox", "bak", body2, Some(&signed2), true).await.unwrap();
        assert_eq!(auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

        // Explicit historical version fetch verifies signature without rollback error.
        auth.verify_file("serverbox", "bak", body1, Some(&signed1), false).await.unwrap();

        // Stripping signature after seeing signed version is rejected — even for a new blob name!
        assert_eq!(auth.verify_file("serverbox", "bak", body2, None, true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(auth.verify_file("serverbox", "blob-new.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);

        // Persisted JSON restores the highest version.
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert_eq!(reloaded.file_version("serverbox", "bak"), 2);
    }

    #[tokio::test]
    async fn forged_key_and_stripped_batches_are_rejected() {
        let key = AccountKey::generate("u1");
        let attacker = AccountKey::generate("u1");
        let (auth, _) = auth_for(key.clone());

        // Attacker signs with a key not in u1's AccountKey history.
        let body = b"evil-batch";
        let msg = crypto::sync_batch_message("u1", "serverbox", 0, &digest(body), "idem-123456789012");
        let forged = Batch {
            seq: 1,
            body: body.to_vec(),
            epoch: None,
            idempotency_key: Some("idem-123456789012".into()),
            signed: Some(signed(&attacker, BASE64.encode(crypto::sign(attacker.signing(), &msg)), None)),
        };
        assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[forged]).await.unwrap_err().kind, Kind::Untrusted);

        let good = signed_batch(&auth, &key, 1, "idem-123456789012", body).await;
        auth.verify_batches("serverbox", Some("log1"), std::slice::from_ref(&good)).await.unwrap();

        // Stripped signature on a later batch rejected.
        let unsigned = Batch { seq: 3, signed: None, ..good };
        assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[unsigned]).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn log_made_anew_reads_on() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let batch = signed_batch(&auth, &key, 500, "idem-123456789012", b"op").await;
        auth.verify_batches("serverbox", Some("log-1"), std::slice::from_ref(&batch)).await.unwrap();
        auth.verify_snapshot("serverbox", &signed_snapshot(&auth, &key, "log-1", 500, b"snap-500").await, b"snap-500").await.unwrap();

        // Homebase made the log anew: seqs start at 1 again, a batch sent
        // again under its key lands at another seq, after a restart too.
        let restarted = PersonalAuth::new(key.clone(), PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap(), MemKeeper::new());
        restarted.verify_snapshot("serverbox", &signed_snapshot(&auth, &key, "log-2", 20, b"snap-20").await, b"snap-20").await.unwrap();
        restarted.verify_batches("serverbox", Some("log-2"), &[Batch { seq: 21, ..batch }]).await.unwrap();

        // Stripping a snapshot's signature stays refused at any seq, and the
        // new log holds no legacy batch below the old log's first signed one.
        let stripped = Snapshot { log: "log-2".into(), seq: 1, signed: None };
        assert_eq!(restarted.verify_snapshot("serverbox", &stripped, b"evil").await.unwrap_err().kind, Kind::Untrusted);
        let unsigned = Batch { seq: 3, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(restarted.verify_batches("serverbox", Some("log-2"), &[unsigned]).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn versions_stay_small() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());
        for i in 0..50 {
            let name = format!("op-{i:04}.age");
            let s = signed(&key, auth.sign_file("serverbox", &name, 1, b"blob").await.signature, Some(1));
            auth.verify_blob("serverbox", &name, b"blob", Some(&s)).await.unwrap();
            auth.record_blob_written("serverbox").await.unwrap();
            let batch = signed_batch(&auth, &key, i + 1, &format!("idem-{i:012}"), b"op").await;
            auth.verify_batches("serverbox", Some("log1"), &[batch]).await.unwrap();
            auth.record_batch_written("serverbox", "log1", i + 100).await.unwrap();
        }
        let saved = keeper.saved.lock().unwrap().clone();
        assert!(saved.len() < 200, "{saved}");
        // An unsigned log blob is still refused.
        assert_eq!(auth.verify_blob("serverbox", "op-evil.age", b"evil", None).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn mutable_file_named_with_op_prefix_keeps_version_watermark() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let v1 = signed(&key, auth.sign_file("serverbox", "op-notes.age", 1, b"v1").await.signature, Some(1));
        auth.verify_file("serverbox", "op-notes.age", b"v1", Some(&v1), true).await.unwrap();
        assert_eq!(auth.next_file_version("serverbox", "op-notes.age").await.unwrap(), 2);

        // Persisting and reloading keeps the op-notes.age watermark intact.
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert_eq!(reloaded.file_version("serverbox", "op-notes.age"), 1);
        assert!(reloaded.requires_signature("serverbox", Some("op-notes.age")));

        let v2 = signed(&key, auth.sign_file("serverbox", "op-notes.age", 2, b"v2").await.signature, Some(2));
        auth.verify_file("serverbox", "op-notes.age", b"v2", Some(&v2), true).await.unwrap();
        assert_eq!(auth.next_file_version("serverbox", "op-notes.age").await.unwrap(), 3);

        // Rolling op-notes.age back to v1 is rejected.
        assert_eq!(auth.verify_file("serverbox", "op-notes.age", b"v1", Some(&v1), true).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[test]
    fn earlier_versions_are_read() {
        let json = r#"{"v":1,"files":{"serverbox/bak":3,"serverbox/op-1.age":1},"signed_files":["serverbox/identity.age","gptbox/op-2.age"],
            "signed_apps":["serverbox"],"signed_logs":["serverbox"],"signed_log_from":{"gptbox":7},"snapshots":{"gptbox":9},
            "taken":{"serverbox":{"idem-123456789012":4}}}"#;
        let v = PersonalVersions::from_json(json).unwrap();
        assert_eq!(v.file_version("serverbox", "bak"), 3);
        assert!(v.requires_signature("serverbox", Some("identity.age")));
        assert!(v.blob_requires_signature("serverbox"));
        assert!(v.blob_requires_signature("gptbox"));
        assert!(!v.requires_signature("gptbox", Some("bak")));
        assert_eq!(v.log_signed_from("serverbox"), Some(1));
        assert!(v.snapshot_requires_signature("gptbox", "log1", 1));
        let json = v.to_json();
        assert!(!json.contains("op-") && !json.contains("taken"), "{json}");
        assert_eq!(PersonalVersions::from_json(&json).unwrap(), v);
    }

    #[test]
    fn v1_migration_preserves_mutable_op_prefixed_watermarks_and_migrates_blobs() {
        let json = r#"{
            "v": 1,
            "files": {
                "serverbox/op-notes.age": 1,
                "serverbox/op-deadbeef.age": 3,
                "serverbox/op-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.age": 1,
                "gptbox/op-0123456789abcdef-fedcba9876543210.age": 1
            },
            "signed_files": ["serverbox/op-deadbeef.age"]
        }"#;
        let v = PersonalVersions::from_json(json).unwrap();
        assert_eq!(v.file_version("serverbox", "op-notes.age"), 1);
        assert_eq!(v.file_version("serverbox", "op-deadbeef.age"), 3);
        assert_eq!(v.file_version("serverbox", "op-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.age"), 0);
        assert!(v.blob_requires_signature("serverbox"));
        assert!(v.blob_requires_signature("gptbox"));
        // Round-tripping v2 preserves all mutable op-* entries.
        let reloaded = PersonalVersions::from_json(&v.to_json()).unwrap();
        assert_eq!(reloaded.file_version("serverbox", "op-notes.age"), 1);
        assert_eq!(reloaded.file_version("serverbox", "op-deadbeef.age"), 3);
    }

    #[tokio::test]
    async fn update_key_rejects_other_user_and_keeper_failure_does_not_advance() {
        let key = AccountKey::generate("u1");
        let other = AccountKey::generate("u2");
        let (auth, keeper) = auth_for(key.clone());

        assert_eq!(auth.update_key(other).await.unwrap_err().kind, Kind::Untrusted);

        // When keeper fails to persist, the version must not advance in memory.
        keeper.fail.store(true, Ordering::SeqCst);
        let body = b"cipher";
        let s = signed(&key, auth.sign_file("serverbox", "bak", 1, body).await.signature, Some(1));
        assert_eq!(auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap_err().kind, Kind::Invalid);
        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
    }

    #[tokio::test]
    async fn rotated_account_key_still_verifies_previous_signatures() {
        let old = AccountKey::generate("u1");
        let rotated = old.rotated();
        let (auth, _) = auth_for(rotated);
        let body = b"older-cipher";
        let msg = crypto::sync_file_message("u1", "serverbox", "bak", 0, 1, &digest(body));
        let s = signed(&old, BASE64.encode(crypto::sign(old.signing(), &msg)), Some(1));
        auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap();
    }

    #[tokio::test]
    async fn key_rotated_elsewhere_is_read_again() {
        let old = AccountKey::generate("u1");
        let rotated = old.rotated();
        let source = Arc::new(MemSource { key: Mutex::new(Some(rotated.clone())), reads: AtomicUsize::new(0) });
        let auth = PersonalAuth::new(old.clone(), PersonalVersions::default(), MemKeeper::new()).with_key_source(source.clone());

        // Another device signed with the rotated key: read once, then known.
        let (writer, _) = auth_for(rotated.clone());
        let body = b"newer-cipher";
        let s = signed(&rotated, writer.sign_file("serverbox", "bak", 1, body).await.signature, Some(1));
        auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap();
        assert_eq!(source.reads.load(Ordering::SeqCst), 1);
        assert_eq!(auth.sign_file("serverbox", "bak", 2, body).await.signature, writer.sign_file("serverbox", "bak", 2, body).await.signature);

        // A key nobody of the account has: the file is read at most once per
        // interval, and meanwhile the write waits instead of being refused.
        let stranger = AccountKey::generate("u1");
        let (forger, _) = auth_for(stranger.clone());
        let f = signed(&stranger, forger.sign_file("serverbox", "bak", 3, body).await.signature, Some(3));
        for _ in 0..3 {
            assert_eq!(auth.verify_file("serverbox", "bak", body, Some(&f), true).await.unwrap_err().kind, Kind::Unreachable);
        }
        assert_eq!(source.reads.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn an_older_account_key_is_not_taken_back() {
        let old = AccountKey::generate("u1");
        let rotated = old.rotated();
        let source = Arc::new(MemSource { key: Mutex::new(Some(old)), reads: AtomicUsize::new(0) });
        let auth = PersonalAuth::new(rotated.clone(), PersonalVersions::default(), MemKeeper::new()).with_key_source(source.clone());

        let stranger = AccountKey::generate("u1");
        let (forger, _) = auth_for(stranger.clone());
        let f = signed(&stranger, forger.sign_file("serverbox", "bak", 1, b"x").await.signature, Some(1));
        assert_eq!(auth.verify_file("serverbox", "bak", b"x", Some(&f), true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(source.reads.load(Ordering::SeqCst), 1);
        let (holder, _) = auth_for(rotated);
        assert_eq!(auth.sign_file("serverbox", "bak", 1, b"x").await.signature, holder.sign_file("serverbox", "bak", 1, b"x").await.signature);
    }

    #[test]
    fn default_personal_versions_round_trips_json() {
        let def = PersonalVersions::default();
        assert_eq!(PersonalVersions::from_json(&def.to_json()).unwrap(), def);
        assert_eq!(PersonalVersions::from_json("").unwrap(), def);
    }

    #[tokio::test]
    async fn historical_file_marks_app_signed_without_advancing() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let body = b"historical-v3";
        let s = signed(&key, auth.sign_file("serverbox", "bak", 3, body).await.signature, Some(3));
        auth.verify_file("serverbox", "bak", body, Some(&s), false).await.unwrap();

        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
        assert!(auth.requires_signature("serverbox", None).await);

        // Subsequent unsigned response for the app is rejected (even after restart).
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        let restarted = PersonalAuth::new(key, reloaded, MemKeeper::new());
        assert_eq!(restarted.verify_file("serverbox", "bak", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(restarted.verify_file("serverbox", "other.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn first_signed_log_write_preserves_legacy_backups_and_earlier_batches() {
        let key = AccountKey::generate("u1");
        let (auth, _) = auth_for(key.clone());

        // First signed log batch lands at seq 10.
        auth.record_batch_written("serverbox", "log1", 10).await.unwrap();
        // Pre-existing unsigned backup file remains readable until files migrate.
        auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
        // Unconsumed legacy unsigned batch from before seq 10 remains readable.
        let legacy_batch = Batch { seq: 9, body: b"legacy-op".to_vec(), epoch: None, idempotency_key: None, signed: None };
        auth.verify_batches("serverbox", Some("log1"), &[legacy_batch]).await.unwrap();
        // Unsigned batch at or past seq 10 is rejected.
        for seq in [10, 11] {
            let stripped = Batch { seq, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
            assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[stripped]).await.unwrap_err().kind, Kind::Untrusted);
        }

        // Signing the sync key file and log blobs keeps the legacy backup
        // readable, here and for what asks whether it needs a signature,
        // while their own stripping is refused.
        auth.record_file_version("serverbox", "identity.age", 1).await.unwrap();
        auth.record_blob_written("serverbox").await.unwrap();
        assert!(!auth.requires_signature("serverbox", Some("srvbox_bak_v4.age")).await);
        assert!(!auth.requires_signature("serverbox", None).await);
        auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
        assert_eq!(auth.verify_file("serverbox", "identity.age", b"stripped", None, true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(auth.verify_blob("serverbox", "op-def.age", b"stripped", None).await.unwrap_err().kind, Kind::Untrusted);

        // Upgrading from the legacy `signed_logs` marker keeps the threshold
        // at 1 even after observing a higher signed seq.
        let legacy_versions = PersonalVersions::from_json(r#"{"v":1,"signed_logs":["serverbox"]}"#).unwrap();
        let legacy_auth = PersonalAuth::new(key, legacy_versions, MemKeeper::new());
        legacy_auth.record_batch_written("serverbox", "log1", 50).await.unwrap();
        let low_unsigned = Batch { seq: 2, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(legacy_auth.verify_batches("serverbox", Some("log1"), &[low_unsigned]).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn retained_blob_needs_its_binding_and_survives_signed_apps_but_not_a_name_seen_signed() {
        let key = AccountKey::generate("u1");
        let digest_of = |b: &[u8]| RetainedBinding::Digest(digest(b));
        let is_legacy = |b: &[u8]| b == b"legacy";
        let mismatch = |e: Error| e.kind == Kind::Untrusted && e.detail.ends_with(RETAINED_MISMATCH);

        // When only `signed_blobs` is set (ordinary files not locked to signed-only),
        // a retained pre-signing blob bound by digest or content remains readable while
        // strict blob reads reject unsigned.
        let blobs_only = PersonalVersions::from_json(r#"{"v":2,"signed_blobs":["serverbox"]}"#).unwrap();
        let auth_blobs = PersonalAuth::new(key.clone(), blobs_only, MemKeeper::new());
        auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, digest_of(b"legacy")).await.unwrap();
        auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, RetainedBinding::Content(&is_legacy)).await.unwrap();
        assert_eq!(
            auth_blobs.verify_blob("serverbox", "op-legacy.age", b"legacy", None).await.unwrap_err().kind,
            Kind::Untrusted
        );

        // Bytes that do not hold their binding are never accepted.
        assert!(mismatch(auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"swapped", None, digest_of(b"legacy")).await.unwrap_err()));
        assert!(mismatch(
            auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"swapped", None, RetainedBinding::Content(&is_legacy)).await.unwrap_err()
        ));

        // `signed_apps` locks ordinary files and strict blob reads, but a bound retained
        // pre-signing blob stays readable so it can still be migrated.
        let apps_locked = PersonalVersions::from_json(r#"{"v":2,"signed_apps":["serverbox"],"signed_blobs":["serverbox"]}"#).unwrap();
        let auth_locked = PersonalAuth::new(key, apps_locked, MemKeeper::new());
        auth_locked.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, digest_of(b"legacy")).await.unwrap();
        assert_eq!(
            auth_locked.verify_blob("serverbox", "op-legacy.age", b"legacy", None).await.unwrap_err().kind,
            Kind::Untrusted
        );

        // A name seen signed refuses an unsigned answer on the retained path, even one
        // holding its binding, and says so before the binding is looked at.
        auth_locked.record_named_blob_written("serverbox", "op-signed.age").await.unwrap();
        let err = auth_locked.verify_retained_blob("serverbox", "op-signed.age", b"stripped", None, digest_of(b"stripped")).await.unwrap_err();
        assert!(err.kind == Kind::Untrusted && err.detail.ends_with("server stripped signature"));
    }
}
