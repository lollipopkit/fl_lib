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

mod verify;
mod versions;

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

    /// [name]'s highest version seen signed here.
    pub async fn file_version(&self, app: &str, name: &str) -> i64 {
        self.versions.lock().await.data.file_version(app, name)
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
        // A log observed live since takes the place of the one bound, as in
        // [Self::verify_snapshot_digest_observed].
        let superseded = match log {
            Some(target) => held.data.signed_log_ids.get(app).is_some_and(|known| known != target) && !observer.confirm(target)?,
            None => false,
        };
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, log, seq, superseded, observer).await
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

#[cfg(test)]
mod tests;
