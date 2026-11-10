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
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use age::secrecy::SecretString;
use tokio::sync::{Mutex, watch};

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

#[derive(Default)]
struct State {
    /// The newest first: what is sealed now, then what was before.
    identities: Vec<String>,
    parsed: Vec<age::x25519::Identity>,
    recipient: Option<age::x25519::Recipient>,
    epoch: i64,
    /// The file's version and the password that opened it here: a check that
    /// finds both unchanged derives no key.
    opened: Option<(String, String)>,
    /// The password the file refused last: with it, none is put in its place
    /// when it is gone.
    refused: Option<String>,
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
}

impl RingInner {
    fn said(&self, id: &str, mismatch: bool) {
        self.mismatch.send_if_modified(|now| if mismatch { now.insert(id.to_string()) } else { now.remove(id) });
    }

    async fn password(&self) -> Result<String> {
        match self.secrets.password().await? {
            Some(p) if !p.is_empty() => Ok(p),
            _ => Err(Error::PasswordMissing),
        }
    }

    async fn set_epoch(&self, id: &str, epoch: Option<i64>) -> Result<()> {
        let mut all = self.secrets.epochs().await?;
        if all.get(id).copied() == epoch {
            return Ok(());
        }
        match epoch {
            Some(e) => all.insert(id.to_string(), e),
            None => all.remove(id),
        };
        self.secrets.set_epochs(all).await
    }

    async fn set_pending(&self, id: &str, pwd: Option<String>) -> Result<()> {
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
        Self(Arc::new(RingInner { secrets, label: label.into(), keys: StdMutex::new(HashMap::new()), mismatch: watch::Sender::new(BTreeSet::new()) }))
    }

    /// The key files the backup password here does not open. Nothing syncs to
    /// their remotes meanwhile.
    pub fn mismatch(&self) -> watch::Receiver<BTreeSet<String>> {
        self.0.mismatch.subscribe()
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
        self.0.said(id, false);
    }

    /// [id]'s remote is gone from this device (signed out, another server): as
    /// [release], and what this device knew of its file goes too.
    pub async fn forget(&self, id: &str) -> Result<()> {
        self.release(id);
        self.0.set_epoch(id, None).await?;
        self.0.set_pending(id, None).await
    }

    /// Before the backup password here changes from [previous]: the files of
    /// the syncs on here, opened with it, are to be sealed with the new one.
    /// Kept on this device until then, so a restart or a remote out of reach
    /// meanwhile loses nothing; a file already waiting keeps the password it
    /// is sealed with.
    pub async fn password_changed(&self, previous: Option<String>) -> Result<()> {
        let Some(previous) = previous.filter(|p| !p.is_empty()) else { return Ok(()) };
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
        let refused = self.0.mismatch.borrow().clone();
        let mut identities: Vec<String> = Vec::new();
        for (id, k) in self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            if !refused.contains(id) {
                identities.extend(k.lock().identities.clone());
            }
        }
        for id in self.0.secrets.epochs().await?.into_keys() {
            if !refused.contains(&id) {
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
            if self.ring.mismatch.borrow().contains(&self.id()) {
                return Err(Error::PasswordMismatch(self.id()));
            }
            return Ok(());
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
                if matches!(e, Error::PasswordMismatch(_)) {
                    self.lock().checked_at = Some(Instant::now());
                }
                return Err(e);
            }
            let now = self.ring.password().await?;
            if now == pwd {
                break;
            }
            pwd = now;
        }
        // Opened with the password here as it is now: nothing waits any more.
        self.ring.set_pending(&self.id(), None).await?;
        self.lock().checked_at = Some(Instant::now());
        Ok(())
    }

    async fn open(&self, pwd: &str, create: bool) -> Result<()> {
        let id = self.id();
        loop {
            let Some((body, version)) = self.file().read().await? else {
                // None to open: put there, unless the password here was refused
                // there, so nothing it seals replaces what another device sealed.
                if self.lock().refused.as_deref() == Some(pwd) {
                    return Err(Error::PasswordMismatch(id));
                }
                let epoch = self.ring.secrets.epochs().await?.get(&id).copied();
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
                let Some(version) = self.file().write(self.sealed(&identities, epoch, pwd)?, None).await? else { continue };
                self.use_identities(identities, true).await?;
                return self.opened_at(epoch, version, pwd).await;
            };
            if self.lock().opened.as_ref().is_some_and(|(v, p)| *v == version && p == pwd) {
                self.ring.said(&id, false);
                return Ok(());
            }
            if let Some((epoch, identities)) = read(&body, pwd)? {
                if self.take(epoch, identities, version, pwd).await? {
                    return Ok(());
                }
                continue;
            }
            self.lock().opened = None;
            if let Some(previous) = self.ring.secrets.pending().await?.get(&id).cloned()
                && previous != pwd
            {
                let old = read(&body, &previous)?;
                let verified = self.ring.secrets.epochs().await?.get(&id).copied();
                // Not if another device sealed it since this one last opened
                // it: that one's password is the remote's now.
                if let Some((old_epoch, old_identities)) = old
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    let identities = self.merged(old_identities);
                    let epoch = old_epoch + 1;
                    let Some(version) = self.file().write(self.sealed(&identities, epoch, pwd)?, Some(version)).await? else { continue };
                    self.use_identities(identities, true).await?;
                    return self.opened_at(epoch, version, pwd).await;
                }
                self.ring.set_pending(&id, None).await?;
            }
            self.lock().refused = Some(pwd.to_string());
            self.ring.said(&id, true);
            return Err(Error::PasswordMismatch(id));
        }
    }

    /// The keys the file holds taken, at [version]. One that lacks the key
    /// this device seals with (put there by a device that made its own at the
    /// same time, on a store that does not order writes) is written again
    /// with it, so the other devices read what it sealed; false when the file
    /// changed meanwhile.
    async fn take(&self, epoch: i64, remote: Vec<String>, version: String, pwd: &str) -> Result<bool> {
        let current = self.lock().identities.first().cloned();
        match current {
            Some(current) if !remote.contains(&current) => {
                // The file's newest stays first: every device then seals with it.
                let mut order = vec![remote[0].clone(), current];
                order.extend(remote.iter().skip(1).cloned());
                let identities = self.merged(order);
                let Some(written) = self.file().write(self.sealed(&identities, epoch, pwd)?, Some(version)).await? else { return Ok(false) };
                self.use_identities(identities, true).await?;
                self.opened_at(epoch, written, pwd).await?;
            }
            _ => {
                self.use_identities(self.merged(remote), true).await?;
                self.opened_at(epoch, version, pwd).await?;
            }
        }
        Ok(true)
    }

    async fn opened_at(&self, epoch: i64, version: String, pwd: &str) -> Result<()> {
        {
            let mut s = self.lock();
            s.epoch = epoch;
            s.opened = Some((version, pwd.to_string()));
            s.refused = None;
        }
        self.ring.set_epoch(&self.id(), Some(epoch)).await?;
        self.ring.said(&self.id(), false);
        Ok(())
    }

    /// A new key in place of this one, put in the file first, so a device that
    /// meets what it seals finds it there ([refresh]). Fails, changing nothing
    /// here, when another device changed the file meanwhile.
    pub async fn rotate(&self) -> Result<()> {
        self.check(true, true).await?;
        let pwd = self.ring.password().await?;
        let (identities, epoch, opened) = {
            let s = self.lock();
            let mut identities = vec![generate()];
            identities.extend(s.identities.iter().cloned());
            identities.truncate(HISTORY + 1);
            (identities, s.epoch, s.opened.as_ref().map(|(v, _)| v.clone()))
        };
        let Some(version) = self.file().write(self.sealed(&identities, epoch, &pwd)?, opened).await? else {
            return Err(Error::Host("identity.age changed meanwhile".into()));
        };
        self.use_identities(identities, true).await?;
        self.opened_at(epoch, version, &pwd).await
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

    fn sealed(&self, identities: &[String], epoch: i64, pwd: &str) -> Result<Vec<u8>> {
        let mut text = format!("# {}, epoch {epoch}", self.ring.label);
        for i in identities {
            text.push('\n');
            text.push_str(i);
        }
        seal_with_password(text.as_bytes(), pwd)
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
    let text = String::from_utf8(plain).map_err(|_| Error::Unreadable("identity.age is not text".into()))?;
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
pub fn open_with_password(sealed: &[u8], pwd: &str) -> Result<Option<Vec<u8>>> {
    let start = sealed.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(sealed.len());
    let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(&sealed[start..])).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut identity = age::scrypt::Identity::new(SecretString::from(pwd.to_string()));
    identity.set_max_work_factor(MAX_WORK_FACTOR);
    let mut r = match decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity)) {
        Ok(r) => r,
        Err(age::DecryptError::DecryptionFailed | age::DecryptError::NoMatchingKeys) => return Ok(None),
        Err(e) => return Err(Error::Unreadable(format!("{e:?}"))),
    };
    let mut out = Vec::new();
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
