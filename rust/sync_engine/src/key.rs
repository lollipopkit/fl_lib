//! A remote's sync key, which seals everything synced there: age X25519
//! identities, the newest sealing and the ones it replaced ([SyncKey::rotate])
//! still opening, so a device that joins later reads what was sealed before.
//!
//! Kept in the remote's key file (`identity.age`), sealed with the backup
//! password: the one thing the password seals. Its first line, a comment
//! `age -i` skips, says the file's epoch, raised each time it is sealed with
//! a new password. Each device keeps the keys in the synced keychain
//! ([Secrets::kept]).
//!
//! The password is the remote's gate: where it does not open the file,
//! nothing syncs there ([Error::PasswordMismatch]) until it does. A device
//! that changed it ([KeyRing::password_changed]) seals the file again with the
//! new one, opening it with the one it changed from, unless another device
//! sealed it since.

use std::collections::{BTreeSet, HashMap};
use std::future::Future;
use std::io::{Read as _, Write as _};
use std::pin::Pin;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

use age::secrecy::SecretString;
use fl_lkc::secret_key::SecretKey;
use tokio::sync::{Mutex, watch};
use zeroize::Zeroizing;

use crate::{Error, Result, Seal};

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A key file's bytes and its version.
pub type Versioned = (Vec<u8>, String);

/// Where a [SyncKey] keeps its keys beside what they seal.
pub trait KeyFile: Send + Sync + 'static {
    /// Which keys these are in the synced keychain (`syncIdentity.<id>`).
    fn id(&self) -> String;

    /// The file and its version, `None` when there is none.
    fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>>;

    /// [body] as the file if it is still at [if_version] (none there for
    /// `None`): its new version, `None` when it is not. A store that does not
    /// order writes checks just before writing.
    fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>>;

    /// Whether a file may be made where none is read: false where one may only
    /// not have arrived yet (a store that does not order writes, holding what
    /// was synced with one).
    fn can_create(&self) -> BoxFuture<'_, Result<bool>>;
}

/// What the keys are kept with on this device.
pub trait Secrets: Send + Sync + 'static {
    /// The backup password, `None` (or empty) when there is none.
    fn password(&self) -> BoxFuture<'_, Result<Option<String>>>;

    /// The client-only 128-bit secret key (`S1-…`), `None` when not yet
    /// generated or imported. Never leaves the device / synced keychain.
    fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>>;

    /// Persists a generated secret key in the synced keychain.
    fn set_secret_key(&self, key: String) -> BoxFuture<'_, Result<()>>;

    /// Persists a user-imported secret key in the synced keychain without
    /// flagging it as auto-generated. Defaults to [`Self::set_secret_key`].
    fn import_secret_key(&self, key: String) -> BoxFuture<'_, Result<()>> {
        self.set_secret_key(key)
    }

    /// Durable device-local staging slot for a candidate secret key generated
    /// before committing a remote key file, so a failure after the remote write
    /// succeeds can recover the key on retry without locking out the remote.
    fn pending_secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(None) })
    }

    /// Stores or clears the staged candidate secret key. Implementors must
    /// override this for durable staging: the default rejects `Some(_)` so a
    /// candidate key can never be silently discarded, while permitting `None`
    /// for cleanup.
    fn set_pending_secret_key(&self, key: Option<String>) -> BoxFuture<'_, Result<()>> {
        match key {
            None => Box::pin(async { Ok(()) }),
            Some(_) => Box::pin(async {
                Err(Error::Host("Secrets::set_pending_secret_key is not implemented".into()))
            }),
        }
    }

    /// Whether sync may silently generate a brand-new secret key when none is
    /// stored yet. Apps that require explicit user confirmation before key
    /// creation return `false`; sync then pauses with [Error::SecretKeyMissing]
    /// without mutating a legacy remote or marking the remote as already 2FA.
    fn allow_auto_generate_secret_key(&self) -> BoxFuture<'_, Result<bool>> {
        Box::pin(async { Ok(true) })
    }

    /// The keys of [id], one per line, the newest first: kept beside the
    /// backup password, synced by the platform's keychain where it does.
    fn kept(&self, id: String) -> BoxFuture<'_, Result<Option<String>>>;

    fn set_kept(&self, id: String, identities: String) -> BoxFuture<'_, Result<()>>;

    /// Each key file's epoch as this device last opened it. Device local.
    fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>>;

    fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>>;

    /// The password each key file is still sealed with after a change here,
    /// until it is sealed again. On this device only.
    fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>>;

    fn set_pending(&self, pending: HashMap<String, String>) -> BoxFuture<'_, Result<()>>;
}

/// The keys kept after a rotation, besides the newest.
const HISTORY: usize = 3;

/// How long a check stands: one per sync would derive a key each time.
const RECHECK_AFTER: Duration = Duration::from_secs(60);

/// scrypt's `log2(N)` the key file is written with: 128 MiB, well under a
/// second on a phone. As fl_lib's `AgeCryptor`.
const WORK_FACTOR: u8 = 17;

/// The highest `log2(N)` opened.
const MAX_WORK_FACTOR: u8 = 20;

/// What a file sealed to a key starts with, as [SyncKey] seals it.
const KEY_SEALED: &[u8] = b"age-encryption.org/v1\n-> X25519 ";

/// Whether [data] is sealed to a key; one sealed with a password otherwise,
/// or not at all.
pub fn sealed_to_key(data: &[u8]) -> bool {
    data.starts_with(KEY_SEALED)
}

const TWO_FA_PREFIX: &str = "2fa:";

fn two_fa_key(id: &str) -> String {
    format!("{TWO_FA_PREFIX}{id}")
}

/// Prefix for the device-local pre-CAS write-intent record stored inside
/// `pending` (`intent:<remote_id>`). Written before a remote key-file CAS write
/// and cleared only after `epochs` and `pending` reflect the outcome, so a
/// failure in `set_epoch_2fa`/`set_pending` or a crash after commit can still
/// distinguish a committed write from an uncommitted attempt or lost CAS.
const WRITE_INTENT_PREFIX: &str = "intent:";

fn write_intent_key(id: &str) -> String {
    format!("{WRITE_INTENT_PREFIX}{id}")
}

#[derive(Clone, PartialEq, Eq)]
struct WriteIntent {
    epoch: i64,
    pwd: String,
}

impl WriteIntent {
    fn encode(&self) -> String {
        serde_json::json!({ "epoch": self.epoch, "pwd": self.pwd }).to_string()
    }

    fn decode(raw: &str) -> Option<Self> {
        let v: serde_json::Value = serde_json::from_str(raw).ok()?;
        let epoch = v["epoch"].as_i64()?;
        let pwd = v["pwd"].as_str()?.to_string();
        (!pwd.is_empty()).then_some(Self { epoch, pwd })
    }
}

/// Process-salted BLAKE3 digest of `(pwd, sk)` so plaintext credentials are
/// never retained in memory across checks.
fn cred_tag(pwd: &str, sk: Option<&SecretKey>) -> [u8; 32] {
    static SALT: OnceLock<[u8; 32]> = OnceLock::new();
    let salt = SALT.get_or_init(|| {
        let mut b = [0u8; 32];
        getrandom::fill(&mut b).expect("the OS random source");
        b
    });
    let mut h = blake3::Hasher::new_keyed(salt);
    h.update(&(pwd.len() as u32).to_be_bytes());
    h.update(pwd.as_bytes());
    match sk {
        Some(k) => {
            h.update(&[1]);
            let fmt = k.format();
            h.update(fmt.as_bytes());
        }
        None => {
            h.update(&[0]);
        }
    }
    *h.finalize().as_bytes()
}

#[derive(Clone)]
struct PendingKeyWrite {
    body: Vec<u8>,
    if_version: Option<String>,
}

#[derive(Default)]
struct State {
    /// The newest first: what is sealed now, then what was before.
    identities: Vec<String>,
    parsed: Vec<age::x25519::Identity>,
    recipient: Option<age::x25519::Recipient>,
    epoch: i64,
    /// The file's version and credential tag that opened it here: a check
    /// that finds both unchanged derives no key.
    opened: Option<(String, [u8; 32])>,
    /// The credential tag (and whether secret key was absent) refused last:
    /// with it, none is put in its place when the remote file is gone.
    refused: Option<([u8; 32], bool)>,
    checked_at: Option<Instant>,
    /// The last open stopped for a secret key none may be made of here, on
    /// a remote that does not need one imported (none there, or sealed with
    /// the password alone).
    awaiting_secret_key: bool,
    /// A committed remote key-file PUT whose local signing watermark save
    /// failed: retried with the exact same bytes and precondition so the
    /// transport flushes local state without resending PUT.
    pending_write: Option<PendingKeyWrite>,
}

#[derive(Default)]
struct PendingState {
    /// Previous passwords announced via [`KeyRing::password_changed`] per
    /// remote that have not yet been superseded by a newer password opening or
    /// committing the remote, preventing reconciliation from dropping an
    /// outstanding notification sent before the stored password updates.
    notified: HashMap<String, Vec<String>>,
}

pub struct SyncKey {
    /// The file's store as last given: another object once signed in again.
    file: StdMutex<Arc<dyn KeyFile>>,
    ring: Arc<RingInner>,
    state: StdMutex<State>,
    checking: Mutex<()>,
}

#[derive(Default)]
struct SecretKeyInitState {
    /// Staged secret key that has already committed to a remote key file via
    /// internal key-file writes and has not yet finished promotion into
    /// `secrets.secret_key()`. While set, conflicting imports are rejected so
    /// the staged key stays recoverable.
    committed_staged: Option<String>,
    /// Monotonic counter generating unique stage identities for unresolved
    /// external remote writes (such as LK Cloud's account key).
    next_external_commit_id: u64,
    /// Unresolved external remote writes keyed by stage identity
    /// (`stage_id -> canonical secret key`). Each settlement consumes only its
    /// matching stage so repeated clears or unrelated commits never drop
    /// another write's protection.
    external_commits: HashMap<String, String>,
}

#[derive(Default)]
struct KeyTable {
    keys: HashMap<String, Arc<SyncKey>>,
    /// Per-remote generation bumped whenever that remote's registered handle
    /// opens or is released, so a stale probe for one remote cannot be
    /// invalidated by unrelated activity on another remote.
    gens: HashMap<String, u64>,
}

impl KeyTable {
    fn gen_of(&self, id: &str) -> u64 {
        self.gens.get(id).copied().unwrap_or(0)
    }

    fn bump_id(&mut self, id: &str) {
        let entry = self.gens.entry(id.to_string()).or_insert(0);
        *entry = entry.wrapping_add(1);
    }

    fn is_current(&self, id: &str, handle: &SyncKey) -> bool {
        self.keys.get(id).is_some_and(|registered| std::ptr::eq(Arc::as_ptr(registered), handle))
    }
}

struct RingInner {
    secrets: Arc<dyn Secrets>,
    /// The comment the key file starts with: `<label>, epoch <n>`.
    label: String,
    keys: StdMutex<KeyTable>,
    mismatch: watch::Sender<BTreeSet<String>>,
    secret_key_missing: watch::Sender<BTreeSet<String>>,
    /// Ring-wide generation bumped on credential changes and `recheck()`,
    /// invalidating in-flight probes across all remotes.
    recheck_gen: AtomicU64,
    /// Serializes read-modify-write updates to the shared `epochs` metadata map.
    epochs_lock: Mutex<()>,
    /// Serializes read-modify-write updates to the shared `pending` map and
    /// coordinates outstanding `password_changed` notifications.
    pending_lock: Mutex<PendingState>,
    /// Serializes secret-key generation/staging/import/persistence across all
    /// remotes sharing this [`KeyRing`].
    secret_key_init: Mutex<SecretKeyInitState>,
}

const EXTERNAL_COMMIT_ID: &str = "lkc-account-key";

impl RingInner {
    async fn clear_external_commit_intent_for(&self, expected: Option<&str>) -> Result<()> {
        let _st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let key = write_intent_key(EXTERNAL_COMMIT_ID);
        let should_remove = match (all.get(&key), expected) {
            (None, _) => false,
            (Some(_), None) => true,
            (Some(raw), Some(cand)) => WriteIntent::decode(raw).is_none_or(|w| w.pwd == cand),
        };
        if should_remove {
            all.remove(&key);
            self.secrets.set_pending(all).await?;
        }
        Ok(())
    }

    fn recheck_gen(&self) -> u64 {
        self.recheck_gen.load(Ordering::Acquire)
    }

    fn bump_recheck_gen(&self) {
        self.recheck_gen.fetch_add(1, Ordering::AcqRel);
    }

    fn probe_snapshot(&self, id: &str) -> (u64, u64) {
        let table = self.keys.lock().unwrap_or_else(|e| e.into_inner());
        (self.recheck_gen(), table.gen_of(id))
    }
    fn said_mismatch(&self, id: &str) {
        self.secret_key_missing.send_if_modified(|now| now.remove(id));
        self.mismatch.send_if_modified(|now| now.insert(id.to_string()));
    }

    fn said_missing(&self, id: &str) {
        self.mismatch.send_if_modified(|now| now.remove(id));
        self.secret_key_missing.send_if_modified(|now| now.insert(id.to_string()));
    }

    fn said_ok(&self, id: &str) {
        self.mismatch.send_if_modified(|now| now.remove(id));
        self.secret_key_missing.send_if_modified(|now| now.remove(id));
    }

    async fn password(&self) -> Result<Zeroizing<String>> {
        match self.secrets.password().await? {
            Some(p) if !p.is_empty() => Ok(Zeroizing::new(p)),
            _ => Err(Error::PasswordMissing),
        }
    }

    async fn secret_key(&self) -> Result<Option<SecretKey>> {
        match self.secrets.secret_key().await? {
            Some(s) if !s.trim().is_empty() => Ok(Some(SecretKey::parse(&s).map_err(|e| Error::Unreadable(e.to_string()))?)),
            _ => Ok(None),
        }
    }

    async fn pending_secret_key(&self) -> Result<Option<SecretKey>> {
        match self.secrets.pending_secret_key().await? {
            Some(s) if !s.trim().is_empty() => Ok(Some(SecretKey::parse(&s).map_err(|e| Error::Unreadable(e.to_string()))?)),
            _ => Ok(None),
        }
    }

    /// The secret key to seal a first write with, `secret_key_init` held:
    /// the one held, else the one staged by an earlier attempt, else one
    /// made and staged now when the app allows it ([Error::SecretKeyMissing]
    /// otherwise); `true` while it is not yet this device's.
    async fn candidate_locked(&self) -> Result<(SecretKey, bool)> {
        if let Some(existing) = self.secret_key().await? {
            return Ok((existing, false));
        }
        if let Some(staged) = self.pending_secret_key().await? {
            return Ok((staged, true));
        }
        if !self.secrets.allow_auto_generate_secret_key().await? {
            return Err(Error::SecretKeyMissing);
        }
        let candidate = SecretKey::generate();
        self.secrets.set_pending_secret_key(Some(candidate.format().to_string())).await?;
        Ok((candidate, true))
    }

    /// Settles one staged external write for [formatted]. When [stage_id] is
    /// `Some`, removes only that exact stage (ignoring missing or mismatched
    /// stages); when `None` (crash recovery across restart), leaves any active
    /// in-process stages intact and only clears a durable intent once no
    /// in-process stages remain.
    async fn settle_external_commit_locked(
        &self,
        init: &mut SecretKeyInitState,
        formatted: &str,
        stage_id: Option<&str>,
    ) -> Result<()> {
        match stage_id {
            Some(id) => {
                if init.external_commits.get(id).map(String::as_str) != Some(formatted) {
                    return Ok(());
                }
                let remaining = init
                    .external_commits
                    .iter()
                    .find(|(k, _)| k.as_str() != id)
                    .map(|(_, v)| v.clone());
                // Persist intent update BEFORE removing `id` from `external_commits`
                // so a transient persistence failure remains retryable with the same `stage_id`.
                if let Some(rem) = remaining {
                    self.stage_write_intent(EXTERNAL_COMMIT_ID, 0, &rem).await?;
                } else {
                    self.clear_external_commit_intent_for(Some(formatted)).await?;
                }
                init.external_commits.remove(id);
                Ok(())
            }
            None => {
                if !init.external_commits.is_empty() {
                    return Ok(());
                }
                self.clear_external_commit_intent_for(Some(formatted)).await
            }
        }
    }

    /// [candidate] as this device's secret key, `secret_key_init` held, now
    /// that a remote holds what it sealed. When [settle_external] is `Some`,
    /// settles the matching external write stage (or crash-recovery durable
    /// intent when `Some(None)`), leaving any other unresolved stages intact.
    async fn commit_locked(
        &self,
        init: &mut SecretKeyInitState,
        candidate: &SecretKey,
        settle_external: Option<Option<&str>>,
    ) -> Result<()> {
        let formatted = candidate.format().to_string();
        match self.secret_key().await? {
            Some(existing) if existing.format().as_str() == formatted.as_str() => {}
            Some(_) => return Err(Error::Host("another secret key was stored meanwhile".into())),
            None => {
                init.committed_staged = Some(formatted.clone());
                self.secrets.set_secret_key(formatted.clone()).await?;
            }
        }
        init.committed_staged = None;
        if let Some(stage_id) = settle_external {
            self.settle_external_commit_locked(init, &formatted, stage_id).await?;
        }
        let _ = self.secrets.set_pending_secret_key(None).await;
        self.bump_recheck_gen();
        Ok(())
    }

    async fn set_epoch_2fa(&self, id: &str, epoch: i64) -> Result<()> {
        let _guard = self.epochs_lock.lock().await;
        let mut all = self.secrets.epochs().await?;
        if let Some(floor) = all.get(id).copied()
            && epoch < floor
        {
            return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
        }
        let marker = two_fa_key(id);
        if all.get(id).copied() == Some(epoch) && all.get(&marker).copied() == Some(1) {
            return Ok(());
        }
        all.insert(id.to_string(), epoch);
        all.insert(marker, 1);
        self.secrets.set_epochs(all).await
    }

    async fn clear_epoch(&self, id: &str) -> Result<()> {
        let _guard = self.epochs_lock.lock().await;
        let mut all = self.secrets.epochs().await?;
        let removed_epoch = all.remove(id).is_some();
        let removed_marker = all.remove(&two_fa_key(id)).is_some();
        if !removed_epoch && !removed_marker {
            return Ok(());
        }
        self.secrets.set_epochs(all).await
    }

    async fn clear_all_pending(&self, id: &str) -> Result<()> {
        let mut st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let removed_pwd = all.remove(id).is_some();
        let removed_intent = all.remove(&write_intent_key(id)).is_some();
        if removed_pwd || removed_intent {
            self.secrets.set_pending(all).await?;
        }
        st.notified.remove(id);
        Ok(())
    }

    async fn stage_write_intent(&self, id: &str, epoch: i64, pwd: &str) -> Result<()> {
        let _st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let key = write_intent_key(id);
        let encoded = WriteIntent { epoch, pwd: pwd.to_string() }.encode();
        if all.get(&key) == Some(&encoded) {
            return Ok(());
        }
        all.insert(key, encoded);
        self.secrets.set_pending(all).await
    }

    async fn clear_write_intent(&self, id: &str) -> Result<()> {
        let _st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        if all.remove(&write_intent_key(id)).is_some() {
            self.secrets.set_pending(all).await?;
        }
        Ok(())
    }

    async fn reconcile_pending_locked(&self, st: &mut PendingState, id: &str, settled_pwd: &str, preserve_same_pending: bool) -> Result<()> {
        let mut all = self.secrets.pending().await?;
        let current = self.secrets.password().await?;
        let notified = st.notified.get(id).is_some_and(|v| v.iter().any(|p| p == settled_pwd));
        let next = match current.as_deref().filter(|p| !p.is_empty()) {
            Some(cur) if cur != settled_pwd => Some(settled_pwd.to_string()),
            _ if notified || (preserve_same_pending && all.get(id).map(String::as_str) == Some(settled_pwd)) => {
                Some(settled_pwd.to_string())
            }
            _ => None,
        };
        let removed_intent = all.remove(&write_intent_key(id)).is_some();
        let pwd_changed = all.get(id) != next.as_ref();
        if removed_intent || pwd_changed {
            match &next {
                Some(p) => all.insert(id.to_string(), p.clone()),
                None => all.remove(id),
            };
            self.secrets.set_pending(all).await?;
        }
        match next {
            Some(_) => {
                if let Some(list) = st.notified.get_mut(id) {
                    list.retain(|p| p == settled_pwd);
                    if list.is_empty() {
                        st.notified.remove(id);
                    }
                }
            }
            None => {
                st.notified.remove(id);
            }
        }
        Ok(())
    }

    /// Records that [id]'s remote key file committed at [epoch] sealed under
    /// `(committed_pwd, sk)`, persisting the 2FA epoch and reconciling
    /// `pending[id]` + clearing the pre-CAS write intent only once both are
    /// durable, without losing a concurrent `password_changed`.
    async fn record_committed_write(&self, id: &str, epoch: i64, committed_pwd: &str) -> Result<()> {
        self.set_epoch_2fa(id, epoch).await?;
        let mut st = self.pending_lock.lock().await;
        self.reconcile_pending_locked(&mut st, id, committed_pwd, true).await
    }

    /// Clears the pre-CAS write intent and `pending[id]` after [id] opened
    /// cleanly under [opened_pwd], unless a `password_changed` notification for
    /// [opened_pwd] or a newer stored password is already outstanding.
    async fn clear_pending_if_settled(&self, id: &str, opened_pwd: &str) -> Result<()> {
        let mut st = self.pending_lock.lock().await;
        self.reconcile_pending_locked(&mut st, id, opened_pwd, false).await
    }
}

/// Every [SyncKey] of this process, one per key file, and what the backup
/// password here does not open.
#[derive(Clone)]
pub struct KeyRing(Arc<RingInner>);

impl KeyRing {
    /// [label] begins the key file's comment line (`ServerBox sync key`).
    pub fn new(secrets: Arc<dyn Secrets>, label: impl Into<String>) -> Self {
        Self(Arc::new(RingInner {
            secrets,
            label: label.into(),
            keys: StdMutex::new(KeyTable::default()),
            mismatch: watch::Sender::new(BTreeSet::new()),
            secret_key_missing: watch::Sender::new(BTreeSet::new()),
            recheck_gen: AtomicU64::new(0),
            epochs_lock: Mutex::new(()),
            pending_lock: Mutex::new(PendingState::default()),
            secret_key_init: Mutex::new(SecretKeyInitState::default()),
        }))
    }

    /// The key files the backup password here does not open. Nothing syncs to
    /// their remotes meanwhile.
    pub fn mismatch(&self) -> watch::Receiver<BTreeSet<String>> {
        self.0.mismatch.subscribe()
    }

    /// The key files that cannot be opened because this device has no
    /// client-side secret key.
    pub fn secret_key_missing(&self) -> watch::Receiver<BTreeSet<String>> {
        self.0.secret_key_missing.subscribe()
    }

    /// The secret key currently staged in the pending slot, if any (read only).
    pub async fn pending_secret_key(&self) -> Result<Option<String>> {
        let _init = self.0.secret_key_init.lock().await;
        Ok(self.0.pending_secret_key().await?.map(|k| k.format().to_string()))
    }

    /// The secret key a first remote write outside this ring (LK Cloud's
    /// account key) seals with: the one held, else one staged for it, made
    /// now when the app allows ([Error::SecretKeyMissing] otherwise). Kept
    /// as this device's by [Self::commit_secret_key] once written.
    pub async fn secret_key_candidate(&self) -> Result<String> {
        let _init = self.0.secret_key_init.lock().await;
        Ok(self.0.candidate_locked().await?.0.format().to_string())
    }

    /// [candidate] ([Self::secret_key_candidate]) as this device's secret
    /// key: a remote holds what it sealed. When [stage_id] is provided, settles
    /// only that staged external write; `None` settles a crash-recovered
    /// durable external intent only when no in-process stages remain.
    pub async fn commit_secret_key(&self, candidate: &str, stage_id: Option<&str>) -> Result<()> {
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let mut init = self.0.secret_key_init.lock().await;
        self.0.commit_locked(&mut init, &candidate, Some(stage_id)).await
    }

    /// Records that an external remote write (such as LK Cloud's account key)
    /// is about to commit using [candidate], returning a unique stage identity
    /// that settles only this write.
    ///
    /// Validates under `secret_key_init` that [candidate] matches the active
    /// secret key (when one exists) or else the current staged key, rejecting
    /// stale candidates before the caller performs the remote write.
    pub async fn stage_external_secret_key_commit(&self, candidate: &str) -> Result<String> {
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = candidate.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        if let Some(active) = self.0.secret_key().await? {
            if active.format().as_str() != formatted.as_str() {
                return Err(Error::Host("stale secret key candidate does not match active secret key".into()));
            }
        } else {
            let staged = self.0.pending_secret_key().await?;
            if staged.as_ref().is_none_or(|k| k.format().as_str() != formatted.as_str()) {
                return Err(Error::Host("stale secret key candidate does not match staged secret key".into()));
            }
        }
        self.0.stage_write_intent(EXTERNAL_COMMIT_ID, 0, &formatted).await?;
        init.next_external_commit_id = init.next_external_commit_id.wrapping_add(1);
        let stage_id = format!("ext-{}", init.next_external_commit_id);
        init.external_commits.insert(stage_id.clone(), formatted);
        Ok(stage_id)
    }

    /// Clears the staged external commit identified by [stage_id] (or a
    /// crash-recovered durable intent when `stage_id` is `None` and no
    /// in-process stages remain) once the caller knows that write did not
    /// commit.
    pub async fn clear_external_secret_key_commit(&self, candidate: &str, stage_id: Option<&str>) -> Result<()> {
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = candidate.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        self.0.settle_external_commit_locked(&mut init, &formatted, stage_id).await
    }

    /// Imports [key] as this device's secret key, serialized with all remote
    /// key-file staging/write/promotion operations on this [`KeyRing`].
    ///
    /// Rejects a conflicting import when a staged key has already committed to
    /// a remote (either in-flight in this process or recorded durably before
    /// promotion finished), preserving that staged key so recovery can finish.
    pub async fn store_secret_key(&self, key: &str) -> Result<()> {
        let expect_empty_before = self.0.secret_key().await?.is_none();
        self.store_secret_key_with_prior(key, expect_empty_before).await
    }

    /// Like [`Self::store_secret_key`], accepting whether the caller already
    /// observed an empty secret-key slot before acquiring external locks so an
    /// intervening concurrent commit between Dart and Rust cannot be overwritten.
    pub async fn store_secret_key_with_prior(&self, key: &str, expect_empty_before: bool) -> Result<()> {
        let parsed = SecretKey::parse(key).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = parsed.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        let existing = self.0.secret_key().await?;
        if expect_empty_before
            && let Some(ref cur) = existing
            && cur.format().as_str() != formatted.as_str()
        {
            return Err(Error::Host("a staged secret key committed while importing".into()));
        }
        if let Some(ref committed) = init.committed_staged
            && committed.as_str() != formatted.as_str()
        {
            return Err(Error::Host("a staged secret key already committed to a remote; refusing conflicting import".into()));
        }
        if init.external_commits.values().any(|c| c.as_str() != formatted.as_str()) {
            return Err(Error::Host("a staged secret key has an unresolved external write; refusing conflicting import".into()));
        }
        let pending = self.0.secrets.pending().await?;
        let ext_intent_key = write_intent_key(EXTERNAL_COMMIT_ID);
        if let Some(raw) = pending.get(&ext_intent_key) {
            let protected = WriteIntent::decode(raw)
                .and_then(|w| SecretKey::parse(&w.pwd).ok())
                .map(|k| k.format().to_string());
            if protected.as_deref() != Some(formatted.as_str()) {
                return Err(Error::Host("a secret key has an unresolved external write intent; refusing conflicting import".into()));
            }
        }
        let staged = self.0.pending_secret_key().await?;
        let replacing_different_key = existing.as_ref().is_some_and(|k| k.format().as_str() != formatted.as_str())
            || staged.as_ref().is_some_and(|k| k.format().as_str() != formatted.as_str());
        if replacing_different_key && pending.keys().any(|k| k.starts_with(WRITE_INTENT_PREFIX) && k != &ext_intent_key) {
            return Err(Error::Host("a secret key has an unresolved remote write intent; refusing conflicting import".into()));
        }
        if let Some(ref staged_key) = staged
            && staged_key.format().as_str() != formatted.as_str()
        {
            let has_pending_write = {
                let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                table.keys.values().any(|k| k.lock().pending_write.is_some())
            };
            if has_pending_write {
                return Err(Error::Host("a staged secret key has a pending remote commit; refusing conflicting import".into()));
            }
            if existing.is_none() {
                let epochs = self.0.secrets.epochs().await?;
                if epochs.keys().any(|k| k.starts_with(TWO_FA_PREFIX)) {
                    return Err(Error::Host("a staged secret key has a committed remote write; refusing conflicting import".into()));
                }
            }
        }
        self.0.secrets.import_secret_key(formatted).await?;
        init.committed_staged = None;
        let _ = self.0.secrets.set_pending_secret_key(None).await;
        self.0.bump_recheck_gen();
        Ok(())
    }

    fn keys(&self) -> Vec<Arc<SyncKey>> {
        self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys.values().cloned().collect()
    }

    /// [file]'s key, opened with the backup password here: one per remote,
    /// checked again at most every minute. [Error::PasswordMismatch] while the
    /// password does not open it. Without [create] (a restore, nothing
    /// synced), none is put where there is none: [Error::KeyNotHere].
    pub async fn of(&self, file: Arc<dyn KeyFile>, create: bool) -> Result<Arc<SyncKey>> {
        let id = file.id();
        let (key, fresh) = {
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            match table.keys.get(&id) {
                Some(k) => {
                    *k.file.lock().unwrap_or_else(|e| e.into_inner()) = file;
                    (k.clone(), false)
                }
                None => {
                    let key = Arc::new(SyncKey { file: StdMutex::new(file), ring: self.0.clone(), state: StdMutex::new(State::default()), checking: Mutex::new(()) });
                    table.keys.insert(id.clone(), key.clone());
                    (key, true)
                }
            }
        };
        if let Err(e) = key.check(false, create).await {
            // A restore's lookup leaves nothing behind for a remote nothing
            // syncs to; retain the handle if a committed remote write still has
            // a pending local watermark flush so the next restore can retry it.
            if !create && fresh {
                let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                if table.keys.get(&id).is_some_and(|k| Arc::ptr_eq(k, &key)) && key.lock().pending_write.is_none() {
                    table.keys.remove(&id);
                }
            }
            return Err(e);
        }
        Ok(key)
    }

    /// [id]'s remote is not synced here any more (turned off): its key is read
    /// again next time, and nothing is said of it meanwhile.
    pub fn release(&self, id: &str) {
        let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        table.keys.remove(id);
        table.bump_id(id);
        self.0.said_ok(id);
    }

    /// [id]'s remote is gone from this device (signed out, another server): as
    /// [release], and what this device knew of its file goes too.
    pub async fn forget(&self, id: &str) -> Result<()> {
        self.release(id);
        self.0.clear_epoch(id).await?;
        self.0.clear_all_pending(id).await
    }

    /// Before the backup password here changes from [previous]: the files of
    /// the syncs on here, opened with it, are to be sealed with the new one.
    /// Kept on this device until then, so a restart or a remote out of reach
    /// meanwhile loses nothing; a file already waiting keeps the password it
    /// is sealed with.
    pub async fn password_changed(&self, previous: Option<String>) -> Result<()> {
        let Some(previous) = previous.filter(|p| !p.is_empty()) else { return Ok(()) };
        let mut st = self.0.pending_lock.lock().await;
        let mut pending = self.0.secrets.pending().await?;
        let ids: Vec<String> = self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys.keys().cloned().collect();
        for id in &ids {
            pending.entry(id.clone()).or_insert_with(|| previous.clone());
        }
        self.0.secrets.set_pending(pending).await?;
        for id in ids {
            let list = st.notified.entry(id).or_default();
            if !list.iter().any(|p| p == &previous) {
                list.push(previous.clone());
            }
        }
        Ok(())
    }

    /// [sealed] opened with a key of a sync on here that the password opens,
    /// looking again for newer keys when none does: what was downloaded from
    /// one of them.
    pub async fn open_any(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        loop {
            let keys: Vec<_> = self.keys().into_iter().filter(|k| k.lock().opened.is_some()).collect();
            let identities: Vec<_> = keys.iter().flat_map(|k| k.lock().parsed.clone()).collect();
            match open_with(sealed, &identities) {
                Err(Error::Unreadable(e)) => {
                    let mut found = false;
                    for k in &keys {
                        if k.refresh().await? {
                            found = true;
                            break;
                        }
                    }
                    if !found {
                        return Err(Error::Unreadable(e));
                    }
                }
                other => return other,
            }
        }
    }

    /// [sealed] opened with any key this device keeps, whatever syncs here
    /// now: a synced backup the person picked to restore. Not one of a remote
    /// the password here is refused by.
    pub async fn open_kept(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        let mut refused = self.0.mismatch.borrow().clone();
        refused.extend(self.0.secret_key_missing.borrow().iter().cloned());
        let mut identities: Vec<String> = Vec::new();
        for (id, k) in self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys.iter() {
            if !refused.contains(id) {
                identities.extend(k.lock().identities.clone());
            }
        }
        for id in self.0.secrets.epochs().await?.into_keys() {
            if !id.starts_with(TWO_FA_PREFIX) && !refused.contains(&id) {
                identities.extend(lines(self.0.secrets.kept(id).await?.as_deref(), false));
            }
        }
        let mut seen = std::collections::HashSet::new();
        identities.retain(|i| seen.insert(i.clone()));
        if identities.is_empty() {
            return Err(Error::Unreadable("no sync key kept here".into()));
        }
        open_with(sealed, &parse_identities(&identities)?)
    }

    /// Whether [file] is there sealed with a secret key, read without opening
    /// or writing anything: a device holding none is to import the one that
    /// sealed it (or its password is not the file's). Said through
    /// [Self::secret_key_missing] until a recheck or the file opens here, only
    /// if this remote's open/release generation and ring recheck generation are
    /// still current.
    pub async fn sealed_with_secret_key(&self, file: Arc<dyn KeyFile>) -> Result<bool> {
        let id = file.id();
        let (recheck_before, id_gen_before) = self.0.probe_snapshot(&id);
        let sk_before = self.0.secret_key().await?;
        let pwd = self.0.password().await?;
        let sealed = match file.read().await? {
            Some((body, _)) => open_with_password(&body, &pwd)?.is_none(),
            None => false,
        };
        if sealed && sk_before.is_none() {
            let sk_now = self.0.secret_key().await?;
            let pwd_now = self.0.secrets.password().await?;
            if sk_now.is_none() && pwd_now.as_deref() == Some(pwd.as_str()) {
                let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                let already_opened = table.keys.get(&id).is_some_and(|k| k.lock().opened.is_some());
                if !already_opened && table.gen_of(&id) == id_gen_before && self.0.recheck_gen() == recheck_before {
                    self.0.said_missing(&id);
                }
            }
        }
        Ok(sealed)
    }

    /// Every key in use checked again now: the password or the secret key
    /// here changed.
    pub async fn recheck(&self) {
        let keys = {
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            self.0.bump_recheck_gen();
            let held: BTreeSet<String> = table.keys.keys().cloned().collect();
            table.gens.retain(|id, _| held.contains(id));
            // What only [Self::sealed_with_secret_key] said is said again when
            // asked again.
            self.0.secret_key_missing.send_if_modified(|now| {
                let before = now.len();
                now.retain(|id| held.contains(id));
                now.len() != before
            });
            table.keys.values().cloned().collect::<Vec<_>>()
        };
        for k in &keys {
            k.lock().checked_at = None;
        }
        for k in keys {
            // Said through [mismatch]; nothing else stops here.
            let _ = k.check(false, true).await;
        }
    }
}

impl SyncKey {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn file(&self) -> Arc<dyn KeyFile> {
        self.file.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn id(&self) -> String {
        self.file().id()
    }

    /// Opened with the backup password here, read again past a minute, or now
    /// with [force]. [Error::PasswordMismatch] while the password does not
    /// open the file.
    pub async fn check(&self, force: bool, create: bool) -> Result<()> {
        if force {
            self.lock().checked_at = None;
        }
        let _checking = self.checking.lock().await;
        self.check_locked(force, create).await.map(|_| ())
    }

    async fn check_locked(&self, force: bool, create: bool) -> Result<Option<(Zeroizing<String>, SecretKey)>> {
        if force {
            self.lock().checked_at = None;
        }
        if self.lock().checked_at.is_some_and(|at| at.elapsed() < RECHECK_AFTER)
            && self.lock().pending_write.is_none()
        {
            let id = self.id();
            let awaiting = self.lock().awaiting_secret_key;
            // Waiting for a secret key: one stored since (no recheck asked)
            // opens the file again at once.
            if self.ring.secret_key_missing.borrow().contains(&id) || (awaiting && self.ring.secret_key().await?.is_none()) {
                return Err(Error::SecretKeyMissing);
            }
            if !awaiting {
                if self.ring.mismatch.borrow().contains(&id) {
                    return Err(Error::PasswordMismatch(id));
                }
                if self.lock().opened.is_some() {
                    return Ok(None);
                }
            }
        }
        if self.lock().identities.is_empty() {
            let kept = self.ring.secrets.kept(self.id()).await?;
            self.use_identities(lines(kept.as_deref(), false), false).await?;
        }
        // Flush any committed remote key-file PUT whose local signing watermark
        // save previously failed, without resending the PUT.
        self.flush_pending_write().await?;
        // Once more when the password changed meanwhile: what was opened with
        // the one before is to be sealed with it.
        let mut pwd = self.ring.password().await?;
        self.lock().awaiting_secret_key = false;
        let opened_sk = loop {
            let sk = match self.open(&pwd, create).await {
                Ok(sk) => sk,
                Err(e) => {
                    if matches!(e, Error::PasswordMismatch(_))
                        || (matches!(e, Error::SecretKeyMissing)
                            && (self.lock().awaiting_secret_key || self.ring.secret_key_missing.borrow().contains(&self.id())))
                    {
                        self.lock().checked_at = Some(Instant::now());
                    }
                    return Err(e);
                }
            };
            // Reconcile pending immediately for the password that just opened
            // the remote so a concurrent password change before the next loop
            // iteration never sees a stale older pending entry.
            self.ring.clear_pending_if_settled(&self.id(), &pwd).await?;
            let now = self.ring.password().await?;
            if *now == *pwd {
                break sk;
            }
            pwd = now;
        };
        self.lock().checked_at = Some(Instant::now());
        Ok(Some((pwd, opened_sk)))
    }

    async fn flush_pending_write(&self) -> Result<()> {
        let Some(pw) = self.lock().pending_write.clone() else {
            return Ok(());
        };
        match self.file().write(pw.body, pw.if_version).await {
            Ok(_) => {
                self.lock().pending_write = None;
                Ok(())
            }
            Err(Error::KeyFilePersistFailed { detail, .. }) => Err(Error::Host(detail)),
            Err(e) => Err(e),
        }
    }

    /// Performs a conditional key-file write, separating a committed remote PUT
    /// whose local signing watermark save failed (`Ok(Some((version, Some(detail))))`)
    /// from a CAS miss (`Ok(None)` -> HTTP 412) and uncommitted transport errors.
    async fn commit_key_file(&self, body: Vec<u8>, if_version: Option<String>) -> Result<Option<(String, Option<String>)>> {
        match self.file().write(body.clone(), if_version.clone()).await {
            Ok(Some(version)) => Ok(Some((version, None))),
            Ok(None) => Ok(None),
            Err(Error::KeyFilePersistFailed { version, detail }) => {
                let mut s = self.lock();
                s.pending_write = Some(PendingKeyWrite { body, if_version });
                s.opened = None;
                s.checked_at = None;
                Ok(Some((version, Some(detail))))
            }
            Err(e) => Err(e),
        }
    }

    /// Serializes candidate secret-key acquisition, durable staging, remote
    /// conditional write, and final secret-key commit across all remotes
    /// sharing `self.ring`. Returns `Ok(None)` when the remote CAS write lost
    /// so the caller should re-read and retry.
    async fn write_with_secret_key(
        &self,
        identities: &[String],
        epoch: i64,
        pwd: &str,
        if_version: Option<String>,
    ) -> Result<Option<(String, SecretKey, Option<String>)>> {
        let mut init = self.ring.secret_key_init.lock().await;
        let id = self.id();
        let (sk, generated) = match self.ring.candidate_locked().await {
            Err(Error::SecretKeyMissing) => {
                // None may be made here: one is to be made or imported by
                // the person, and checks wait for it ([RECHECK_AFTER], or a
                // recheck) instead of opening the file again each time.
                self.lock().awaiting_secret_key = true;
                return Err(Error::SecretKeyMissing);
            }
            other => other?,
        };
        let body = self.sealed(identities, epoch, pwd, &sk)?;
        self.ring.stage_write_intent(&id, epoch, pwd).await?;
        let Some((version, persist_err)) = self.commit_key_file(body, if_version).await? else {
            let _ = self.ring.clear_write_intent(&id).await;
            return Ok(None);
        };
        if generated {
            init.committed_staged = Some(sk.format().to_string());
        }
        // The remote file is now committed under `(pwd, sk)` at `epoch`:
        // persist the epoch, reconcile `pending`, and clear the write intent
        // BEFORE `set_secret_key` or `set_kept`, so a later or concurrent
        // `password_changed` matches `pwd` instead of keeping a stale entry.
        self.ring.record_committed_write(&id, epoch, pwd).await?;
        if generated {
            self.ring.commit_locked(&mut init, &sk, None).await?;
        }
        Ok(Some((version, sk, persist_err)))
    }

    async fn open(&self, pwd: &str, create: bool) -> Result<SecretKey> {
        let id = self.id();
        loop {
            let sk = self.ring.secret_key().await?;
            let tag = cred_tag(pwd, sk.as_ref());
            let Some((body, version)) = self.file().read().await? else {
                // None to open: put there, unless this `(pwd, sk)` was refused
                // there, so nothing it seals replaces what another device sealed.
                if let Some((refused_tag, was_missing)) = self.lock().refused
                    && refused_tag == tag
                {
                    return Err(if was_missing { Error::SecretKeyMissing } else { Error::PasswordMismatch(id) });
                }
                let epochs = self.ring.secrets.epochs().await?;
                let epoch = epochs.get(&id).copied();
                let held = self.lock().identities.clone();
                let knew = epoch.is_some() && !held.is_empty();
                // A device that opened it before puts back the keys it holds;
                // another makes none where synced data may only be waiting for
                // its key.
                if !create || (!knew && !self.file().can_create().await?) {
                    return Err(Error::KeyNotHere(id));
                }
                let identities = if held.is_empty() { vec![generate()] } else { held };
                let epoch = epoch.unwrap_or(0);
                let Some((version, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, None).await? else { continue };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, version, pwd, &sk).await?;
                return Ok(sk);
            };
            if let Some(ref sk) = sk
                && self.lock().opened.as_ref().is_some_and(|(v, t)| v == &version && *t == tag)
            {
                let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                if table.is_current(&id, self) {
                    table.bump_id(&id);
                    self.ring.said_ok(&id);
                }
                return Ok(sk.clone());
            }
            let epochs = self.ring.secrets.epochs().await?;
            let upgraded_2fa = epochs.contains_key(&two_fa_key(&id));
            let verified = epochs.get(&id).copied();
            let staged = if sk.is_none() { self.ring.pending_secret_key().await? } else { None };
            if let Some(ref sk) = sk {
                let derived = sk.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    if let Some(floor) = verified
                        && epoch < floor
                    {
                        self.lock().opened = None;
                        return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
                    }
                    if self.take(epoch, identities, version, pwd, sk).await? {
                        return Ok(sk.clone());
                    }
                    continue;
                }
            } else if let Some(ref staged) = staged {
                // Recover a candidate key whose remote write committed before
                // `set_secret_key` failed or the process exited.
                let derived = staged.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    if let Some(floor) = verified
                        && epoch < floor
                    {
                        self.lock().opened = None;
                        return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
                    }
                    let use_staged = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        init.committed_staged = Some(staged.format().to_string());
                        if let Some(existing) = self.ring.secret_key().await? {
                            if existing.format().as_str() == staged.format().as_str() {
                                init.committed_staged = None;
                                let _ = self.ring.secrets.set_pending_secret_key(None).await;
                                true
                            } else {
                                init.committed_staged = None;
                                false
                            }
                        } else {
                            self.ring.secrets.set_secret_key(staged.format().to_string()).await?;
                            init.committed_staged = None;
                            let _ = self.ring.secrets.set_pending_secret_key(None).await;
                            self.ring.bump_recheck_gen();
                            true
                        }
                    };
                    if !use_staged {
                        continue;
                    }
                    if self.take(epoch, identities, version, pwd, staged).await? {
                        return Ok(staged.clone());
                    }
                    continue;
                }
            }
            // TODO(migration): drop passphrase-only fallback once existing
            // single-factor `identity.age` files have upgraded to SecretKey.
            // Never allow bare-password fallback once this remote has already
            // used 2FA, preventing a weak-password key takeover or replay.
            if !upgraded_2fa
                && let Some((old_epoch, old_identities)) = read(&body, pwd)?
                && verified.is_none_or(|v| old_epoch >= v)
            {
                let identities = self.merged(old_identities);
                let epoch = old_epoch + 1;
                let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version)).await? else { continue };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, written, pwd, &sk).await?;
                return Ok(sk);
            }
            self.lock().opened = None;
            let pending_map = self.ring.secrets.pending().await?;
            // First check any durable pre-CAS write intent: if our previous
            // remote write already committed at `intent.epoch` under
            // `intent.pwd` (e.g. `set_epoch_2fa` or `set_pending` failed
            // afterward) and the password changed again since, recover from
            // that committed state instead of treating it as a mismatch.
            if let Some(intent) = pending_map.get(&write_intent_key(&id)).and_then(|raw| WriteIntent::decode(raw))
                && intent.pwd != pwd
            {
                if sk.is_none()
                    && let Some(ref staged) = staged
                    && let Some((old_epoch, old_identities)) = read(&body, &staged.combine_passphrase(&intent.pwd))?
                    && old_epoch == intent.epoch
                    && verified.is_none_or(|v| old_epoch >= v)
                {
                    // Persist the confirmed previous commit FIRST before staging
                    // the next write intent, so a CAS miss or network error on
                    // the new write cannot lose `(old_epoch, intent.pwd)`.
                    self.ring.record_committed_write(&id, old_epoch, &intent.pwd).await?;
                    let identities = self.merged(old_identities);
                    let epoch = old_epoch + 1;
                    let (written, persist_err) = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        if let Some(existing) = self.ring.secret_key().await?
                            && existing.format().as_str() != staged.format().as_str()
                        {
                            continue;
                        }
                        let sealed = self.sealed(&identities, epoch, pwd, staged)?;
                        self.ring.stage_write_intent(&id, epoch, pwd).await?;
                        let Some((written, persist_err)) = self.commit_key_file(sealed, Some(version)).await? else {
                            let _ = self.ring.clear_write_intent(&id).await;
                            continue;
                        };
                        init.committed_staged = Some(staged.format().to_string());
                        self.ring.record_committed_write(&id, epoch, pwd).await?;
                        self.ring.commit_locked(&mut init, staged, None).await?;
                        (written, persist_err)
                    };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, written, pwd, staged).await?;
                    return Ok(staged.clone());
                }
                if let Some(ref k) = sk
                    && let Some((old_epoch, old_identities)) = read(&body, &k.combine_passphrase(&intent.pwd))?
                    && old_epoch == intent.epoch
                    && verified.is_none_or(|v| old_epoch >= v)
                {
                    // Persist the confirmed previous commit FIRST before staging
                    // the next write intent, so a CAS miss or network error on
                    // the new write cannot lose `(old_epoch, intent.pwd)`.
                    self.ring.record_committed_write(&id, old_epoch, &intent.pwd).await?;
                    let identities = self.merged(old_identities);
                    let epoch = old_epoch + 1;
                    let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version)).await? else { continue };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, written, pwd, &sk).await?;
                    return Ok(sk);
                }
            }
            if let Some(previous) = pending_map.get(&id).cloned()
                && previous != pwd
            {
                // Recover a staged key sealed under the previous password (even
                // when `upgraded_2fa` is already set) without generating a new key.
                if sk.is_none()
                    && let Some(ref staged) = staged
                    && let Some((old_epoch, old_identities)) = read(&body, &staged.combine_passphrase(&previous))?
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    let identities = self.merged(old_identities);
                    let epoch = old_epoch + 1;
                    let (written, persist_err) = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        if let Some(existing) = self.ring.secret_key().await?
                            && existing.format().as_str() != staged.format().as_str()
                        {
                            continue;
                        }
                        let sealed = self.sealed(&identities, epoch, pwd, staged)?;
                        self.ring.stage_write_intent(&id, epoch, pwd).await?;
                        let Some((written, persist_err)) = self.commit_key_file(sealed, Some(version)).await? else {
                            let _ = self.ring.clear_write_intent(&id).await;
                            continue;
                        };
                        init.committed_staged = Some(staged.format().to_string());
                        // The remote file is now committed under `(pwd, staged)`
                        // at `epoch`: persist the epoch and reconcile `pending`
                        // BEFORE `set_secret_key` so a later or concurrent
                        // `password_changed` matches `pwd` instead of keeping
                        // stale `previous`.
                        self.ring.record_committed_write(&id, epoch, pwd).await?;
                        self.ring.commit_locked(&mut init, staged, None).await?;
                        (written, persist_err)
                    };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, written, pwd, staged).await?;
                    return Ok(staged.clone());
                }
                let old = match &sk {
                    Some(k) => match read(&body, &k.combine_passphrase(&previous))? {
                        Some(found) => Some(found),
                        // TODO(migration): fallback for legacy passphrase-only key files.
                        None if !upgraded_2fa => read(&body, &previous)?,
                        None => None,
                    },
                    None if !upgraded_2fa => read(&body, &previous)?,
                    None => None,
                };
                // Not if another device sealed it since this one last opened
                // it: that one's password is the remote's now.
                if let Some((old_epoch, old_identities)) = old
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    let identities = self.merged(old_identities);
                    let epoch = old_epoch + 1;
                    let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version)).await? else { continue };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, written, pwd, &sk).await?;
                    return Ok(sk);
                }
                // Keep `pending` when `sk` is missing so importing the secret
                // key later can still finish sealing the password change.
            }
            if sk.is_some()
                && (pending_map.contains_key(&id) || pending_map.contains_key(&write_intent_key(&id)))
            {
                self.ring.clear_all_pending(&id).await?;
            }
            if sk.is_none() && self.ring.secret_key().await?.is_some() {
                // Another remote or caller stored an active secret key while we
                // checked; retry immediately so the body can be opened with it.
                continue;
            }
            let missing_sk = sk.is_none();
            self.lock().refused = Some((tag, missing_sk));
            {
                let table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                if table.is_current(&id, self) {
                    if missing_sk {
                        self.ring.said_missing(&id);
                    } else {
                        self.ring.said_mismatch(&id);
                    }
                }
            }
            if missing_sk {
                return Err(Error::SecretKeyMissing);
            }
            return Err(Error::PasswordMismatch(id));
        }
    }

    /// The keys the file holds taken, at [version]. One that lacks the key
    /// this device seals with (put there by a device that made its own at the
    /// same time, on a store that does not order writes) is written again
    /// with it, so the other devices read what it sealed; false when the file
    /// changed meanwhile.
    async fn take(&self, epoch: i64, remote: Vec<String>, version: String, pwd: &str, sk: &SecretKey) -> Result<bool> {
        let current = self.lock().identities.first().cloned();
        match current {
            Some(current) if !remote.contains(&current) => {
                // The file's newest stays first: every device then seals with it.
                let mut order = vec![remote[0].clone(), current];
                order.extend(remote.iter().skip(1).cloned());
                let identities = self.merged(order);
                let Some((written, persist_err)) = self.commit_key_file(self.sealed(&identities, epoch, pwd, sk)?, Some(version)).await? else { return Ok(false) };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    self.ring.record_committed_write(&self.id(), epoch, pwd).await?;
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, written, pwd, sk).await?;
            }
            _ => {
                self.use_identities(self.merged(remote), true).await?;
                self.opened_at(epoch, version, pwd, sk).await?;
            }
        }
        Ok(true)
    }

    async fn opened_at(&self, epoch: i64, version: String, pwd: &str, sk: &SecretKey) -> Result<()> {
        let id = self.id();
        let tag = cred_tag(pwd, Some(sk));
        // Persist the 2FA epoch and marker BEFORE caching `s.opened`, so a
        // metadata persistence failure leaves the opening state uncached and
        // retryable.
        if let Err(e) = self.ring.set_epoch_2fa(&id, epoch).await {
            self.lock().opened = None;
            return Err(e);
        }
        {
            let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
            let mut s = self.lock();
            s.epoch = epoch;
            s.opened = Some((version, tag));
            s.refused = None;
            drop(s);
            if table.is_current(&id, self) {
                table.bump_id(&id);
                self.ring.said_ok(&id);
            }
        }
        Ok(())
    }

    /// A new key in place of this one, put in the file first, so a device that
    /// meets what it seals finds it there ([refresh]). Fails, changing nothing
    /// here, when another device changed the file meanwhile.
    pub async fn rotate(&self) -> Result<()> {
        self.rotate_with_hook(|| Box::pin(async { Ok(()) })).await
    }

    #[cfg(test)]
    pub(crate) async fn rotate_after_check<F>(&self, hook: F) -> Result<()>
    where
        F: FnOnce() -> BoxFuture<'static, Result<()>>,
    {
        self.rotate_with_hook(hook).await
    }

    async fn rotate_with_hook<F>(&self, after_check: F) -> Result<()>
    where
        F: FnOnce() -> BoxFuture<'static, Result<()>>,
    {
        let _checking = self.checking.lock().await;
        // Seal with the exact `(pwd, sk)` that opened the version validated by
        // `check_locked`, keeping `epoch` and `pending` consistent even if a
        // concurrent password change occurs before sealing and PUT commit.
        let (pwd, sk) = self
            .check_locked(true, true)
            .await?
            .ok_or_else(|| Error::Host("rotate did not verify key credentials".into()))?;
        after_check().await?;
        let (identities, epoch, opened) = {
            let s = self.lock();
            let mut identities = vec![generate()];
            identities.extend(s.identities.iter().cloned());
            identities.truncate(HISTORY + 1);
            (identities, s.epoch, s.opened.as_ref().map(|(v, _)| v.clone()))
        };
        let Some((version, persist_err)) = self.commit_key_file(self.sealed(&identities, epoch, &pwd, &sk)?, opened).await? else {
            return Err(Error::Host("identity.age changed meanwhile".into()));
        };
        {
            let mut s = self.lock();
            s.opened = None;
            s.checked_at = None;
        }
        self.use_identities(identities, true).await?;
        if let Some(detail) = persist_err {
            return Err(Error::Host(detail));
        }
        self.opened_at(epoch, version, &pwd, &sk).await
    }

    /// [other] first, then those kept here, at most [HISTORY] besides the
    /// newest.
    fn merged(&self, other: Vec<String>) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mine = self.lock().identities.clone();
        other.into_iter().chain(mine).filter(|i| seen.insert(i.clone())).take(HISTORY + 1).collect()
    }

    async fn use_identities(&self, identities: Vec<String>, save: bool) -> Result<()> {
        if identities.is_empty() {
            return Ok(());
        }
        let parsed = parse_identities(&identities)?;
        let changed = {
            let mut s = self.lock();
            let changed = s.identities != identities;
            if changed || s.recipient.is_none() {
                s.recipient = Some(parsed[0].to_public());
            }
            s.identities = identities.clone();
            s.parsed = parsed;
            changed
        };
        if save && changed {
            self.ring.secrets.set_kept(self.id(), identities.join("\n")).await?;
        }
        Ok(())
    }

    fn sealed(&self, identities: &[String], epoch: i64, pwd: &str, sk: &SecretKey) -> Result<Vec<u8>> {
        let mut text = Zeroizing::new(format!("# {}, epoch {epoch}", self.ring.label));
        for i in identities {
            text.push('\n');
            text.push_str(i);
        }
        let derived = sk.combine_passphrase(pwd);
        seal_with_password(text.as_bytes(), &derived)
    }

    /// [Seal::open], once more after looking for a newer key when none kept
    /// here opens it (it was replaced elsewhere).
    pub async fn open_fresh(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        match self.open_sealed(sealed) {
            Err(Error::Unreadable(e)) => {
                if !self.refresh().await? {
                    return Err(Error::Unreadable(e));
                }
                self.open_sealed(sealed)
            }
            other => other,
        }
    }

    fn open_sealed(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        let parsed = self.lock().parsed.clone();
        open_with(sealed, &parsed)
    }
}

impl Seal for SyncKey {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>> {
        let recipient = self.lock().recipient.clone().ok_or_else(|| Error::Host("the sync key is not opened".into()))?;
        let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient)).map_err(|e| Error::Host(e.to_string()))?;
        let mut out = Vec::with_capacity(plain.len() + 256);
        let mut w = encryptor.wrap_output(&mut out).map_err(|e| Error::Host(e.to_string()))?;
        w.write_all(plain).and_then(|_| w.finish()).map_err(|e| Error::Host(e.to_string()))?;
        Ok(out)
    }

    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        self.open_sealed(sealed)
    }

    fn name_of(&self, data: &[u8]) -> String {
        let first = self.lock().identities.first().cloned().unwrap_or_default();
        fl_sync::blob_name(&first, data)
    }

    /// Reads the file again: whether it held keys not here.
    async fn refresh(&self) -> Result<bool> {
        let before: std::collections::HashSet<String> = self.lock().identities.iter().cloned().collect();
        self.check(true, true).await?;
        Ok(!self.lock().identities.iter().all(|i| before.contains(i)))
    }
}

fn generate() -> String {
    use age::secrecy::ExposeSecret;
    age::x25519::Identity::generate().to_string().expose_secret().to_string()
}

fn parse_identities(identities: &[String]) -> Result<Vec<age::x25519::Identity>> {
    identities.iter().map(|i| age::x25519::Identity::from_str(i).map_err(|e| Error::Unreadable(format!("not an age identity: {e}")))).collect()
}

fn lines(text: Option<&str>, comments: bool) -> Vec<String> {
    text.unwrap_or_default().split('\n').map(str::trim).filter(|t| !t.is_empty() && (comments || !t.starts_with('#'))).map(str::to_string).collect()
}

/// [sealed] opened with [pwd]: its epoch and keys, the newest first; `None`
/// when [pwd] does not open it. A file with no epoch line is epoch 0.
fn read(sealed: &[u8], pwd: &str) -> Result<Option<(i64, Vec<String>)>> {
    let Some(plain) = open_with_password(sealed, pwd)? else { return Ok(None) };
    let text = Zeroizing::new(String::from_utf8((*plain).clone()).map_err(|_| Error::Unreadable("identity.age is not text".into()))?);
    let all = lines(Some(&text), true);
    let epoch = all.first().filter(|l| l.starts_with('#')).and_then(|l| epoch_of(l)).unwrap_or(0);
    let identities: Vec<String> = all.into_iter().filter(|l| !l.starts_with('#')).collect();
    if identities.is_empty() {
        return Err(Error::Unreadable("identity.age holds no key".into()));
    }
    Ok(Some((epoch, identities)))
}

/// `# … epoch <n>`: the `epoch` a word of its own.
fn epoch_of(line: &str) -> Option<i64> {
    let at = line.rfind("epoch ")?;
    if at > 0 && line.as_bytes()[at - 1].is_ascii_alphanumeric() {
        return None;
    }
    let n = &line[at + "epoch ".len()..];
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    n.parse().ok()
}

/// [plain] sealed with [pwd], armored, as `age -p -a` writes it.
pub fn seal_with_password(plain: &[u8], pwd: &str) -> Result<Vec<u8>> {
    let mut recipient = age::scrypt::Recipient::new(SecretString::from(pwd.to_string()));
    recipient.set_work_factor(WORK_FACTOR);
    let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient)).map_err(|e| Error::Host(e.to_string()))?;
    let mut out = Vec::new();
    let armored = age::armor::ArmoredWriter::wrap_output(&mut out, age::armor::Format::AsciiArmor).map_err(|e| Error::Host(e.to_string()))?;
    let mut w = encryptor.wrap_output(armored).map_err(|e| Error::Host(e.to_string()))?;
    w.write_all(plain).map_err(|e| Error::Host(e.to_string()))?;
    w.finish().and_then(|armored| armored.finish()).map_err(|e| Error::Host(e.to_string()))?;
    Ok(out)
}

/// [sealed] (armored or binary) opened with [pwd]; `None` when [pwd] does not
/// open it.
pub fn open_with_password(sealed: &[u8], pwd: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let start = sealed.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(sealed.len());
    let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(&sealed[start..])).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut identity = age::scrypt::Identity::new(SecretString::from(pwd.to_string()));
    identity.set_max_work_factor(MAX_WORK_FACTOR);
    let mut r = match decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity)) {
        Ok(r) => r,
        Err(age::DecryptError::DecryptionFailed | age::DecryptError::NoMatchingKeys) => return Ok(None),
        Err(e) => return Err(Error::Unreadable(format!("{e:?}"))),
    };
    let mut out = Zeroizing::new(Vec::new());
    r.read_to_end(&mut out).map_err(|e| Error::Unreadable(e.to_string()))?;
    Ok(Some(out))
}

/// [sealed] opened with whichever of [identities] it is sealed to.
pub fn open_with(sealed: &[u8], identities: &[age::x25519::Identity]) -> Result<Vec<u8>> {
    if identities.is_empty() {
        return Err(Error::Unreadable("no key here".into()));
    }
    let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(sealed)).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut r = decryptor.decrypt(identities.iter().map(|i| i as &dyn age::Identity)).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut out = Vec::new();
    r.read_to_end(&mut out).map_err(|e| Error::Unreadable(e.to_string()))?;
    Ok(out)
}
