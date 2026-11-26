//! Signed personal LK Cloud sync: reuses the user's [`AccountKey`] Ed25519
//! signing key and persists monotonic versions locally so a compromised
//! homebase cannot forge writes, strip signatures, replay batches at other
//! sequence numbers or roll back files/snapshots.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, RwLock};

use crate::session::{Session, Store};
use crate::sync::{Batch, Error, Kind, Signed, Snapshot, WriteSig};
use crate::team::TeamClient;
use crate::team::crypto::{self, KEY_LEN};
use crate::team::identity::AccountKey;

/// Max remembered `(app, idempotency_key) -> seq` entries before reset.
const TAKEN_MAX: usize = 20_000;
const VERSIONS_FORMAT: u32 = 1;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Persists [`PersonalVersions`] JSON locally before any accepted write or
/// verified read advances the monotonic watermark.
pub trait VersionKeeper: Send + Sync + 'static {
    fn save(&self, json: String) -> BoxFuture<'_, Result<(), String>>;
}

/// Monotonic watermarks kept on-device for a single personal LK Cloud account.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersonalVersions {
    v: u32,
    /// Highest verified or written version per `"{app}/{name}"`.
    #[serde(default)]
    files: BTreeMap<String, i64>,
    /// Apps for which any signed file, batch, or snapshot has been observed or
    /// written; once present, unsigned responses for any object in this app
    /// (including newly seen blobs) are rejected.
    #[serde(default)]
    signed_apps: BTreeSet<String>,
    /// Apps whose personal log has been observed carrying signed writes.
    #[serde(default)]
    signed_logs: BTreeSet<String>,
    /// Highest verified or written snapshot seq per app (keyed by app rather
    /// than unsigned `Sync-Log` header so a compromised server cannot bypass
    /// rollback checks by fabricating a new log id).
    #[serde(default)]
    snapshots: BTreeMap<String, i64>,
}

impl PersonalVersions {
    pub fn from_json(json: &str) -> Result<Self, Error> {
        let fresh = Self { v: VERSIONS_FORMAT, ..Self::default() };
        if json.trim().is_empty() {
            return Ok(fresh);
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

    fn saw_file(&mut self, app: &str, name: &str, version: i64) {
        self.signed_apps.insert(app.to_string());
        let entry = self.files.entry(file_key(app, name)).or_insert(0);
        *entry = (*entry).max(version);
    }

    fn app_signed(&self, app: &str) -> bool {
        self.signed_apps.contains(app) || self.signed_logs.contains(app)
    }

    fn log_signed(&self, app: &str) -> bool {
        self.signed_logs.contains(app) || self.signed_apps.contains(app)
    }

    fn mark_log_signed(&mut self, app: &str) {
        self.signed_apps.insert(app.to_string());
        self.signed_logs.insert(app.to_string());
    }

    fn snapshot_seq(&self, app: &str) -> i64 {
        self.snapshots.get(app).copied().unwrap_or(0)
    }

    fn saw_snapshot(&mut self, app: &str, seq: i64) {
        self.signed_apps.insert(app.to_string());
        self.signed_logs.insert(app.to_string());
        let entry = self.snapshots.entry(app.to_string()).or_insert(0);
        *entry = (*entry).max(seq);
    }
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

/// Signs outgoing writes and verifies incoming reads for one user's personal
/// LK Cloud sync space (`epoch = 0`, `owner = account.user_id()`).
pub struct PersonalAuth {
    key: RwLock<AccountKey>,
    versions: AsyncMutex<PersonalVersions>,
    keeper: Arc<dyn VersionKeeper>,
    /// `(app, idempotency_key) -> seq`; intentionally omits the unsigned
    /// `Sync-Log` header so a server cannot replay a batch under a fake log id.
    taken: Mutex<HashMap<(String, String), i64>>,
    published: AsyncMutex<bool>,
}

impl PersonalAuth {
    pub fn new(key: AccountKey, versions: PersonalVersions, keeper: Arc<dyn VersionKeeper>) -> Self {
        Self {
            key: RwLock::new(key),
            versions: AsyncMutex::new(versions),
            keeper,
            taken: Mutex::new(HashMap::new()),
            published: AsyncMutex::new(false),
        }
    }

    /// Replaces the open account key (for example after another device rotated
    /// it), keeping the accumulated monotonic version watermarks.
    pub async fn update_key(&self, key: AccountKey) -> Result<(), Error> {
        let mut current = self.key.write().await;
        if key.user_id() != current.user_id() {
            return Err(untrusted("account key belongs to a different user"));
        }
        *current = key;
        *self.published.lock().await = false;
        Ok(())
    }

    pub async fn user_id(&self) -> String {
        self.key.read().await.user_id().to_string()
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
        self.persist_checked(|v| {
            v.saw_file(app, name, version);
            Ok(())
        })
        .await
    }

    pub async fn record_log_signed(&self, app: &str) -> Result<(), Error> {
        self.persist_checked(|v| {
            v.mark_log_signed(app);
            Ok(())
        })
        .await
    }

    pub async fn record_snapshot_written(&self, app: &str, seq: i64) -> Result<(), Error> {
        self.persist_checked(|v| {
            v.saw_snapshot(app, seq);
            Ok(())
        })
        .await
    }

    /// Verifies a downloaded file's signature and monotonic version.
    ///
    /// When `enforce_monotonic` is false (explicitly fetching an older version
    /// from history via `download_version`), the signature is still verified
    /// against this account's own key history without failing on an older
    /// version number or moving the watermark.
    pub async fn verify_file(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        self.verify_file_digest(app, name, &digest(body), signed, enforce_monotonic).await
    }

    /// Streaming variant of [`Self::verify_file`] taking a precomputed blake3 digest.
    pub async fn verify_file_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        let Some(s) = signed else {
            // Checked under the versions lock to avoid TOCTOU races with
            // concurrent signed writes/reads.
            // TODO(migration): reject unsigned personal files unconditionally
            // once pre-signing dev uploads are no longer present.
            let v = self.versions.lock().await;
            let seen = v.file_version(app, name);
            if seen > 0 || v.app_signed(app) {
                return Err(untrusted(format!("{app}/{name}: server stripped signature (expected version >= {seen})")));
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
        }
        Ok(())
    }

    /// Verifies a log batch's signature and checks that its idempotency key is
    /// not replayed at a different sequence number.
    pub async fn verify_batch(&self, app: &str, _log: Option<&str>, batch: &Batch) -> Result<(), Error> {
        let what = format!("{app}/log batch {}", batch.seq);
        let Some(s) = batch.signed.as_ref() else {
            // TODO(migration): reject unsigned personal log batches
            // unconditionally once pre-signing logs are compacted.
            let v = self.versions.lock().await;
            if v.log_signed(app) {
                return Err(untrusted(format!("{what}: server stripped signature")));
            }
            return Ok(());
        };
        let idem = batch.idempotency_key.as_deref().ok_or_else(|| untrusted(format!("{what}: missing idempotency key")))?;
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_batch_message(&owner, app, 0, &digest(&batch.body), idem);
        verify_sig(s, &msg, &what)?;
        let slot = (app.to_string(), idem.to_string());
        {
            let mut taken = self.taken.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(&prev_seq) = taken.get(&slot)
                && prev_seq != batch.seq
            {
                return Err(untrusted(format!("{what}: batch replayed at seq {} (was {prev_seq})", batch.seq)));
            }
            if taken.len() >= TAKEN_MAX && !taken.contains_key(&slot) {
                taken.clear();
            }
            taken.insert(slot, batch.seq);
        }
        self.persist_checked(|v| {
            v.mark_log_signed(app);
            Ok(())
        })
        .await
    }

    /// Verifies a log snapshot's signature and checks that `seq` does not roll
    /// back for the app.
    pub async fn verify_snapshot(&self, app: &str, snapshot: &Snapshot, body: &[u8]) -> Result<(), Error> {
        self.verify_snapshot_digest(app, snapshot, &digest(body)).await
    }

    /// Streaming variant of [`Self::verify_snapshot`] taking a precomputed blake3 digest.
    pub async fn verify_snapshot_digest(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let Some(s) = snapshot.signed.as_ref() else {
            // TODO(migration): reject unsigned personal snapshots
            // unconditionally once pre-signing snapshots are replaced.
            let v = self.versions.lock().await;
            if v.log_signed(app) || v.snapshot_seq(app) > 0 {
                return Err(untrusted(format!("{what}: server stripped signature")));
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

    async fn persist_checked(&self, f: impl FnOnce(&mut PersonalVersions) -> Result<(), Error>) -> Result<(), Error> {
        let mut held = self.versions.lock().await;
        let mut next = held.clone();
        f(&mut next)?;
        if next != *held {
            self.keeper.save(next.to_json()).await.map_err(|e| Error::new(Kind::Invalid, format!("personal versions not saved: {e}")))?;
            *held = next;
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
}
