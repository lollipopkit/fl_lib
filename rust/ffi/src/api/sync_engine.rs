//! `fl_sync_engine` for Dart: the operation-log sync on LK Cloud's log or a
//! folder, sealed to the account's sync key. The app's records, state and
//! keychain stay in Dart, reached through one callback answering by method
//! (`SyncHost` in fl_lib's Dart).

use std::sync::Arc;

use fl_sync_engine::key::{KeyFile, KeyRing, SyncKey};
use fl_sync_engine::lkc::{LkcKeyFile, LkcLog};
use fl_sync_engine::log::LogSync;
use fl_sync_engine::segment::SegmentSync;
use fl_sync_engine::{Error, Seal};
use flutter_rust_bridge::{DartFnFuture, frb};

use crate::api::lkc::LkcSync;
use crate::lkc_bridge::DartStore;
use crate::sync_engine_bridge::{Bridge, Call, DartFiles, DartHost, DartKeyFile, DartLog, DartSecrets};

/// What Dart answers a call with: JSON (empty for null) and bytes, or an
/// error and its kind (`remote`, `refused`, `signedOut`, `passwordMissing`;
/// anything else is the host's).
pub struct SyncReply {
    pub json: String,
    pub bytes: Option<Vec<u8>>,
    pub error: Option<String>,
    pub error_kind: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncEngineErrorKind {
    Host,
    /// Worth trying later.
    Remote,
    /// LK Cloud refused it ([SyncEngineError::detail] its reason).
    Refused,
    LogFull,
    /// A batch of a newer build: this one reads no further until updated.
    TooNew,
    Unreadable,
    /// The backup password here does not open the sync key.
    PasswordMismatch,
    /// No key file there yet beside what was synced with one.
    KeyNotHere,
    PasswordMissing,
    /// Remote key file exists, but this device has no client-side secret key.
    SecretKeyMissing,
    /// Server response failed Ed25519 signature or rollback verification.
    Untrusted,
    SignedOut,
}

#[derive(Debug)]
pub struct SyncEngineError {
    pub kind: SyncEngineErrorKind,
    /// The reason a refusal gives, the key file's id, the newer version, or
    /// what went wrong, for logs.
    pub detail: String,
}

impl From<Error> for SyncEngineError {
    fn from(e: Error) -> Self {
        use SyncEngineErrorKind as K;
        let (kind, detail) = match e {
            Error::Host(d) => (K::Host, d),
            Error::Remote(d) => (K::Remote, d),
            Error::Refused(d) => (K::Refused, d),
            Error::LogFull => (K::LogFull, String::new()),
            Error::TooNew(v) => (K::TooNew, v.to_string()),
            Error::Unreadable(d) => (K::Unreadable, d),
            Error::PasswordMismatch(id) => (K::PasswordMismatch, id),
            Error::KeyNotHere(id) => (K::KeyNotHere, id),
            Error::PasswordMissing => (K::PasswordMissing, String::new()),
            Error::SecretKeyMissing => (K::SecretKeyMissing, String::new()),
            Error::Untrusted(d) => (K::Untrusted, d),
            Error::SignedOut => (K::SignedOut, String::new()),
            Error::Pending(what) => (K::Remote, format!("{what} is not here yet")),
            Error::AppendPersistFailed { detail, .. } => (K::Host, detail),
            Error::SnapshotPersistFailed { detail, .. } => (K::Host, detail),
            Error::KeyFilePersistFailed { detail, .. } => (K::Host, detail),
        };
        Self { kind, detail }
    }
}

/// Generates a fresh 128-bit client-side secret key (`S1-XXXXX-…`).
#[frb(sync)]
pub fn generate_secret_key() -> String {
    fl_lkc::secret_key::SecretKey::generate().format().to_string()
}

/// Validates and canonicalizes a user-entered or scanned secret key; returns
/// `None` when the format or checksum is invalid.
#[frb(sync)]
pub fn normalize_secret_key(input: String) -> Option<String> {
    fl_lkc::secret_key::SecretKey::parse(&input).ok().map(|k| k.format().to_string())
}

/// Derives the combined `age scrypt` passphrase from `(password, secret_key)`.
/// Returns `None` when [secret_key] is malformed or fails checksum.
#[frb(sync)]
pub fn derive_sync_passphrase(password: String, secret_key: String) -> Option<String> {
    let key = fl_lkc::secret_key::SecretKey::parse(&secret_key).ok()?;
    Some((*key.combine_passphrase(&password)).clone())
}

type R<T> = Result<T, SyncEngineError>;

fn bridge(call: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> Bridge {
    let call: Call = Arc::new(call);
    Bridge(call)
}

/// Every sync key of the app, one per remote, and what the backup password
/// here does not open. One per process.
#[frb(opaque)]
pub struct SyncKeys(KeyRing);

impl SyncKeys {
    /// [label] begins the key file's comment line (`ServerBox sync key`);
    /// [secrets] answers `secrets.*`.
    #[frb(sync)]
    pub fn new(label: String, secrets: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> SyncKeys {
        Self(KeyRing::new(Arc::new(DartSecrets(bridge(secrets))), label))
    }

    /// The key of [account] on LK Cloud ([lkc]'s `identity.age`). Without
    /// [create], none is made where there is none.
    pub async fn of_lkc(&self, lkc: &LkcSync, account: String, create: bool) -> R<SyncKeyHandle> {
        let file: Arc<dyn KeyFile> = Arc::new(LkcKeyFile { client: lkc.client(), account });
        Ok(SyncKeyHandle(self.0.of(file, create).await?))
    }

    /// The key of a folder [id] names, its file reached through [file]
    /// (`keyFile.*`).
    pub async fn of_files(
        &self,
        id: String,
        create: bool,
        file: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static,
    ) -> R<SyncKeyHandle> {
        let file: Arc<dyn KeyFile> = Arc::new(DartKeyFile { bridge: bridge(file), id });
        Ok(SyncKeyHandle(self.0.of(file, create).await?))
    }

    /// The key files the password here does not open.
    #[frb(sync)]
    pub fn mismatch(&self) -> Vec<String> {
        self.0.mismatch().borrow().iter().cloned().collect()
    }

    /// The key files that cannot be opened because this device has no secret key.
    #[frb(sync)]
    pub fn secret_key_missing(&self) -> Vec<String> {
        self.0.secret_key_missing().borrow().iter().cloned().collect()
    }

    /// The secret key currently staged in the pending slot, if any (read only).
    pub async fn pending_secret_key(&self) -> R<Option<String>> {
        Ok(self.0.pending_secret_key().await?)
    }

    /// The secret key LK Cloud's account key is first sealed with: the one
    /// held, else one staged for it, made now when the app allows; null when
    /// none may be made. [commit_secret_key] once the account key holds it.
    pub async fn secret_key_candidate(&self) -> R<Option<String>> {
        match self.0.secret_key_candidate().await {
            Ok(key) => Ok(Some(key)),
            Err(Error::SecretKeyMissing) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Whether [account]'s LK Cloud key file ([lkc]'s `identity.age`) is
    /// sealed with a secret key, read only: one to import here.
    pub async fn lkc_sealed_with_secret_key(&self, lkc: &LkcSync, account: String) -> R<bool> {
        let file: Arc<dyn KeyFile> = Arc::new(LkcKeyFile { client: lkc.client(), account });
        Ok(self.0.sealed_with_secret_key(file).await?)
    }

    /// [candidate] as this device's secret key, settling [stage_id] when given.
    pub async fn commit_secret_key(&self, candidate: String, stage_id: Option<String>) -> R<()> {
        Ok(self.0.commit_secret_key(&candidate, stage_id.as_deref()).await?)
    }

    /// Marks [candidate] as having an in-flight/unconfirmed external remote
    /// commit (such as LK Cloud's account key), returning its stage identity.
    pub async fn stage_external_secret_key_commit(&self, candidate: String) -> R<String> {
        Ok(self.0.stage_external_secret_key_commit(&candidate).await?)
    }

    /// Clears the staged external commit identified by [stage_id] (or a
    /// crash-recovered intent when omitted) when the remote write is known not
    /// to have committed.
    pub async fn clear_external_secret_key_commit(&self, candidate: String, stage_id: Option<String>) -> R<()> {
        Ok(self.0.clear_external_secret_key_commit(&candidate, stage_id.as_deref()).await?)
    }

    /// Imports [key] as this device's secret key, coordinated with all remote
    /// key-file staging/write/promotion operations on this ring.
    pub async fn store_secret_key(&self, key: String, expect_empty_before: bool) -> R<()> {
        Ok(self.0.store_secret_key_with_prior(&key, expect_empty_before).await?)
    }

    #[frb(sync)]
    pub fn release(&self, id: String) {
        self.0.release(&id);
    }

    pub async fn forget(&self, id: String) -> R<()> {
        Ok(self.0.forget(&id).await?)
    }

    /// Before the backup password here changes from [previous].
    pub async fn password_changed(&self, previous: Option<String>) -> R<()> {
        Ok(self.0.password_changed(previous).await?)
    }

    /// Every key in use checked again: the password here changed.
    pub async fn recheck(&self) {
        self.0.recheck().await;
    }

    /// [sealed] opened with a key of a sync on here.
    pub async fn open_any(&self, sealed: Vec<u8>) -> R<Vec<u8>> {
        Ok(self.0.open_any(&sealed).await?)
    }

    /// [sealed] opened with any key this device keeps.
    pub async fn open_kept(&self, sealed: Vec<u8>) -> R<Vec<u8>> {
        Ok(self.0.open_kept(&sealed).await?)
    }
}

/// One remote's sync key.
#[frb(opaque)]
pub struct SyncKeyHandle(Arc<SyncKey>);

impl SyncKeyHandle {
    #[frb(sync)]
    pub fn id(&self) -> String {
        self.0.id()
    }

    /// [plain] sealed to the key: off Dart's isolate, as a whole backup is
    /// large.
    pub async fn seal(&self, plain: Vec<u8>) -> R<Vec<u8>> {
        Ok(self.0.seal(&plain)?)
    }

    /// [sealed] opened, once more after looking for a newer key.
    pub async fn open(&self, sealed: Vec<u8>) -> R<Vec<u8>> {
        Ok(self.0.open_fresh(&sealed).await?)
    }

    /// A name for [data] only holders of the key derive.
    #[frb(sync)]
    pub fn name_of(&self, data: Vec<u8>) -> String {
        self.0.name_of(&data)
    }

    /// Opened with the password here again, now with [force].
    pub async fn check(&self, force: bool) -> R<()> {
        Ok(self.0.check(force, true).await?)
    }
}

/// The log a [SyncLogEngine] runs on.
enum Log {
    Lkc(LogSync<DartHost, LkcLog<DartStore>, SyncKey>),
    Dart(LogSync<DartHost, DartLog, SyncKey>),
}

macro_rules! on_log {
    ($self:expr, $s:ident => $e:expr) => {
        match &$self.0 {
            Log::Lkc($s) => $e,
            Log::Dart($s) => $e,
        }
    };
}

/// The sync on a server-ordered log: an app's on LK Cloud, or one Dart
/// keeps.
#[frb(opaque)]
pub struct SyncLogEngine(Log);

impl SyncLogEngine {
    /// [host] answers the host's calls; [lkc] is the app's LK Cloud sync,
    /// [key] its account's.
    #[frb(sync)]
    pub fn new(lkc: &LkcSync, key: &SyncKeyHandle, host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> SyncLogEngine {
        Self(Log::Lkc(LogSync::new(Arc::new(DartHost(bridge(host))), Arc::new(LkcLog(lkc.client())), key.0.clone())))
    }

    /// On a log [host] keeps too (`log.*`, its blobs `files.*`).
    #[frb(sync)]
    pub fn on_dart(key: &SyncKeyHandle, host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> SyncLogEngine {
        let bridge = bridge(host);
        Self(Log::Dart(LogSync::new(Arc::new(DartHost(bridge.clone())), Arc::new(DartLog(bridge)), key.0.clone())))
    }

    /// Reads what other devices sent, then sends what this one has.
    pub async fn run(&self) -> R<()> {
        Ok(on_log!(self, s => s.sync().await)?)
    }

    pub async fn pull(&self) -> R<()> {
        Ok(on_log!(self, s => s.pull().await)?)
    }

    /// Whether the log at [seq] has batches not read here.
    pub async fn behind(&self, seq: i64) -> R<bool> {
        Ok(on_log!(self, s => s.behind(seq).await)?)
    }

    pub async fn reset(&self) -> R<()> {
        Ok(on_log!(self, s => s.reset().await)?)
    }

    /// Replaces [key] with a new one, then writes a snapshot under it.
    pub async fn rotate(&self, key: &SyncKeyHandle) -> R<()> {
        let key = key.0.clone();
        Ok(on_log!(self, s => { let key = key.clone(); s.rotate(async move { key.rotate().await }).await })?)
    }

    /// Whether the last read stopped at a newer build's batch.
    #[frb(sync)]
    pub fn too_new(&self) -> bool {
        on_log!(self, s => *s.too_new().borrow())
    }

    /// Forgets the log: the next sync reads it from its start.
    pub async fn forget(host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> R<()> {
        Ok(LogSync::<DartHost, DartLog, SyncKey>::forget(&DartHost(bridge(host))).await?)
    }

    /// The log of [account] from now on: another account's is forgotten.
    pub async fn bind(account: String, host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> R<()> {
        Ok(LogSync::<DartHost, DartLog, SyncKey>::bind(&DartHost(bridge(host)), &account).await?)
    }
}

/// The sync on a folder (WebDAV, iCloud).
#[frb(opaque)]
pub struct SyncSegmentEngine(SegmentSync<DartHost, DartFiles, SyncKey>);

impl SyncSegmentEngine {
    /// [host] answers the host's calls and the folder's (`files.*`).
    #[frb(sync)]
    pub fn new(key: &SyncKeyHandle, host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> SyncSegmentEngine {
        let bridge = bridge(host);
        Self(SegmentSync::new(Arc::new(DartHost(bridge.clone())), Arc::new(DartFiles(bridge)), key.0.clone()))
    }

    /// Reads what other devices wrote, then writes what this one has.
    pub async fn run(&self) -> R<()> {
        Ok(self.0.sync().await?)
    }

    pub async fn reset(&self) -> R<()> {
        Ok(self.0.reset().await?)
    }

    #[frb(sync)]
    pub fn too_new(&self) -> bool {
        *self.0.too_new().borrow()
    }

    pub async fn forget(host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> R<()> {
        Ok(SegmentSync::<DartHost, DartFiles, SyncKey>::forget(&DartHost(bridge(host))).await?)
    }

    /// The files of [store] from now on: another store's are forgotten.
    pub async fn bind(store: String, host: impl Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync + 'static) -> R<()> {
        Ok(SegmentSync::<DartHost, DartFiles, SyncKey>::bind(&DartHost(bridge(host)), &store).await?)
    }
}
