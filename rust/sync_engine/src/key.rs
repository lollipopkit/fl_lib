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

    /// Durable device-local staging slot for a candidate secret key generated
    /// before committing a remote key file, so a failure after the remote write
    /// succeeds can recover the key on retry without locking out the remote.
    fn pending_secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { Ok(None) })
    }

    /// Stores or clears the staged candidate secret key.
    fn set_pending_secret_key(&self, _key: Option<String>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async { Ok(()) })
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
}

pub struct SyncKey {
    /// The file's store as last given: another object once signed in again.
    file: StdMutex<Arc<dyn KeyFile>>,
    ring: Arc<RingInner>,
    state: StdMutex<State>,
    checking: Mutex<()>,
}

struct RingInner {
    secrets: Arc<dyn Secrets>,
    /// The comment the key file starts with: `<label>, epoch <n>`.
    label: String,
    keys: StdMutex<HashMap<String, Arc<SyncKey>>>,
    mismatch: watch::Sender<BTreeSet<String>>,
    secret_key_missing: watch::Sender<BTreeSet<String>>,
    /// Serializes read-modify-write updates to the shared `epochs` metadata map.
    epochs_lock: Mutex<()>,
    /// Serializes read-modify-write updates to the shared `pending` map.
    pending_lock: Mutex<()>,
    /// Serializes secret-key generation/staging/persistence across all remotes
    /// sharing this [`KeyRing`].
    secret_key_init: Mutex<()>,
}

impl RingInner {
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

    async fn set_epoch_2fa(&self, id: &str, epoch: i64) -> Result<()> {
        let _guard = self.epochs_lock.lock().await;
        let mut all = self.secrets.epochs().await?;
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

    async fn set_pending(&self, id: &str, pwd: Option<String>) -> Result<()> {
        let _guard = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        if all.get(id) == pwd.as_ref() {
            return Ok(());
        }
        match pwd {
            Some(p) => all.insert(id.to_string(), p),
            None => all.remove(id),
        };
        self.secrets.set_pending(all).await
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
            keys: StdMutex::new(HashMap::new()),
            mismatch: watch::Sender::new(BTreeSet::new()),
            secret_key_missing: watch::Sender::new(BTreeSet::new()),
            epochs_lock: Mutex::new(()),
            pending_lock: Mutex::new(()),
            secret_key_init: Mutex::new(()),
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

    fn keys(&self) -> Vec<Arc<SyncKey>> {
        self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect()
    }

    /// [file]'s key, opened with the backup password here: one per remote,
    /// checked again at most every minute. [Error::PasswordMismatch] while the
    /// password does not open it. Without [create] (a restore, nothing
    /// synced), none is put where there is none: [Error::KeyNotHere].
    pub async fn of(&self, file: Arc<dyn KeyFile>, create: bool) -> Result<Arc<SyncKey>> {
        let id = file.id();
        let (key, fresh) = {
            let mut keys = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            match keys.get(&id) {
                Some(k) => {
                    *k.file.lock().unwrap_or_else(|e| e.into_inner()) = file;
                    (k.clone(), false)
                }
                None => {
                    let key = Arc::new(SyncKey { file: StdMutex::new(file), ring: self.0.clone(), state: StdMutex::new(State::default()), checking: Mutex::new(()) });
                    keys.insert(id.clone(), key.clone());
                    (key, true)
                }
            }
        };
        if let Err(e) = key.check(false, create).await {
            // A restore's lookup leaves nothing behind for a remote nothing
            // syncs to; a sync's stays, to be checked again.
            if !create && fresh {
                let mut keys = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                if keys.get(&id).is_some_and(|k| Arc::ptr_eq(k, &key)) {
                    keys.remove(&id);
                }
            }
            return Err(e);
        }
        Ok(key)
    }

    /// [id]'s remote is not synced here any more (turned off): its key is read
    /// again next time, and nothing is said of it meanwhile.
    pub fn release(&self, id: &str) {
        self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        self.0.said_ok(id);
    }

    /// [id]'s remote is gone from this device (signed out, another server): as
    /// [release], and what this device knew of its file goes too.
    pub async fn forget(&self, id: &str) -> Result<()> {
        self.release(id);
        self.0.clear_epoch(id).await?;
        self.0.set_pending(id, None).await
    }

    /// Before the backup password here changes from [previous]: the files of
    /// the syncs on here, opened with it, are to be sealed with the new one.
    /// Kept on this device until then, so a restart or a remote out of reach
    /// meanwhile loses nothing; a file already waiting keeps the password it
    /// is sealed with.
    pub async fn password_changed(&self, previous: Option<String>) -> Result<()> {
        let Some(previous) = previous.filter(|p| !p.is_empty()) else { return Ok(()) };
        let _guard = self.0.pending_lock.lock().await;
        let mut pending = self.0.secrets.pending().await?;
        let ids: Vec<String> = self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        for id in ids {
            pending.entry(id).or_insert_with(|| previous.clone());
        }
        self.0.secrets.set_pending(pending).await
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
        for (id, k) in self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).iter() {
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

    /// Every key in use checked again now: the password here changed.
    pub async fn recheck(&self) {
        let keys = self.keys();
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
        if self.lock().checked_at.is_some_and(|at| at.elapsed() < RECHECK_AFTER) {
            let id = self.id();
            if self.ring.secret_key_missing.borrow().contains(&id) {
                return Err(Error::SecretKeyMissing);
            }
            if self.ring.mismatch.borrow().contains(&id) {
                return Err(Error::PasswordMismatch(id));
            }
            if self.lock().opened.is_some() {
                return Ok(());
            }
        }
        if self.lock().identities.is_empty() {
            let kept = self.ring.secrets.kept(self.id()).await?;
            self.use_identities(lines(kept.as_deref(), false), false).await?;
        }
        // Once more when the password changed meanwhile: what was opened with
        // the one before is to be sealed with it.
        let mut pwd = self.ring.password().await?;
        loop {
            if let Err(e) = self.open(&pwd, create).await {
                if matches!(e, Error::PasswordMismatch(_))
                    || (matches!(e, Error::SecretKeyMissing)
                        && self.ring.secret_key_missing.borrow().contains(&self.id()))
                {
                    self.lock().checked_at = Some(Instant::now());
                }
                return Err(e);
            }
            let now = self.ring.password().await?;
            if *now == *pwd {
                break;
            }
            pwd = now;
        }
        // Opened with the password here as it is now: nothing waits any more.
        self.ring.set_pending(&self.id(), None).await?;
        self.lock().checked_at = Some(Instant::now());
        Ok(())
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
    ) -> Result<Option<(String, SecretKey)>> {
        let _init = self.ring.secret_key_init.lock().await;
        let (sk, generated) = match self.ring.secret_key().await? {
            Some(existing) => (existing, false),
            None => match self.ring.pending_secret_key().await? {
                Some(staged) => (staged, true),
                None => {
                    if !self.ring.secrets.allow_auto_generate_secret_key().await? {
                        return Err(Error::SecretKeyMissing);
                    }
                    let candidate = SecretKey::generate();
                    self.ring.secrets.set_pending_secret_key(Some(candidate.format().to_string())).await?;
                    (candidate, true)
                }
            },
        };
        let Some(version) = self.file().write(self.sealed(identities, epoch, pwd, &sk)?, if_version).await? else {
            return Ok(None);
        };
        if generated {
            self.ring.secrets.set_secret_key(sk.format().to_string()).await?;
            let _ = self.ring.secrets.set_pending_secret_key(None).await;
        }
        Ok(Some((version, sk)))
    }

    async fn open(&self, pwd: &str, create: bool) -> Result<()> {
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
                let Some((version, sk)) = self.write_with_secret_key(&identities, epoch, pwd, None).await? else { continue };
                self.use_identities(identities, true).await?;
                return self.opened_at(epoch, version, pwd, &sk).await;
            };
            if sk.is_some() && self.lock().opened.as_ref().is_some_and(|(v, t)| v == &version && *t == tag) {
                self.ring.said_ok(&id);
                return Ok(());
            }
            if let Some(ref sk) = sk {
                let derived = sk.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    if self.take(epoch, identities, version, pwd, sk).await? {
                        return Ok(());
                    }
                    continue;
                }
            } else if let Some(staged) = self.ring.pending_secret_key().await? {
                // Recover a candidate key whose remote write committed before
                // `set_secret_key` failed or the process exited.
                let derived = staged.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    let use_staged = {
                        let _init = self.ring.secret_key_init.lock().await;
                        if let Some(existing) = self.ring.secret_key().await? {
                            existing.format().as_str() == staged.format().as_str()
                        } else {
                            self.ring.secrets.set_secret_key(staged.format().to_string()).await?;
                            let _ = self.ring.secrets.set_pending_secret_key(None).await;
                            true
                        }
                    };
                    if !use_staged {
                        continue;
                    }
                    if self.take(epoch, identities, version, pwd, &staged).await? {
                        return Ok(());
                    }
                    continue;
                }
            }
            let epochs = self.ring.secrets.epochs().await?;
            let upgraded_2fa = epochs.contains_key(&two_fa_key(&id));
            let verified = epochs.get(&id).copied();
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
                let Some((written, sk)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version)).await? else { continue };
                self.use_identities(identities, true).await?;
                return self.opened_at(epoch, written, pwd, &sk).await;
            }
            self.lock().opened = None;
            if let Some(previous) = self.ring.secrets.pending().await?.get(&id).cloned()
                && previous != pwd
            {
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
                    let Some((written, sk)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version)).await? else { continue };
                    self.use_identities(identities, true).await?;
                    return self.opened_at(epoch, written, pwd, &sk).await;
                }
                // Keep `pending` when `sk` is missing so importing the secret
                // key later can still finish sealing the password change.
                if sk.is_some() {
                    self.ring.set_pending(&id, None).await?;
                }
            }
            let missing_sk = sk.is_none();
            self.lock().refused = Some((tag, missing_sk));
            if missing_sk {
                self.ring.said_missing(&id);
                return Err(Error::SecretKeyMissing);
            }
            self.ring.said_mismatch(&id);
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
                let Some(written) = self.file().write(self.sealed(&identities, epoch, pwd, sk)?, Some(version)).await? else { return Ok(false) };
                self.use_identities(identities, true).await?;
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
        let tag = cred_tag(pwd, Some(sk));
        // Persist the 2FA epoch and marker BEFORE caching `s.opened`, so a
        // metadata persistence failure leaves the opening state uncached and
        // retryable.
        self.ring.set_epoch_2fa(&self.id(), epoch).await?;
        {
            let mut s = self.lock();
            s.epoch = epoch;
            s.opened = Some((version, tag));
            s.refused = None;
        }
        self.ring.said_ok(&self.id());
        Ok(())
    }

    /// A new key in place of this one, put in the file first, so a device that
    /// meets what it seals finds it there ([refresh]). Fails, changing nothing
    /// here, when another device changed the file meanwhile.
    pub async fn rotate(&self) -> Result<()> {
        self.check(true, true).await?;
        let pwd = self.ring.password().await?;
        let sk = self.ring.secret_key().await?.ok_or(Error::SecretKeyMissing)?;
        let (identities, epoch, opened) = {
            let s = self.lock();
            let mut identities = vec![generate()];
            identities.extend(s.identities.iter().cloned());
            identities.truncate(HISTORY + 1);
            (identities, s.epoch, s.opened.as_ref().map(|(v, _)| v.clone()))
        };
        let Some(version) = self.file().write(self.sealed(&identities, epoch, &pwd, &sk)?, opened).await? else {
            return Err(Error::Host("identity.age changed meanwhile".into()));
        };
        self.use_identities(identities, true).await?;
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
