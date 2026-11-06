//! Homebase's sync (`/v2/sync/{app}/{name}`): one app's files of a person.
//!
//! Every write names the version it read (`If-Match`), or `If-None-Match: *`
//! for a new file, and homebase takes it only when that is still the file's
//! version: a write that lost the race is [`Kind::Changed`], and the caller
//! reads, merges and writes again. The bodies are age files, encrypted before
//! they get here; homebase keeps them as they come.
//!
//! Each app also has a log (`/v2/sync/{app}/log`): batches homebase numbers
//! in the order they commit, read from a cursor, and a snapshot covering it up
//! to a seq ([`SyncClient::append`], [`SyncClient::read_log`],
//! [`SyncClient::put_snapshot`], [`SyncClient::download_snapshot`]).
//!
//! Homebase refuses a request it takes no token for as a `200` carrying
//! `{"code": 2}`, not as a `401`: a file's own answers always carry an
//! `ETag`, and one without it is that refusal only when a body says so.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::{Stream, StreamExt};
use reqwest::{Method, StatusCode, header};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::session::{Session, Store};
use crate::team::{canonical, team_bytes};
use crate::{Failure, now_ms, unreachable};

/// Up to this a file is sent in one request; above it, straight to the store.
pub const DIRECT_MAX: u64 = 1 << 20;
/// The largest file homebase keeps.
pub const MAX_BYTES: u64 = 32 << 20;
/// What a JSON answer may be.
const MAX_JSON: usize = 1 << 20;
/// What a page of the log may be: homebase fills one while the batches
/// before the last come to under 1 MiB, so up to 1 MiB plus a batch, as
/// base64 (4/3) in JSON (up to 1000 batches' fields).
const MAX_LOG_PAGE: usize = 3 << 20;
/// The largest log batch homebase takes.
pub const BATCH_MAX: usize = 256 << 10;
/// The longest `Retry-After` a `503` is waited out for, once.
const RETRY_AFTER_MAX: Duration = Duration::from_secs(5);
/// How often a completion the store has not yet seen is asked again.
const COMPLETE_TRIES: u32 = 8;
/// The longest wait between two connections of [`SyncClient::events`].
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// Clock samples kept: the one sent and answered quickest is believed.
const SAMPLES: usize = 16;

/// Why a sync request did not go through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// Another version is there now (`412`): read, merge, write again.
    Changed,
    /// No such file, version or upload (`404`).
    Missing,
    /// Larger than homebase keeps (`413`).
    TooLarge,
    /// Not an age file (`415`).
    NotAge,
    /// Homebase's `reason`: `sync_unavailable` (the plan has no sync),
    /// `sync_quota` or `sync_daily_limit` (`403`); `sync_log_full` (a snapshot
    /// is due) or `sync_snapshot_stale` (`409`); `sync_key_reused` (`422`).
    Refused(String),
    /// Too many writes this minute, or uploads under way (`429`).
    Busy,
    /// A team's write under a replaced key (`409`): the current epoch.
    StaleEpoch(i64),
    /// A file's version not past the highest homebase knows of it (`409`):
    /// that highest.
    Version(i64),
    /// Not signed in, or homebase no longer takes the session.
    SignedOut,
    /// Nothing reached homebase, or no answer: worth trying later.
    Unreachable,
    /// An answer this cannot read.
    Invalid,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub kind: Kind,
    /// For logs; never a token.
    pub detail: String,
}

impl Error {
    fn new(kind: Kind, detail: impl Into<String>) -> Self {
        Self { kind, detail: detail.into() }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.detail)
    }
}

impl std::error::Error for Error {}

/// What a write expects the file to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Condition {
    /// At this version.
    Match(String),
    /// Not there.
    Absent,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct File {
    pub name: String,
    pub etag: String,
    pub size: u64,
    /// RFC 3339.
    pub updated_at: String,
    /// A team's: the key epoch it was written under.
    #[serde(default)]
    pub epoch: Option<i64>,
    /// Its writer's signature, when signed.
    #[serde(flatten)]
    pub signed: Option<Signed>,
}

/// A write's signature as homebase keeps it: [signer] (a user id) under
/// [signing_key], [signature] (both base64), a file's [version].
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Signed {
    pub signer: String,
    pub signing_key: String,
    pub signature: String,
    #[serde(default)]
    pub version: Option<i64>,
}

impl Signed {
    fn of(response: &reqwest::Response) -> Option<Self> {
        let header = |name: &str| response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
        Some(Self {
            signer: header("x-signer")?,
            signing_key: header("x-signing-key")?,
            signature: header("x-signature")?,
            version: header("x-sync-version").and_then(|v| v.parse().ok()),
        })
    }
}

/// What a signed write sends: the signature (base64) and a file's version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteSig {
    pub signature: String,
    pub version: Option<i64>,
}

fn signed_by(request: reqwest::RequestBuilder, sig: Option<&WriteSig>) -> reqwest::RequestBuilder {
    match sig {
        None => request,
        Some(s) => {
            let request = request.header("x-signature", &s.signature);
            match s.version {
                Some(v) => request.header("x-sync-version", v),
                None => request,
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Version {
    pub etag: String,
    pub size: u64,
    /// RFC 3339.
    pub written_at: String,
    /// RFC 3339.
    pub replaced_at: String,
}

/// What a download did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fetched {
    Missing,
    /// The version named is the file's.
    Unchanged,
    /// Written to the path asked, at this version.
    Saved(String),
}

/// A batch appended to the log.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Appended {
    /// The log's id: a log made anew numbers from 1 again.
    pub log: String,
    pub seq: i64,
    pub live: Live,
    /// A snapshot is due.
    pub compact: bool,
}

/// What no snapshot covers yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Live {
    pub batches: i64,
    pub bytes: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub seq: i64,
    /// The age file, its digest checked.
    pub body: Vec<u8>,
    /// A team's: the key epoch it was sealed under.
    pub epoch: Option<i64>,
    /// What it was appended once by: its signature covers it.
    pub idempotency_key: Option<String>,
    /// Its writer's signature, when signed.
    pub signed: Option<Signed>,
}

/// Where the log is after a read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogRead {
    Page {
        /// `None` before the log's first batch.
        log: Option<String>,
        batches: Vec<Batch>,
        head: i64,
        snapshot_seq: i64,
        /// More batches follow the last: read again after it.
        more: bool,
    },
    /// The batches after the cursor are gone, or the cursor is of another
    /// log: load the snapshot, then read on from its seq.
    Compacted { log: Option<String>, snapshot_seq: i64 },
}

/// A snapshot downloaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub log: String,
    /// The seq it covers the log up to.
    pub seq: i64,
    /// Its writer's signature, when signed.
    pub signed: Option<Signed>,
}

#[derive(Deserialize)]
struct WireBatch {
    seq: i64,
    digest: String,
    body: String,
    #[serde(default)]
    epoch: Option<i64>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(flatten)]
    signed: Option<Signed>,
}

#[derive(Deserialize)]
struct WirePage {
    log: Option<String>,
    batches: Vec<WireBatch>,
    head: i64,
    snapshot_seq: i64,
    more: bool,
}

/// What [`SyncClient::events`] says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Listening (again): anything written while not was not heard.
    Connected,
    /// [name] is now at [etag], or removed (`None`), by another device.
    Changed { name: String, etag: Option<String> },
    /// The log reached [seq] (this device's own appends too): read on from
    /// the cursor.
    Log { seq: i64 },
    /// A team's members or key changed (`key`, `members`, `rotation_needed`,
    /// …): its keys are read again ([`SyncClient::team_events`]).
    Team { change: String },
    /// Not listening: a connection failed or ended, and is tried again after
    /// a wait. For logs; never a token.
    Lost(String),
}

#[derive(Deserialize)]
struct Begun {
    id: String,
    url: String,
}

/// This side's clock against homebase's, from `X-Server-Time`.
#[derive(Default)]
struct Clock {
    /// `(round trip, offset)` in milliseconds.
    samples: Mutex<VecDeque<(i64, i64)>>,
}

impl Clock {
    fn record(&self, sent: i64, received: i64, response: &reqwest::Response) {
        let server = response.headers().get("x-server-time").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<i64>().ok());
        let Some(server) = server else { return };
        let trip = received - sent;
        if trip < 0 {
            return;
        }
        let mut samples = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        if samples.len() == SAMPLES {
            samples.pop_front();
        }
        samples.push_back((trip, server - (sent + received) / 2));
    }

    fn offset_ms(&self) -> i64 {
        let samples = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        samples.iter().min_by_key(|(trip, _)| *trip).map_or(0, |(_, offset)| *offset)
    }
}

/// A team's space (`/v2/teams/{team}/sync`): every request names the key
/// epoch its writes are sealed under (`X-Team-Epoch`).
struct TeamSpace {
    id: String,
    epoch: AtomicI64,
}

/// One app's sync, on a signed-in [`Session`]: the person's own files, or a
/// team's ([`SyncClient::for_team`]).
pub struct SyncClient<S: Store> {
    session: Arc<Session<S>>,
    app: String,
    team: Option<TeamSpace>,
    clock: Clock,
    /// The version each name was last written at by this device, so its own
    /// writes heard back on [`SyncClient::events`] are not taken for another's.
    written: Mutex<HashMap<String, String>>,
}

/// An event stream's body as it arrives.
type Body = Pin<Box<dyn Stream<Item = reqwest::Result<bytes::Bytes>> + Send>>;

impl<S: Store> SyncClient<S> {
    /// [app]: `serverbox`, `gptbox`, … (`[a-z0-9._-]`, not starting with `.`).
    pub fn new(session: Arc<Session<S>>, app: &str) -> Self {
        Self { session, app: app.to_string(), team: None, clock: Clock::default(), written: Mutex::new(HashMap::new()) }
    }

    /// [app]'s files of team [team] (its id), written under key [epoch].
    pub(crate) fn for_team(session: Arc<Session<S>>, team: &str, app: &str, epoch: i64) -> Self {
        // Canonical, so homebase's events name it alike however it was given.
        let team = Some(TeamSpace { id: canonical(team).unwrap_or_else(|_| team.to_string()), epoch: AtomicI64::new(epoch) });
        Self { session, app: app.to_string(), team, clock: Clock::default(), written: Mutex::new(HashMap::new()) }
    }

    /// The key epoch a team's writes now name; after a rotation, or a
    /// [`Kind::StaleEpoch`].
    pub(crate) fn set_epoch(&self, epoch: i64) {
        if let Some(t) = &self.team {
            t.epoch.store(epoch, Ordering::Release);
        }
    }

    /// The epoch writes name; `None` for the person's own files.
    pub(crate) fn epoch(&self) -> Option<i64> {
        self.team.as_ref().map(|t| t.epoch.load(Ordering::Acquire))
    }

    pub fn session(&self) -> &Arc<Session<S>> {
        &self.session
    }

    /// Homebase's clock minus this one's, in milliseconds; 0 before any answer.
    pub fn offset_ms(&self) -> i64 {
        self.clock.offset_ms()
    }

    /// [name]'s version, `None` when there is no such file.
    pub async fn head(&self, name: &str) -> Result<Option<String>, Error> {
        let response = self.send(Method::HEAD, &self.file_path(name)?, |r| r).await?;
        match response.status() {
            StatusCode::OK => match self.etag(&response) {
                Some(etag) => Ok(Some(etag)),
                None => Err(self.without_version().await),
            },
            StatusCode::NOT_FOUND => Ok(None),
            _ => Err(refusal(response).await),
        }
    }

    /// [name] written to [to], unless its version is [known].
    pub async fn download(&self, name: &str, to: &Path, known: Option<&str>) -> Result<Fetched, Error> {
        self.fetch(&self.file_path(name)?, to, known).await
    }

    /// [name]'s bytes and version; `None` when there is no such file.
    /// [name]'s bytes, version and its writer's signature (when signed);
    /// `None` when there is no such file.
    pub async fn download_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        let mut body = Vec::new();
        let mut signed = None;
        match self.fetch_with(&self.file_path(name)?, Target::Memory(&mut body), None, |r| signed = Signed::of(r)).await? {
            Fetched::Saved(etag) => Ok(Some((body, etag, signed))),
            Fetched::Missing => Ok(None),
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a file answered 304")),
        }
    }

    /// A kept version of [name] ([`SyncClient::versions`]) written to [to].
    pub async fn download_version(&self, name: &str, etag: &str, to: &Path) -> Result<Fetched, Error> {
        if !etag.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::new(Kind::Invalid, "not a version"));
        }
        self.fetch(&format!("{}/versions/{etag}", self.file_path(name)?), to, None).await
    }

    /// [from] as [name]'s new version, if [condition] still holds. Answers the
    /// new version.
    pub async fn upload(&self, name: &str, from: &Path, condition: Condition) -> Result<String, Error> {
        self.upload_bytes(name, read_file(from).await?, condition).await
    }

    /// [body] as [name]'s new version, if [condition] still holds.
    pub async fn upload_bytes(&self, name: &str, body: Vec<u8>, condition: Condition) -> Result<String, Error> {
        self.upload_signed(name, body, condition, None).await
    }

    /// [upload_bytes], signed by its writer ([sig]): a team's every write is.
    pub async fn upload_signed(&self, name: &str, body: Vec<u8>, condition: Condition, sig: Option<&WriteSig>) -> Result<String, Error> {
        let path = self.file_path(name)?;
        let bytes = bytes::Bytes::from(body);
        let size = bytes.len() as u64;
        if size > MAX_BYTES {
            return Err(Error::new(Kind::TooLarge, format!("{size} bytes")));
        }
        let etag = if size <= DIRECT_MAX {
            let response = self
                .send(Method::PUT, &path, |r| {
                    signed_by(condition_on(r, &condition), sig)
                        .header(header::CONTENT_TYPE, "application/octet-stream")
                        .header(header::CONTENT_LENGTH, size)
                        .body(bytes.clone())
                })
                .await?;
            self.written_version(response).await?
        } else {
            let response = self
                .send(Method::POST, &format!("{path}/uploads"), |r| signed_by(condition_on(r, &condition), sig).json(&serde_json::json!({ "size": size })))
                .await?;
            let begun: Begun = self.json(response).await?;
            self.store_upload(&begun.url, bytes).await?;
            self.complete(&path, &begun.id).await?
        };
        self.written.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), etag.clone());
        Ok(etag)
    }

    /// [bytes] to an upload's presigned [url]: the store's own address, so no
    /// token goes there.
    async fn store_upload(&self, url: &str, bytes: bytes::Bytes) -> Result<(), Error> {
        let put = self
            .session
            .client()
            .transfer()
            .put(url)
            .header(header::CONTENT_LENGTH, bytes.len())
            .body(bytes)
            .send()
            .await
            .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
        if !put.status().is_success() {
            return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", put.status())));
        }
        Ok(())
    }

    /// Records an upload, asked again while the store has not seen it.
    /// Completing twice is answered alike, so a completion whose answer was
    /// lost is simply asked again.
    async fn complete(&self, path: &str, id: &str) -> Result<String, Error> {
        let mut wait = Duration::from_millis(500);
        for _ in 0..COMPLETE_TRIES {
            let response = self.send(Method::POST, &format!("{path}/uploads/{id}/complete"), |r| r).await?;
            // A bare `409` is the store not showing the upload yet; one with a
            // reason (a snapshot gone stale) is a refusal.
            if response.status() == StatusCode::CONFLICT {
                if let Some(current) = stale_epoch(&response, self.epoch()) {
                    return Err(Error::new(Kind::StaleEpoch(current), "HTTP 409 team_epoch_stale"));
                }
                let body = read_limited(response, MAX_JSON).await?;
                if let Some(reason) = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)) {
                    return Err(Error::new(Kind::Refused(reason.clone()), format!("HTTP 409 {reason}")));
                }
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(Duration::from_secs(8));
                continue;
            }
            return self.written_version(response).await;
        }
        Err(Error::new(Kind::Unreachable, "the store never showed the upload"))
    }

    /// Removes [name], if [if_match] (when given) is its version. `false`
    /// when there was no such file.
    pub async fn delete(&self, name: &str, if_match: Option<&str>) -> Result<bool, Error> {
        let response = self
            .send(Method::DELETE, &self.file_path(name)?, |r| match if_match {
                Some(etag) => r.header(header::IF_MATCH, quote(etag)),
                None => r,
            })
            .await?;
        match response.status() {
            StatusCode::NO_CONTENT => {
                self.written.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                Ok(true)
            }
            StatusCode::NOT_FOUND => Ok(false),
            StatusCode::OK => Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a delete answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    pub async fn list(&self) -> Result<Vec<File>, Error> {
        let response = self.send(Method::GET, &self.app_path()?, |r| r).await?;
        self.json(response).await
    }

    /// [name]'s kept versions, the newest first.
    pub async fn versions(&self, name: &str) -> Result<Vec<Version>, Error> {
        let response = self.send(Method::GET, &format!("{}/versions", self.file_path(name)?), |r| r).await?;
        self.json(response).await
    }

    /// Appends [body] (an age file, up to [`BATCH_MAX`]) to the log, once per
    /// [key] (16 to 64 of `[A-Za-z0-9_-]`): a retry is answered the seq given.
    pub async fn append(&self, key: &str, body: Vec<u8>) -> Result<Appended, Error> {
        self.append_signed(key, body, None).await
    }

    /// [append], signed by its writer ([sig], no version).
    pub async fn append_signed(&self, key: &str, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<Appended, Error> {
        if !(16..=64).contains(&key.len()) || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err(Error::new(Kind::Invalid, "not an idempotency key"));
        }
        if body.len() > BATCH_MAX {
            return Err(Error::new(Kind::TooLarge, format!("{} bytes", body.len())));
        }
        let body = bytes::Bytes::from(body);
        let path = format!("{}/log", self.app_path()?);
        let response = self
            .send(Method::POST, &path, |r| {
                signed_by(r, sig)
                    .header("idempotency-key", key)
                    .header(header::CONTENT_TYPE, "application/octet-stream")
                    .header(header::CONTENT_LENGTH, body.len())
                    .body(body.clone())
            })
            .await?;
        self.json(response).await
    }

    /// The log's batches after [after] of [log] (needed past 0), up to
    /// [limit] (homebase's default when `None`).
    pub async fn read_log(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<LogRead, Error> {
        let mut query = format!("after={after}");
        if let Some(log) = log {
            if !log.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
                return Err(Error::new(Kind::Invalid, "not a log id"));
            }
            query.push_str(&format!("&log={log}"));
        }
        if let Some(limit) = limit {
            query.push_str(&format!("&limit={limit}"));
        }
        let response = self.send(Method::GET, &format!("{}/log?{query}", self.app_path()?), |r| r).await?;
        if response.status() == StatusCode::GONE {
            let header = |name: &str| response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
            let snapshot_seq = header("sync-snapshot-seq").and_then(|v| v.parse().ok()).ok_or_else(|| Error::new(Kind::Invalid, "a 410 without Sync-Snapshot-Seq"))?;
            return Ok(LogRead::Compacted { log: header("sync-log"), snapshot_seq });
        }
        let page: WirePage = self.json_within(response, MAX_LOG_PAGE).await?;
        let mut batches = Vec::with_capacity(page.batches.len());
        for b in page.batches {
            let body = BASE64.decode(&b.body).map_err(|e| Error::new(Kind::Invalid, format!("batch {}: {e}", b.seq)))?;
            if blake3::hash(&body).to_hex().as_str() != b.digest {
                return Err(Error::new(Kind::Invalid, format!("batch {}: digest mismatch", b.seq)));
            }
            batches.push(Batch { seq: b.seq, body, epoch: b.epoch, idempotency_key: b.idempotency_key, signed: b.signed });
        }
        Ok(LogRead::Page { log: page.log, batches, head: page.head, snapshot_seq: page.snapshot_seq, more: page.more })
    }

    /// [from] as the log's snapshot up to [seq]: further than the last, up to
    /// the head. Answers its version.
    pub async fn put_snapshot(&self, seq: i64, from: &Path) -> Result<String, Error> {
        self.put_snapshot_bytes(seq, read_file(from).await?).await
    }

    /// [body] as the log's snapshot up to [seq].
    pub async fn put_snapshot_bytes(&self, seq: i64, body: Vec<u8>) -> Result<String, Error> {
        self.put_snapshot_signed(seq, body, None).await
    }

    /// [put_snapshot_bytes], signed by its writer ([sig], no version).
    pub async fn put_snapshot_signed(&self, seq: i64, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<String, Error> {
        let path = format!("{}/snapshot", self.app_path()?);
        let bytes = bytes::Bytes::from(body);
        let size = bytes.len() as u64;
        if size > MAX_BYTES {
            return Err(Error::new(Kind::TooLarge, format!("{size} bytes")));
        }
        if size <= DIRECT_MAX {
            let response = self
                .send(Method::PUT, &format!("{path}?seq={seq}"), |r| {
                    signed_by(r, sig).header(header::CONTENT_TYPE, "application/octet-stream").header(header::CONTENT_LENGTH, size).body(bytes.clone())
                })
                .await?;
            return self.written_version(response).await;
        }
        let response = self.send(Method::POST, &format!("{path}/uploads?seq={seq}"), |r| signed_by(r, sig).json(&serde_json::json!({ "size": size }))).await?;
        let begun: Begun = self.json(response).await?;
        self.store_upload(&begun.url, bytes).await?;
        self.complete(&path, &begun.id).await
    }

    /// The log's snapshot written to [to]; `None` before there is one.
    pub async fn download_snapshot(&self, to: &Path) -> Result<Option<Snapshot>, Error> {
        self.snapshot_into(Target::File(to)).await
    }

    /// The log's snapshot and its bytes; `None` before there is one.
    pub async fn download_snapshot_bytes(&self) -> Result<Option<(Snapshot, Vec<u8>)>, Error> {
        let mut body = Vec::new();
        Ok(self.snapshot_into(Target::Memory(&mut body)).await?.map(|s| (s, body)))
    }

    async fn snapshot_into(&self, into: Target<'_>) -> Result<Option<Snapshot>, Error> {
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), into, None, |response| {
                let header = |name: &str| response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
                found = header("sync-log").zip(header("sync-seq").and_then(|v| v.parse().ok())).map(|(log, seq)| Snapshot { log, seq, signed: Signed::of(response) });
            })
            .await?;
        match fetched {
            Fetched::Missing => Ok(None),
            Fetched::Saved(_) => found.map(Some).ok_or_else(|| Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq")),
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }

    /// What other devices write, as long as it is read: connected again after
    /// a drop, waiting longer each time up to a minute. Ends when signed out.
    pub fn events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("sync")
    }

    /// A team's changes of members and key ([Event::Team]), as [events].
    pub fn team_events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("team")
    }

    fn events_on(self: Arc<Self>, chan: &'static str) -> impl Stream<Item = Event> + Send + 'static {
        struct Listen<S: Store> {
            chan: &'static str,
            sync: Arc<SyncClient<S>>,
            body: Option<Body>,
            buffer: Vec<u8>,
            wait: Duration,
            /// Waited before the next connection, once [Event::Lost] is out.
            retry: Option<Duration>,
        }
        let start = Listen { chan, sync: self, body: None, buffer: Vec::new(), wait: Duration::from_secs(1), retry: None };
        futures_util::stream::unfold(start, |mut st| async move {
            if let Some(wait) = st.retry.take() {
                tokio::time::sleep(wait).await;
            }
            loop {
                if let Some(event) = take_event(&mut st.buffer) {
                    if let Some(event) = st.sync.heard(&event) {
                        return Some((event, st));
                    }
                    continue;
                }
                let Some(body) = st.body.as_mut() else {
                    match st.sync.listen(st.chan).await {
                        Ok(body) => {
                            st.body = Some(body);
                            st.buffer.clear();
                            st.wait = Duration::from_secs(1);
                            return Some((Event::Connected, st));
                        }
                        Err(e) if e.kind == Kind::SignedOut => return None,
                        Err(e) => {
                            let wait = st.wait;
                            st.wait = (st.wait * 2).min(MAX_BACKOFF);
                            st.retry = Some(wait);
                            return Some((Event::Lost(e.to_string()), st));
                        }
                    }
                };
                let lost = match body.next().await {
                    Some(Ok(chunk)) => {
                        st.buffer.extend_from_slice(&chunk);
                        continue;
                    }
                    Some(Err(e)) => format!("the event stream failed: {e}"),
                    None => "the event stream ended".to_string(),
                };
                st.body = None;
                let wait = st.wait;
                st.wait = (st.wait * 2).min(MAX_BACKOFF);
                st.retry = Some(wait);
                return Some((Event::Lost(lost), st));
            }
        })
    }

    async fn listen(&self, chan: &str) -> Result<Body, Error> {
        let response = self.send(Method::GET, &format!("/sse/listen?chan={chan}"), |r| r.header(header::ACCEPT, "text/event-stream")).await?;
        let stream = response.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|v| v.starts_with("text/event-stream"));
        if response.status() != StatusCode::OK {
            return Err(refusal(response).await);
        }
        if !stream {
            // `{"code": 2}`, or another refusal as JSON.
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "not an event stream")));
        }
        Ok(Box::pin(response.bytes_stream()))
    }

    /// An event of this app (of this team, or of none) written by another
    /// device.
    fn heard(&self, value: &Value) -> Option<Event> {
        let team = value["team"].as_str().map(|t| canonical(t).unwrap_or_default());
        if team.as_deref() != self.team.as_ref().map(|t| t.id.as_str()) {
            return None;
        }
        if value["event"] == "team" {
            return value["change"].as_str().map(|c| Event::Team { change: c.to_string() });
        }
        if value["app"] != self.app.as_str() {
            return None;
        }
        if value["event"] == "log" {
            return value["seq"].as_i64().map(|seq| Event::Log { seq });
        }
        if value["event"] != "sync" {
            return None;
        }
        let name = value["name"].as_str()?.to_string();
        let etag = value["etag"].as_str().map(str::to_string);
        let own = etag.is_some() && self.written.lock().unwrap_or_else(|e| e.into_inner()).get(&name) == etag.as_ref();
        (!own).then_some(Event::Changed { name, etag })
    }

    async fn fetch(&self, path: &str, to: &Path, known: Option<&str>) -> Result<Fetched, Error> {
        self.fetch_with(path, Target::File(to), known, |_| {}).await
    }

    /// [fetch], [answered] shown homebase's answer before its body is read.
    async fn fetch_with(&self, path: &str, into: Target<'_>, known: Option<&str>, answered: impl FnOnce(&reqwest::Response)) -> Result<Fetched, Error> {
        let response = self
            .send(Method::GET, path, |r| match known {
                Some(etag) => r.header(header::IF_NONE_MATCH, quote(etag)),
                None => r,
            })
            .await?;
        let status = response.status();
        if status == StatusCode::NOT_MODIFIED {
            return Ok(Fetched::Unchanged);
        }
        if status == StatusCode::NOT_FOUND {
            return Ok(Fetched::Missing);
        }
        if status != StatusCode::OK && status != StatusCode::FOUND {
            return Err(refusal(response).await);
        }
        let Some(etag) = self.etag(&response) else {
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a file without its version")));
        };
        answered(&response);
        let body = if status == StatusCode::FOUND {
            let location = response
                .headers()
                .get(header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| Error::new(Kind::Invalid, "a redirect without Location"))?
                .to_string();
            // The store's own address: no token goes there.
            let stored = self
                .session
                .client()
                .transfer()
                .get(&location)
                .send()
                .await
                .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
            if !stored.status().is_success() {
                return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", stored.status())));
            }
            stored
        } else {
            response
        };
        match into {
            Target::File(to) => save(body, to).await?,
            Target::Memory(buffer) => *buffer = read_limited(body, MAX_BYTES as usize).await?,
        }
        Ok(Fetched::Saved(etag))
    }

    /// The version a write's `204` names.
    async fn written_version(&self, response: reqwest::Response) -> Result<String, Error> {
        match response.status() {
            StatusCode::NO_CONTENT => self.etag(&response).ok_or_else(|| Error::new(Kind::Invalid, "a write without its version")),
            StatusCode::OK => Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a write answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    async fn json<T: DeserializeOwned>(&self, response: reqwest::Response) -> Result<T, Error> {
        self.json_within(response, MAX_JSON).await
    }

    async fn json_within<T: DeserializeOwned>(&self, response: reqwest::Response, max: usize) -> Result<T, Error> {
        let status = response.status();
        if !status.is_success() {
            return Err(refusal(response).await);
        }
        let url = response.url().path().to_string();
        let body = read_limited(response, max).await?;
        match crate::unwrap(&url, status.as_u16(), &body) {
            Ok(data) => serde_json::from_value(data).map_err(|e| Error::new(Kind::Invalid, format!("{url}: {e}"))),
            Err(e) if e.failure == Failure::Rejected => {
                self.session.forget(format!("homebase refused the session at {url}: {}", e.detail)).await;
                Err(Error::new(Kind::SignedOut, e.detail))
            }
            Err(e) if e.failure == Failure::Unreachable => Err(Error::new(Kind::Unreachable, e.detail)),
            Err(e) => Err(Error::new(Kind::Refused(String::new()), e.detail)),
        }
    }

    /// Sends a request; a `503` homebase asks to be retried shortly
    /// (`Retry-After` up to [`RETRY_AFTER_MAX`]) is sent once more, when the
    /// request may be: any but a `POST` without an `Idempotency-Key`.
    async fn send(
        &self,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        let client = self.session.client();
        let url = client.api_url(path);
        let mut again = true;
        loop {
            let token = self.session.access_token().await.map_err(|e| match e.failure {
                Failure::Rejected => Error::new(Kind::SignedOut, e.detail),
                _ => Error::new(Kind::Unreachable, e.detail),
            })?;
            let mut request = build(client.transfer().request(method.clone(), &url).bearer_auth(token));
            if let Some(epoch) = self.epoch() {
                request = request.header("x-team-epoch", epoch);
            }
            let retryable = method != Method::POST || request.try_clone().and_then(|r| r.build().ok()).is_some_and(|r| r.headers().contains_key("idempotency-key"));
            let sent = now_ms();
            let response = request.send().await.map_err(|e| Error::new(Kind::Unreachable, unreachable(&url, e).detail))?;
            self.clock.record(sent, now_ms(), &response);
            let wait = (response.status() == StatusCode::SERVICE_UNAVAILABLE)
                .then(|| response.headers().get(header::RETRY_AFTER)?.to_str().ok()?.parse::<u64>().ok())
                .flatten()
                .map(Duration::from_secs)
                .filter(|w| *w <= RETRY_AFTER_MAX);
            match wait {
                Some(wait) if again && retryable => {
                    again = false;
                    tokio::time::sleep(wait).await;
                }
                _ => return Ok(response),
            }
        }
    }

    fn etag(&self, response: &reqwest::Response) -> Option<String> {
        let tag = response.headers().get(header::ETAG)?.to_str().ok()?;
        Some(tag.trim_matches('"').to_string()).filter(|t| !t.is_empty())
    }

    /// A bodiless `200` without the `ETag` every file answer carries: homebase
    /// refusing the session, or something in front of it (a captive portal, a
    /// proxy). Only homebase's own word, read from a body, signs out.
    async fn without_version(&self) -> Error {
        match self.list().await {
            Err(e) => e,
            Ok(_) => Error::new(Kind::Unreachable, "an answer without its version"),
        }
    }

    fn app_segment(&self) -> Result<&str, Error> {
        valid(&self.app, 64, false).then_some(self.app.as_str()).ok_or_else(|| Error::new(Kind::Invalid, "not an app name"))
    }

    fn app_path(&self) -> Result<String, Error> {
        let app = self.app_segment()?;
        match &self.team {
            None => Ok(format!("/v2/sync/{app}")),
            Some(t) if team_bytes(&t.id).is_ok() => Ok(format!("/v2/teams/{}/sync/{app}", t.id)),
            Some(_) => Err(Error::new(Kind::Invalid, "not a team id")),
        }
    }

    fn file_path(&self, name: &str) -> Result<String, Error> {
        if !valid(name, 128, true) {
            return Err(Error::new(Kind::Invalid, "not a file name"));
        }
        Ok(format!("{}/{name}", self.app_path()?))
    }
}

/// Homebase's names: `[a-z0-9._-]` for an app, uppercase too for a file, not
/// starting with a dot.
fn valid(s: &str, max: usize, upper: bool) -> bool {
    !s.is_empty()
        && s.len() <= max
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-') || (upper && b.is_ascii_uppercase()))
}

fn quote(etag: &str) -> String {
    format!("\"{etag}\"")
}

fn condition_on(request: reqwest::RequestBuilder, condition: &Condition) -> reqwest::RequestBuilder {
    match condition {
        Condition::Match(etag) => request.header(header::IF_MATCH, quote(etag)),
        Condition::Absent => request.header(header::IF_NONE_MATCH, "*"),
    }
}

/// A refusal by its status; a `403` by homebase's `reason`.
async fn refusal(response: reqwest::Response) -> Error {
    let status = response.status();
    let kind = match status {
        StatusCode::PRECONDITION_FAILED => Kind::Changed,
        StatusCode::NOT_FOUND => Kind::Missing,
        StatusCode::PAYLOAD_TOO_LARGE => Kind::TooLarge,
        StatusCode::UNSUPPORTED_MEDIA_TYPE => Kind::NotAge,
        StatusCode::TOO_MANY_REQUESTS => Kind::Busy,
        StatusCode::UNAUTHORIZED => Kind::SignedOut,
        StatusCode::FORBIDDEN | StatusCode::CONFLICT | StatusCode::UNPROCESSABLE_ENTITY => {
            let current = response.headers().get("x-team-epoch").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok());
            let highest = response.headers().get("x-sync-version").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok());
            let body = read_limited(response, MAX_JSON).await.unwrap_or_default();
            let reason = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)).unwrap_or_default();
            if let (STALE_EPOCH, Some(current)) = (reason.as_str(), current) {
                return Error::new(Kind::StaleEpoch(current), format!("HTTP {status} {STALE_EPOCH}"));
            }
            if let ("sync_version", Some(highest)) = (reason.as_str(), highest) {
                return Error::new(Kind::Version(highest), format!("HTTP {status} sync_version"));
            }
            return Error::new(Kind::Refused(reason.clone()), format!("HTTP {status} {reason}"));
        }
        s if s.is_server_error() => Kind::Unreachable,
        _ => Kind::Invalid,
    };
    Error::new(kind, format!("HTTP {status}"))
}

/// Homebase's reason for a team's write under a replaced key.
const STALE_EPOCH: &str = "team_epoch_stale";

/// The current epoch a team's `409` names (`X-Team-Epoch`), when it names
/// one other than the request's: a write under a replaced key.
fn stale_epoch(response: &reqwest::Response, sent: Option<i64>) -> Option<i64> {
    let current = response.headers().get("x-team-epoch")?.to_str().ok()?.parse().ok()?;
    (Some(current) != sent).then_some(current)
}

/// Where a download goes.
enum Target<'a> {
    File(&'a Path),
    Memory(&'a mut Vec<u8>),
}

async fn read_file(from: &Path) -> Result<Vec<u8>, Error> {
    tokio::fs::read(from).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", from.display())))
}

async fn read_limited(mut response: reqwest::Response, max: usize) -> Result<Vec<u8>, Error> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))? {
        body.extend_from_slice(&chunk);
        if body.len() > max {
            return Err(Error::new(Kind::Invalid, "answer too large"));
        }
    }
    Ok(body)
}

/// [response]'s body into [to], through a file beside it renamed into place:
/// a download cut short leaves the old file.
async fn save(response: reqwest::Response, to: &Path) -> Result<(), Error> {
    let io = |e: std::io::Error| Error::new(Kind::Invalid, format!("{}: {e}", to.display()));
    let part = to.with_extension(format!("{}.part", to.extension().and_then(|e| e.to_str()).unwrap_or_default()));
    let mut file = tokio::fs::File::create(&part).await.map_err(io)?;
    let mut stream = response.bytes_stream();
    let mut written = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))?;
        written += chunk.len() as u64;
        if written > MAX_BYTES {
            let _ = tokio::fs::remove_file(&part).await;
            return Err(Error::new(Kind::TooLarge, "the file outgrew homebase's limit"));
        }
        file.write_all(&chunk).await.map_err(io)?;
    }
    file.flush().await.map_err(io)?;
    drop(file);
    tokio::fs::rename(&part, to).await.map_err(io)
}

/// The next complete event in [buffer] (its `data:` lines as JSON), taken
/// out; comments (`: ping`) and other fields are skipped.
fn take_event(buffer: &mut Vec<u8>) -> Option<Value> {
    loop {
        let end = buffer.windows(2).position(|w| w == b"\n\n")?;
        let block: Vec<u8> = buffer.drain(..end + 2).collect();
        let text = String::from_utf8_lossy(&block);
        let data: String = text.lines().filter_map(|l| l.strip_prefix("data:")).map(str::trim_start).collect::<Vec<_>>().join("\n");
        if data.is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str(&data) {
            return Some(value);
        }
    }
}

#[cfg(test)]
mod tests;
