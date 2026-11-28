//! A remote's sync key, which seals everything synced there: age X25519
//! identities, the newest sealing and the ones it replaced ([SyncKey::rotate])
//! still opening, so a device that joins later reads what was sealed before.
//!
//! Kept in the remote's key file (`identity.age`), sealed with two factors:
//! the backup password and the client-side secret key
//! ([SecretKey::combine_passphrase]), both needed to open it; the one thing
//! they seal. A file sealed with the password alone (before the secret key)
//! opens with it until sealed again with both, and never once the remote has
//! been opened with both. Its first line, a comment `age -i` skips, says the
//! file's epoch, raised each time it is sealed with a new password. Each
//! device keeps the keys in the synced keychain ([Secrets::kept]).
//!
//! The password and the secret key are the remote's gate: where they do not
//! open the file, nothing syncs there ([Error::PasswordMismatch],
//! [Error::SecretKeyMissing]) until they do. A device
//! that changed it ([KeyRing::password_changed]) seals the file again with the
//! new one, opening it with the one it changed from, unless another device
//! sealed it since.

use std::collections::{BTreeSet, HashMap};
use std::future::Future;
use std::io::{Read as _, Write as _};
use std::pin::Pin;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

use age::secrecy::SecretString;
use fl_lkc::secret_key::SecretKey;
use tokio::sync::{Mutex, watch};
use tokio::time::Instant as MonoInstant;
use zeroize::Zeroizing;

use crate::{Error, Result, Seal};

mod crypto;
mod handle;
mod open;
mod pending;
mod ring;
mod secret_key;

pub use crypto::{open_with, open_with_password, seal_with_password};
pub use ring::KeyRing;
use crypto::*;
use pending::*;
use ring::*;

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

    /// Persists this device's watermark for a key-file write that already
    /// committed remotely at [version] ([sync_version], when signed), as
    /// [Self::write] answered with `KeyFilePersistFailed`; never by writing
    /// again. A store answering that implements this; any other never has a
    /// write to flush, and one left pending here stays.
    fn flush_committed_write(&self, _version: String, _sync_version: Option<i64>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async { Err(Error::Host("this key file keeps no committed-write watermark".into())) })
    }

    /// Whether a file may be made where none is read: false where one may only
    /// not have arrived yet (a store that does not order writes, holding what
    /// was synced with one).
    fn can_create(&self) -> BoxFuture<'_, Result<bool>>;

    /// Whether writes here are ordered (every write conditional on the version
    /// it read, checked by the store as it commits): then a verified file
    /// settles every attempt at its epoch or below, any other one at it
    /// having lost its condition.
    fn orders_writes(&self) -> bool {
        false
    }

    /// How long after it is dispatched a write here may still take effect:
    /// an attempt dispatched longer than this before a read began, which that
    /// read does not hold, is over. Measured on this process's monotonic
    /// clock; an attempt left by an earlier process counts from when this one
    /// first meets it.
    fn settle_window(&self) -> Duration {
        SETTLE_WINDOW
    }
}

/// [KeyFile::settle_window] unless a store says otherwise: past a request's
/// timeout and a synced folder's conflict resolution.
pub const SETTLE_WINDOW: Duration = Duration::from_secs(10 * 60);

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
/// `pending` (`intent:<remote_id>`): every remote key-file CAS attempt not yet
/// resolved, oldest first. One is added before its write and goes only once a
/// remote read or the write's own result settles it, so a failure in
/// `set_epoch_2fa`/`set_pending`, a crash after commit or a later attempt can
/// still tell a committed write from an uncommitted attempt or lost CAS.
const WRITE_INTENT_PREFIX: &str = "intent:";

/// Distinct namespace prefix for external account-key write intents
/// (`ext-intent:<id>`), isolated from per-remote folder write intents
/// (`intent:<remote_id>`) so folder writes and `forget` cannot remove it.
const EXTERNAL_INTENT_PREFIX: &str = "ext-intent:";

fn write_intent_key(id: &str) -> String {
    format!("{WRITE_INTENT_PREFIX}{id}")
}

fn external_intent_key(id: &str) -> String {
    format!("{EXTERNAL_INTENT_PREFIX}{id}")
}

fn validate_remote_id(id: &str) -> Result<()> {
    if id.is_empty() {
        return Err(Error::Host("remote key id cannot be empty".into()));
    }
    if id.starts_with(TWO_FA_PREFIX)
        || id.starts_with(WRITE_INTENT_PREFIX)
        || id.starts_with(EXTERNAL_INTENT_PREFIX)
    {
        return Err(Error::Host(format!("reserved remote key id prefix: {id}")));
    }
    Ok(())
}

/// This process's key for the digests that stand for credentials in memory.
fn process_salt() -> &'static [u8; 32] {
    static SALT: OnceLock<[u8; 32]> = OnceLock::new();
    SALT.get_or_init(|| {
        let mut b = [0u8; 32];
        getrandom::fill(&mut b).expect("the OS random source");
        b
    })
}

/// Process-salted BLAKE3 digest of `(pwd, sk)` so plaintext credentials are
/// never retained in memory across checks.
fn cred_tag(pwd: &str, sk: Option<&SecretKey>) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(process_salt());
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
    seq: u64,
    handle_id: u64,
    version: String,
    sync_version: Option<i64>,
}

#[derive(Default)]
struct State {
    /// The newest first: what is sealed now, then what was before.
    identities: Vec<String>,
    parsed: Vec<age::x25519::Identity>,
    recipient: Option<age::x25519::Recipient>,
    /// The identities held are not yet saved in the keychain: a save that
    /// failed is tried again by the next one, unchanged or not.
    unsaved: bool,
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
}

#[cfg(test)]
type TestTakeMergeHook = Arc<dyn Fn() -> BoxFuture<'static, ()> + Send + Sync>;

pub struct SyncKey {
    handle_id: u64,
    forget_gen: u64,
    /// `(lkc_switch_gen, lkc_account_gen)` captured when an LK Cloud account
    /// handle was made: an account switch or stale-account invalidation since
    /// then stops any new key-file write through it.
    lkc_tokens: Option<(u64, u64)>,
    /// The file's store as last given: another object once signed in again.
    file: StdMutex<Arc<dyn KeyFile>>,
    ring: Arc<RingInner>,
    state: StdMutex<State>,
    checking: Mutex<()>,
    /// Lookups ([KeyRing::of]) holding it now, and whether one returned it:
    /// a failed restore unregisters only a handle no other has. Both changed
    /// under the key table's lock.
    lookups: AtomicUsize,
    handed_out: AtomicBool,
    #[cfg(test)]
    before_take_merge: StdMutex<Option<TestTakeMergeHook>>,
}
