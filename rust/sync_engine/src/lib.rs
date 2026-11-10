//! The operation-log sync every app on fl_lib runs.
//!
//! Everything synced is a record `(c, id)` the host keeps and stamps
//! ([`fl_sync::Hlc`]). The engine sends this device's changes as batches of
//! [`Op`]s, sealed to the account's sync key ([`key::SyncKey`]), and hands the
//! host the ops other devices sent, which it writes where they win. Two
//! places keep the ops:
//!
//! - [`log::LogSync`]: a log the server orders, LK Cloud's
//!   (`/v2/sync/{app}/log`), compacted into snapshots.
//! - [`segment::SegmentSync`]: a folder nothing orders writes in (WebDAV,
//!   iCloud), where each device writes only its own files.
//!
//! What either writes is read by both ServerBox's Dart engine before this
//! one and this: the batch format, the blob names and the key file are
//! unchanged.

use std::collections::HashSet;
use std::future::Future;

pub use fl_sync::{Hlc, Op};
use serde_json::Value;

mod engine;
pub mod key;
pub mod lkc;
pub mod log;
pub mod segment;

#[cfg(test)]
mod tests;

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The host could not do what was asked; its words.
    Host(String),
    /// The store did not take or answer a request: worth trying later.
    Remote(String),
    /// LK Cloud refused the request: `sync_quota`, `sync_daily_limit`,
    /// `sync_unavailable`, … The send stops until it is taken.
    Refused(String),
    /// The log takes no more batches until a snapshot covers them
    /// (`409 sync_log_full`).
    LogFull,
    /// A batch of a newer build, in a format this one does not read: the
    /// log is not read past it until this build is updated.
    TooNew(Value),
    /// Not sealed to a key here, or not a sealed file at all.
    Unreadable(String),
    /// The backup password here does not open the key file of [0].
    PasswordMismatch(String),
    /// No key file is there yet beside what was synced with one: it may
    /// only not have arrived.
    KeyNotHere(String),
    /// No backup password here: nothing is sealed or opened without one.
    PasswordMissing,
    /// Signed out, or in as someone the run was not for.
    SignedOut,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Host(e) => write!(f, "host: {e}"),
            Error::Remote(e) => write!(f, "remote: {e}"),
            Error::Refused(r) => write!(f, "refused: {r}"),
            Error::LogFull => f.write_str("the log is full"),
            Error::TooNew(v) => write!(f, "batch version {v}"),
            Error::Unreadable(e) => write!(f, "unreadable: {e}"),
            Error::PasswordMismatch(id) => write!(f, "the backup password does not open the sync key of {id}"),
            Error::KeyNotHere(id) => write!(f, "the sync key of {id} is not here yet"),
            Error::PasswordMissing => f.write_str("no backup password"),
            Error::SignedOut => f.write_str("signed out"),
        }
    }
}

impl std::error::Error for Error {}

/// A record and its newest stamp, as the host recorded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stamped {
    pub c: String,
    pub id: String,
    pub h: Hlc,
}

/// A record as it is now.
#[derive(Debug, Clone, PartialEq)]
pub enum Read {
    Value(Value),
    /// Not here: deleted.
    Gone,
    /// Cannot be told now (a file that should be there is not): the send
    /// stops just before it, so it and what follows are read again next time.
    Unread,
    /// Nothing to say now: not sent, and nothing after it held back. It is
    /// stamped again once there is.
    Silent,
}

/// What an app gives the engine: its records, and a place for the engine's
/// own state. Every call may cross into another language, so they are few
/// and batched.
pub trait Host: Send + Sync + 'static {
    /// This install's device id: random, made once, never 0 (the stamp of a
    /// change no device made).
    fn device(&self) -> impl Future<Output = Result<u64>> + Send;

    /// Records changed outside any write that stamps them (files) are
    /// stamped now, before the pending records are read.
    fn stamp(&self) -> impl Future<Output = Result<()>> + Send;

    /// Every record and its stamp, the oldest first: what a snapshot holds,
    /// and what a device joining a log sends.
    fn all(&self) -> impl Future<Output = Result<Vec<Stamped>>> + Send;

    /// The records this device stamped after [after] (`None`: all of them),
    /// the oldest first: what the next send carries.
    fn pending(&self, after: Option<Hlc>) -> impl Future<Output = Result<Vec<Stamped>>> + Send;

    /// [ids] as they are now, in order.
    fn read(&self, ids: Vec<(String, String)>) -> impl Future<Output = Result<Vec<Read>>> + Send;

    /// Writes, in one transaction, those of [ops] whose stamp is greater than
    /// the record's here (`fl_sync::winners`), each stamped with its op's,
    /// and tells the app what changed. Deciding and writing are one step, so
    /// an edit made meanwhile is not overwritten by an older op. Answers the
    /// ops of collections this build does not keep (a newer one's), which the
    /// engine keeps for its snapshots, so the log loses none of them.
    fn apply(&self, ops: Vec<Op>) -> impl Future<Output = Result<Vec<Op>>> + Send;

    /// The collections not sent or taken now (a category switched off here).
    /// Asked once per run: one switched during a run is taken by the next.
    fn not_carried(&self) -> impl Future<Output = Result<HashSet<String>>> + Send;

    /// A read of the other devices' ops went past where it stopped before:
    /// what could not be written then is tried again.
    fn after_read(&self, not_carried: HashSet<String>) -> impl Future<Output = Result<()>> + Send;

    /// The engine's state (`sync_state`): [keys]' values, in order.
    fn state(&self, keys: Vec<String>) -> impl Future<Output = Result<Vec<Option<String>>>> + Send;

    /// The state keys starting with [prefix], and their values.
    fn state_prefixed(&self, prefix: String) -> impl Future<Output = Result<Vec<(String, String)>>> + Send;

    /// Sets each key to its value, or removes it (`None`), in one transaction.
    fn set_state(&self, values: Vec<(String, Option<String>)>) -> impl Future<Output = Result<()>> + Send;

    /// Removes every state key starting with [prefix] but [keep].
    fn clear_state(&self, prefix: String, keep: Vec<String>) -> impl Future<Output = Result<()>> + Send;

    /// Keeps [ops], of collections not carried here, for [engine]'s
    /// snapshots (`sync_passed`): each replaces one of its record kept before
    /// only when its stamp is greater.
    fn pass(&self, engine: String, ops: Vec<Op>) -> impl Future<Output = Result<()>> + Send;

    /// What [pass] kept for [engine].
    fn passed(&self, engine: String) -> impl Future<Output = Result<Vec<Op>>> + Send;

    fn forget_passed(&self, engine: String) -> impl Future<Output = Result<()>> + Send;

    /// Something the engine went past (an unreadable batch, a record left
    /// out) and the app should log.
    fn warn(&self, message: String);
}

/// What batches, snapshots and blobs are sealed with: the account's sync key.
pub trait Seal: Send + Sync + 'static {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>>;

    /// [Error::Unreadable] when no key here opens it.
    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>>;

    /// A name for [data] only holders of the key can derive
    /// (`fl_sync::blob_name`).
    fn name_of(&self, data: &[u8]) -> String;

    /// Looks again for the account's key, after something did not [open]:
    /// whether a newer one was found (the key was replaced elsewhere).
    fn refresh(&self) -> impl Future<Output = Result<bool>> + Send;
}

/// Where large records are kept beside the ops (`op-<name>.age`).
pub trait BlobStore: Send + Sync + 'static {
    /// [body] kept as [name]; already there is done.
    fn put_blob(&self, name: String, body: Vec<u8>) -> impl Future<Output = Result<()>> + Send;

    /// The blob [name], `None` when it is gone.
    fn get_blob(&self, name: String) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send;

    /// The blobs whose name starts with [prefix], and when each was written
    /// (Unix ms).
    fn blobs(&self, prefix: String) -> impl Future<Output = Result<Vec<Listed>>> + Send;

    fn delete_blob(&self, name: String) -> impl Future<Output = Result<()>> + Send;
}

/// A file in a store's listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listed {
    pub name: String,
    /// When it was written, Unix ms; `None` when the store does not say.
    pub at: Option<i64>,
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}
