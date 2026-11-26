//! Signed personal LK Cloud sync: reuses the user's [`AccountKey`] Ed25519
//! signing key and persists monotonic versions locally so a compromised
//! homebase cannot forge writes, strip signatures, replay batches at other
//! sequence numbers or roll back files/snapshots.

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, RwLock};

use crate::session::{Session, Store};
use crate::sync::{Batch, Error, Kind, Signed, Snapshot, WriteSig};
use crate::team::TeamClient;
use crate::team::crypto::{self, KEY_LEN};
use crate::team::identity::AccountKey;

const VERSIONS_FORMAT: u32 = 1;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Persists [`PersonalVersions`] JSON locally before any accepted write or
/// verified read advances the monotonic watermark.
pub trait VersionKeeper: Send + Sync + 'static {
    fn save(&self, json: String) -> BoxFuture<'_, Result<(), String>>;
}

/// Monotonic watermarks kept on-device for a single personal LK Cloud account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersonalVersions {
    v: u32,
    /// Highest verified or written version per `"{app}/{name}"`.
    #[serde(default)]
    files: BTreeMap<String, i64>,
    /// Files (`"{app}/{name}"`) that have ever been observed or written signed
    /// (including explicit historical fetches whose version does not move the
    /// current watermark).
    #[serde(default)]
    signed_files: BTreeSet<String>,
    /// Apps for which any signed app file (outside log metadata/blobs) has
    /// been observed or written; once present, unsigned responses for any file
    /// in this app are rejected.
    #[serde(default)]
    signed_apps: BTreeSet<String>,
    /// Legacy boolean marker from earlier builds; treated as
    /// `signed_log_from = 1` when `signed_log_from` has no entry for the app.
    #[serde(default)]
    signed_logs: BTreeSet<String>,
    /// Lowest log sequence number at which a signed batch or snapshot was
    /// observed or written for an app. Unsigned batches/snapshots at or above
    /// this sequence are rejected while unconsumed legacy entries below it
    /// remain readable during migration.
    #[serde(default)]
    signed_log_from: BTreeMap<String, i64>,
    /// Highest verified or written snapshot seq per app (keyed by app rather
    /// than unsigned `Sync-Log` header so a compromised server cannot bypass
    /// rollback checks by fabricating a new log id).
    #[serde(default)]
    snapshots: BTreeMap<String, i64>,
    /// Persisted `app -> (idempotency_key -> seq)` bindings so a compromised
    /// server cannot replay a signed batch at a different sequence number,
    /// even across process restarts.
    #[serde(default)]
    taken: BTreeMap<String, BTreeMap<String, i64>>,
}

impl Default for PersonalVersions {
    fn default() -> Self {
        Self {
            v: VERSIONS_FORMAT,
            files: BTreeMap::new(),
            signed_files: BTreeSet::new(),
            signed_apps: BTreeSet::new(),
            signed_logs: BTreeSet::new(),
            signed_log_from: BTreeMap::new(),
            snapshots: BTreeMap::new(),
            taken: BTreeMap::new(),
        }
    }
}

impl PersonalVersions {
    pub fn from_json(json: &str) -> Result<Self, Error> {
        if json.trim().is_empty() {
            return Ok(Self::default());
        }
        let parsed: Self = serde_json::from_str(json).map_err(|e| Error::new(Kind::Invalid, format!("personal versions: {e}")))?;
        if parsed.v != VERSIONS_FORMAT {
            return Err(Error::new(Kind::Invalid, format!("personal versions: unsupported version {}", parsed.v)));
        }
        Ok(parsed)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("plain JSON")
    }

    pub fn file_version(&self, app: &str, name: &str) -> i64 {
        self.files.get(&file_key(app, name)).copied().unwrap_or(0)
    }

    /// Whether any signed file, log batch, or snapshot has ever been recorded
    /// for [app] on this device.
    pub fn is_app_signed(&self, app: &str) -> bool {
        if self.signed_apps.contains(app)
            || self.signed_logs.contains(app)
            || self.signed_log_from.contains_key(app)
            || self.snapshots.contains_key(app)
        {
            return true;
        }
        let prefix = format!("{app}/");
        self.files.keys().any(|k| k.starts_with(&prefix))
            || self.signed_files.iter().any(|k| k.starts_with(&prefix))
    }

    fn mark_file_signed(&mut self, app: &str, name: &str) {
        self.signed_files.insert(file_key(app, name));
        // Writing the sync key file (`identity.age`) or log blobs (`op-*`)
        // during migration must not lock out pre-existing unsigned backups in
        // the same app; regular app files activate the app-wide file marker.
        if is_app_file(name) {
            self.signed_apps.insert(app.to_string());
        }
    }

    fn saw_file(&mut self, app: &str, name: &str, version: i64) {
        self.mark_file_signed(app, name);
        let entry = self.files.entry(file_key(app, name)).or_insert(0);
        *entry = (*entry).max(version);
    }

    fn file_requires_signature(&self, app: &str, name: &str) -> bool {
        let key = file_key(app, name);
        self.files.get(&key).copied().unwrap_or(0) > 0
            || self.signed_files.contains(&key)
            || self.signed_apps.contains(app)
    }

    fn log_signed_from(&self, app: &str) -> Option<i64> {
        let from = self.signed_log_from.get(app).copied();
        if self.signed_logs.contains(app) {
            return Some(from.map_or(1, |s| s.min(1)));
        }
        from
    }

    fn mark_log_signed_at(&mut self, app: &str, seq: i64) {
        let initial = if self.signed_logs.contains(app) { seq.min(1) } else { seq };
        let entry = self.signed_log_from.entry(app.to_string()).or_insert(initial);
        *entry = (*entry).min(initial);
    }

    fn record_taken(&mut self, app: &str, idem: &str, seq: i64, what: &str) -> Result<(), Error> {
        let app_taken = self.taken.entry(app.to_string()).or_default();
        if let Some(&prev_seq) = app_taken.get(idem)
            && prev_seq != seq
        {
            return Err(untrusted(format!("{what}: batch replayed at seq {seq} (was {prev_seq})")));
        }
        app_taken.insert(idem.to_string(), seq);
        Ok(())
    }

    fn snapshot_seq(&self, app: &str) -> i64 {
        self.snapshots.get(app).copied().unwrap_or(0)
    }

    fn saw_snapshot(&mut self, app: &str, seq: i64) {
        self.mark_log_signed_at(app, seq);
        let entry = self.snapshots.entry(app.to_string()).or_insert(0);
        *entry = (*entry).max(seq);
    }
}

fn is_app_file(name: &str) -> bool {
    name != "identity.age" && !name.starts_with("op-")
}

fn file_key(app: &str, name: &str) -> String {
    format!("{app}/{name}")
}

fn digest(body: &[u8]) -> [u8; KEY_LEN] {
    *blake3::hash(body).as_bytes()
}

fn untrusted(what: impl Into<String>) -> Error {
    Error::new(Kind::Untrusted, what)
}

struct VersionState {
    data: PersonalVersions,
    /// True when a committed remote write advanced `data` in memory but
    /// `VersionKeeper::save` has not yet succeeded for it.
    dirty: bool,
}

/// Signs outgoing writes and verifies incoming reads for one user's personal
/// LK Cloud sync space (`epoch = 0`, `owner = account.user_id()`).
pub struct PersonalAuth {
    key: RwLock<AccountKey>,
    versions: AsyncMutex<VersionState>,
    keeper: Arc<dyn VersionKeeper>,
    published: AsyncMutex<bool>,
}

impl PersonalAuth {
    pub fn new(key: AccountKey, versions: PersonalVersions, keeper: Arc<dyn VersionKeeper>) -> Self {
        Self {
            key: RwLock::new(key),
            versions: AsyncMutex::new(VersionState { data: versions, dirty: false }),
            keeper,
            published: AsyncMutex::new(false),
        }
    }

    /// Replaces the open account key (for example after another device rotated
    /// it), keeping the accumulated monotonic version watermarks.
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

    pub async fn user_id(&self) -> String {
        self.key.read().await.user_id().to_string()
    }

    pub async fn is_app_signed(&self, app: &str) -> bool {
        self.versions.lock().await.data.is_app_signed(app)
    }

    /// Retries persisting any committed write watermarks whose previous
    /// [`VersionKeeper::save`] failed, without re-sending remote writes.
    pub async fn flush_pending_versions(&self) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        if !held.dirty {
            return Ok(());
        }
        self.keeper
            .save(held.data.to_json())
            .await
            .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
        held.dirty = false;
        Ok(())
    }

    /// Ensures the current signing public key is published on `/v2/keys` so
    /// homebase accepts `X-Signature` headers. Never performs an unchained
    /// reset when `/v2/keys` already holds a different signing key.
    pub async fn ensure_published<S: Store>(&self, session: &Arc<Session<S>>, force: bool) -> Result<(), Error> {
        let mut done = self.published.lock().await;
        if *done && !force {
            return Ok(());
        }
        let key = self.key.read().await.clone();
        TeamClient::new(session.clone()).publish_no_reset(&key).await.map_err(|e| match e {
            crate::team::TeamError::SignedOut => Error::new(Kind::SignedOut, e.to_string()),
            crate::team::TeamError::Unreachable(d) => Error::new(Kind::Unreachable, d),
            crate::team::TeamError::Refused(r) => Error::new(Kind::Refused(r), "publish signing key refused"),
            crate::team::TeamError::Untrusted(d) => Error::new(Kind::Untrusted, d),
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
        self.record_committed(|v| {
            v.saw_file(app, name, version);
            Ok(())
        })
        .await
    }

    /// Records a committed signed batch append at [seq] under [idempotency_key].
    pub async fn record_batch_written(&self, app: &str, idempotency_key: &str, seq: i64) -> Result<(), Error> {
        let what = format!("{app}/log batch {seq}");
        self.record_committed(|v| {
            v.record_taken(app, idempotency_key, seq, &what)?;
            v.mark_log_signed_at(app, seq);
            Ok(())
        })
        .await
    }

    pub async fn record_snapshot_written(&self, app: &str, seq: i64) -> Result<(), Error> {
        self.record_committed(|v| {
            v.saw_snapshot(app, seq);
            Ok(())
        })
        .await
    }

    /// Verifies a downloaded file's signature and monotonic version.
    ///
    /// When `enforce_monotonic` is false (explicitly fetching an older version
    /// from history via `download_version`), the signature is still verified
    /// against this account's own key history and recorded as signed without
    /// failing on an older version number or moving the current watermark.
    pub async fn verify_file(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        self.verify_file_digest(app, name, &digest(body), signed, enforce_monotonic).await
    }

    /// Streaming variant of [`Self::verify_file`] taking a precomputed blake3 digest.
    pub async fn verify_file_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        let Some(s) = signed else {
            // Checked under the versions lock to avoid TOCTOU races with
            // concurrent signed writes/reads.
            // TODO(migration): reject unsigned personal files unconditionally
            // once pre-signing uploads are no longer present.
            let mut held = self.versions.lock().await;
            let seen = held.data.file_version(app, name);
            if held.data.file_requires_signature(app, name) {
                return Err(untrusted(format!("{app}/{name}: server stripped signature (expected version >= {seen})")));
            }
            if held.dirty {
                self.keeper
                    .save(held.data.to_json())
                    .await
                    .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
                held.dirty = false;
            }
            return Ok(());
        };
        let version = s.version.ok_or_else(|| untrusted(format!("{app}/{name}: signed file missing version")))?;
        if version <= 0 {
            return Err(untrusted(format!("{app}/{name}: invalid version {version}")));
        }
        let owner = self.verify_own_key(s, &format!("{app}/{name}")).await?;
        let msg = crypto::sync_file_message(&owner, app, name, 0, version, body_digest);
        verify_sig(s, &msg, &format!("{app}/{name}"))?;
        if enforce_monotonic {
            self.persist_checked(|v| {
                let seen = v.file_version(app, name);
                if version < seen {
                    return Err(untrusted(format!("{app}/{name}: version rollback ({version} < {seen})")));
                }
                v.saw_file(app, name, version);
                Ok(())
            })
            .await?;
        } else {
            self.persist_checked(|v| {
                v.mark_file_signed(app, name);
                Ok(())
            })
            .await?;
        }
        Ok(())
    }

    /// Verifies a log batch's signature and checks that its idempotency key is
    /// not replayed at a different sequence number.
    pub async fn verify_batch(&self, app: &str, log: Option<&str>, batch: &Batch) -> Result<(), Error> {
        self.verify_batches(app, log, std::slice::from_ref(batch)).await
    }

    /// Verifies a page of log batches and persists all new replay bindings and
    /// log signing markers in a single atomic [`VersionKeeper::save`] call.
    pub async fn verify_batches(&self, app: &str, _log: Option<&str>, batches: &[Batch]) -> Result<(), Error> {
        let mut signed_items: Vec<(String, i64, String)> = Vec::new();
        let mut unsigned_seqs: Vec<i64> = Vec::new();
        for batch in batches {
            let what = format!("{app}/log batch {}", batch.seq);
            let Some(s) = batch.signed.as_ref() else {
                unsigned_seqs.push(batch.seq);
                continue;
            };
            let idem = batch.idempotency_key.as_deref().ok_or_else(|| untrusted(format!("{what}: missing idempotency key")))?;
            let owner = self.verify_own_key(s, &what).await?;
            let msg = crypto::sync_batch_message(&owner, app, 0, &digest(&batch.body), idem);
            verify_sig(s, &msg, &what)?;
            signed_items.push((idem.to_string(), batch.seq, what));
        }
        if signed_items.is_empty() {
            let mut held = self.versions.lock().await;
            if !unsigned_seqs.is_empty()
                && let Some(from) = held.data.log_signed_from(app)
            {
                for seq in unsigned_seqs {
                    if seq >= from {
                        return Err(untrusted(format!("{app}/log batch {seq}: server stripped signature")));
                    }
                }
            }
            if held.dirty {
                self.keeper
                    .save(held.data.to_json())
                    .await
                    .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
                held.dirty = false;
            }
            return Ok(());
        }
        self.persist_checked(|v| {
            for (idem, seq, what) in &signed_items {
                v.record_taken(app, idem, *seq, what)?;
                v.mark_log_signed_at(app, *seq);
            }
            if let Some(from) = v.log_signed_from(app) {
                for &seq in &unsigned_seqs {
                    if seq >= from {
                        return Err(untrusted(format!("{app}/log batch {seq}: server stripped signature")));
                    }
                }
            }
            Ok(())
        })
        .await
    }

    /// Verifies a log snapshot's signature and checks that `seq` does not roll
    /// back for the app.
    ///
    /// Note on homebase's contract: `sync_snapshot_message` signs
    /// `(owner, app, epoch, seq, digest)` and does not authenticate `Sync-Log`,
    /// nor does homebase define a verifiable log-reset record. The snapshot
    /// watermark therefore stays strictly monotonic per app and never resets
    /// on an unsigned `Sync-Log` change.
    pub async fn verify_snapshot(&self, app: &str, snapshot: &Snapshot, body: &[u8]) -> Result<(), Error> {
        self.verify_snapshot_digest(app, snapshot, &digest(body)).await
    }

    /// Streaming variant of [`Self::verify_snapshot`] taking a precomputed blake3 digest.
    pub async fn verify_snapshot_digest(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let Some(s) = snapshot.signed.as_ref() else {
            // TODO(migration): reject unsigned personal snapshots
            // unconditionally once pre-signing snapshots are replaced.
            let mut held = self.versions.lock().await;
            if held.data.snapshot_seq(app) > 0
                || held.data.log_signed_from(app).is_some_and(|from| snapshot.seq >= from)
            {
                return Err(untrusted(format!("{what}: server stripped signature")));
            }
            if held.dirty {
                self.keeper
                    .save(held.data.to_json())
                    .await
                    .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
                held.dirty = false;
            }
            return Ok(());
        };
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_snapshot_message(&owner, app, 0, snapshot.seq, body_digest);
        verify_sig(s, &msg, &what)?;
        self.persist_checked(|v| {
            let seen_seq = v.snapshot_seq(app);
            if snapshot.seq < seen_seq {
                return Err(untrusted(format!("{what}: snapshot rollback ({} < {seen_seq})", snapshot.seq)));
            }
            v.saw_snapshot(app, snapshot.seq);
            Ok(())
        })
        .await
    }

    async fn verify_own_key(&self, s: &Signed, what: &str) -> Result<String, Error> {
        let key = self.key.read().await;
        if s.signer != key.user_id() {
            return Err(untrusted(format!("{what}: signed by {}, not {}", s.signer, key.user_id())));
        }
        if !key.signing_history().any(|k| k == s.signing_key) {
            return Err(untrusted(format!("{what}: signing key not in account key history")));
        }
        Ok(key.user_id().to_string())
    }

    /// Read-path persistence: only advances in-memory state once `keeper.save`
    /// succeeds so an unpersisted read does not silently advance watermarks.
    async fn persist_checked(&self, f: impl FnOnce(&mut PersonalVersions) -> Result<(), Error>) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        f(&mut next)?;
        if next != held.data || held.dirty {
            self.keeper
                .save(next.to_json())
                .await
                .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
            held.data = next;
            held.dirty = false;
        }
        Ok(())
    }

    /// Write-path persistence: updates in-memory state immediately after the
    /// remote write has already committed, marking state dirty if `keeper.save`
    /// fails so persistence can be retried without resending the remote write.
    async fn record_committed(&self, f: impl FnOnce(&mut PersonalVersions) -> Result<(), Error>) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        f(&mut next)?;
        let changed = next != held.data;
        if changed {
            held.data = next;
            held.dirty = true;
        }
        if held.dirty {
            self.keeper
                .save(held.data.to_json())
                .await
                .map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
            held.dirty = false;
        }
        Ok(())
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
    use std::sync::atomic::{AtomicBool, Ordering};

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

    fn auth_for(key: AccountKey) -> (PersonalAuth, Arc<MemKeeper>) {
        let keeper = MemKeeper::new();
        let auth = PersonalAuth::new(key, PersonalVersions::from_json("").unwrap(), keeper.clone());
        (auth, keeper)
    }

    #[tokio::test]
    async fn file_sign_verify_and_rollback_detection() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let body1 = b"age-cipher-1";
        let sig1 = auth.sign_file("serverbox", "bak", 1, body1).await;
        let signed1 = Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig1.signature, version: Some(1) };
        auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap();
        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 2);

        // Tampered body fails signature check.
        assert_eq!(auth.verify_file("serverbox", "bak", b"tampered", Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

        // Advance to version 2, then server attempts rollback to version 1.
        let body2 = b"age-cipher-2";
        let sig2 = auth.sign_file("serverbox", "bak", 2, body2).await;
        let signed2 = Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig2.signature, version: Some(2) };
        auth.verify_file("serverbox", "bak", body2, Some(&signed2), true).await.unwrap();
        assert_eq!(auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

        // Explicit historical version fetch verifies signature without rollback error.
        auth.verify_file("serverbox", "bak", body1, Some(&signed1), false).await.unwrap();

        // Stripping signature after seeing signed version is rejected — even for a new blob name!
        assert_eq!(auth.verify_file("serverbox", "bak", body2, None, true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(auth.verify_file("serverbox", "blob-new.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);

        // Persisted JSON restores the watermark.
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        assert_eq!(reloaded.file_version("serverbox", "bak"), 2);
    }

    #[tokio::test]
    async fn forged_key_and_batch_replay_are_rejected() {
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
            signed: Some(Signed {
                signer: "u1".into(),
                signing_key: attacker.signing_public(),
                signature: BASE64.encode(crypto::sign(attacker.signing(), &msg)),
                version: None,
            }),
        };
        assert_eq!(auth.verify_batch("serverbox", Some("log1"), &forged).await.unwrap_err().kind, Kind::Untrusted);

        // Valid batch accepted, replayed at another seq (even with a forged log id) rejected.
        let good_sig = auth.sign_batch("serverbox", "idem-123456789012", body).await;
        let good = Batch {
            seq: 1,
            body: body.to_vec(),
            epoch: None,
            idempotency_key: Some("idem-123456789012".into()),
            signed: Some(Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: good_sig.signature, version: None }),
        };
        auth.verify_batch("serverbox", Some("log1"), &good).await.unwrap();
        let replayed = Batch { seq: 2, ..good.clone() };
        assert_eq!(auth.verify_batch("serverbox", Some("fake-log-2"), &replayed).await.unwrap_err().kind, Kind::Untrusted);

        // Stripped signature on later batch rejected.
        let unsigned = Batch { seq: 3, signed: None, ..good };
        assert_eq!(auth.verify_batch("serverbox", Some("log1"), &unsigned).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn snapshot_rollback_and_fake_log_id_are_rejected() {
        let key = AccountKey::generate("u1");
        let (auth, _) = auth_for(key.clone());

        let body5 = b"snap-5";
        let sig5 = auth.sign_snapshot("serverbox", 5, body5).await;
        let snap5 = Snapshot {
            log: "log-1".into(),
            seq: 5,
            signed: Some(Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig5.signature, version: None }),
        };
        auth.verify_snapshot("serverbox", &snap5, body5).await.unwrap();

        let body10 = b"snap-10";
        let sig10 = auth.sign_snapshot("serverbox", 10, body10).await;
        let snap10 = Snapshot {
            log: "log-1".into(),
            seq: 10,
            signed: Some(Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig10.signature, version: None }),
        };
        auth.verify_snapshot("serverbox", &snap10, body10).await.unwrap();

        // Rollback to seq 5 fails even if server fabricates a new unsigned Sync-Log header.
        let forged_log = Snapshot { log: "log-2-forged".into(), ..snap5.clone() };
        assert_eq!(auth.verify_snapshot("serverbox", &forged_log, body5).await.unwrap_err().kind, Kind::Untrusted);

        // Stripping signature on snapshot fails.
        let stripped = Snapshot { log: "log-1".into(), seq: 11, signed: None };
        assert_eq!(auth.verify_snapshot("serverbox", &stripped, b"evil").await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn update_key_rejects_other_user_and_keeper_failure_does_not_advance() {
        let key = AccountKey::generate("u1");
        let other = AccountKey::generate("u2");
        let (auth, keeper) = auth_for(key.clone());

        assert_eq!(auth.update_key(other).await.unwrap_err().kind, Kind::Untrusted);

        // When keeper fails to persist, watermark must not advance in memory.
        keeper.fail.store(true, Ordering::SeqCst);
        let body = b"cipher";
        let sig = auth.sign_file("serverbox", "bak", 1, body).await;
        let signed = Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig.signature, version: Some(1) };
        assert_eq!(auth.verify_file("serverbox", "bak", body, Some(&signed), true).await.unwrap_err().kind, Kind::Invalid);
        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
    }

    #[tokio::test]
    async fn rotated_account_key_still_verifies_previous_signatures() {
        let old = AccountKey::generate("u1");
        let rotated = old.rotated();
        let (auth, _) = auth_for(rotated);
        let body = b"older-cipher";
        let msg = crypto::sync_file_message("u1", "serverbox", "bak", 0, 1, &digest(body));
        let signed = Signed {
            signer: "u1".into(),
            signing_key: old.signing_public(),
            signature: BASE64.encode(crypto::sign(old.signing(), &msg)),
            version: Some(1),
        };
        auth.verify_file("serverbox", "bak", body, Some(&signed), true).await.unwrap();
    }

    #[test]
    fn default_personal_versions_round_trips_json() {
        let def = PersonalVersions::default();
        assert_eq!(PersonalVersions::from_json(&def.to_json()).unwrap(), def);
        assert_eq!(PersonalVersions::from_json("").unwrap(), def);
    }

    #[tokio::test]
    async fn historical_file_marks_app_signed_without_advancing_watermark() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());

        let body = b"historical-v3";
        let sig = auth.sign_file("serverbox", "bak", 3, body).await;
        let signed = Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig.signature, version: Some(3) };
        auth.verify_file("serverbox", "bak", body, Some(&signed), false).await.unwrap();

        // Watermark was NOT advanced by historical fetch.
        assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
        assert!(auth.is_app_signed("serverbox").await);

        // Subsequent unsigned response for the app is rejected (even after restart).
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        let restarted = PersonalAuth::new(key, reloaded, MemKeeper::new());
        assert_eq!(restarted.verify_file("serverbox", "bak", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
        assert_eq!(restarted.verify_file("serverbox", "other.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn taken_bindings_persist_across_restart_and_allow_same_seq_reread() {
        let key = AccountKey::generate("u1");
        let (auth, keeper) = auth_for(key.clone());
        let body = b"batch-1";
        let sig = auth.sign_batch("serverbox", "idem-123456789012", body).await;
        let batch = Batch {
            seq: 5,
            body: body.to_vec(),
            epoch: None,
            idempotency_key: Some("idem-123456789012".into()),
            signed: Some(Signed { signer: "u1".into(), signing_key: key.signing_public(), signature: sig.signature, version: None }),
        };
        auth.verify_batch("serverbox", Some("log1"), &batch).await.unwrap();

        // Reload PersonalAuth from persisted keeper JSON.
        let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
        let restarted = PersonalAuth::new(key, reloaded, MemKeeper::new());

        // Reading again at the originally recorded sequence succeeds.
        restarted.verify_batch("serverbox", Some("log1"), &batch).await.unwrap();
        // Replaying at a different sequence after restart is rejected.
        let replayed = Batch { seq: 6, ..batch };
        assert_eq!(restarted.verify_batch("serverbox", Some("log1"), &replayed).await.unwrap_err().kind, Kind::Untrusted);
    }

    #[tokio::test]
    async fn first_signed_log_write_preserves_legacy_backups_and_earlier_batches() {
        let key = AccountKey::generate("u1");
        let (auth, _) = auth_for(key.clone());

        // First signed log batch lands at seq 10.
        auth.record_batch_written("serverbox", "idem-123456789012", 10).await.unwrap();
        // Pre-existing unsigned backup file remains readable until files migrate.
        auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
        // Unconsumed legacy unsigned batch from before seq 10 remains readable.
        let legacy_batch = Batch { seq: 9, body: b"legacy-op".to_vec(), epoch: None, idempotency_key: None, signed: None };
        auth.verify_batch("serverbox", Some("log1"), &legacy_batch).await.unwrap();
        // Unsigned batch at or past seq 10 is rejected.
        let stripped = Batch { seq: 10, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(auth.verify_batch("serverbox", Some("log1"), &stripped).await.unwrap_err().kind, Kind::Untrusted);
        let stripped_after = Batch { seq: 11, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(auth.verify_batch("serverbox", Some("log1"), &stripped_after).await.unwrap_err().kind, Kind::Untrusted);

        // Signing `identity.age` (sync key file) also does not break legacy backup file,
        // while rejecting unsigned stripping on `identity.age` itself.
        auth.record_file_version("serverbox", "identity.age", 1).await.unwrap();
        auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
        assert_eq!(auth.verify_file("serverbox", "identity.age", b"stripped", None, true).await.unwrap_err().kind, Kind::Untrusted);

        // Upgrading from legacy `signed_logs` marker must keep threshold at 1 even after
        // observing a higher signed seq.
        let legacy_versions = PersonalVersions::from_json(r#"{"v":1,"signed_logs":["serverbox"]}"#).unwrap();
        let legacy_auth = PersonalAuth::new(key, legacy_versions, MemKeeper::new());
        legacy_auth.record_batch_written("serverbox", "idem-0000000000000050", 50).await.unwrap();
        let low_unsigned = Batch { seq: 2, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(legacy_auth.verify_batch("serverbox", Some("log1"), &low_unsigned).await.unwrap_err().kind, Kind::Untrusted);
    }
}
