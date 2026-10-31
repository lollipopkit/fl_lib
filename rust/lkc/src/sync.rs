//! Homebase's sync (`/v2/sync/{app}/{name}`): one app's files of a person.
//!
//! Every write names the version it read (`If-Match`), or `If-None-Match: *`
//! for a new file, and homebase takes it only when that is still the file's
//! version: a write that lost the race is [`Kind::Changed`], and the caller
//! reads, merges and writes again. The bodies are age files, encrypted before
//! they get here; homebase keeps them as they come.
//!
//! Homebase refuses a request it takes no token for as a `200` carrying
//! `{"code": 2}`, not as a `401`: a file's own answers always carry an
//! `ETag`, and one without it is that refusal only when a body says so.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{Stream, StreamExt};
use reqwest::{Method, StatusCode, header};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::session::{Session, Store};
use crate::{Failure, now_ms, unreachable};

/// Up to this a file is sent in one request; above it, straight to the store.
pub const DIRECT_MAX: u64 = 1 << 20;
/// The largest file homebase keeps.
pub const MAX_BYTES: u64 = 32 << 20;
/// What a JSON answer may be.
const MAX_JSON: usize = 1 << 20;
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
    /// `sync_quota` or `sync_daily_limit`.
    Refused(String),
    /// Too many writes this minute, or uploads under way (`429`).
    Busy,
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

/// What [`SyncClient::events`] says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Listening (again): anything written while not was not heard.
    Connected,
    /// [name] is now at [etag], or removed (`None`), by another device.
    Changed { name: String, etag: Option<String> },
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

/// One app's sync, on a signed-in [`Session`].
pub struct SyncClient<S: Store> {
    session: Arc<Session<S>>,
    app: String,
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
        Self { session, app: app.to_string(), clock: Clock::default(), written: Mutex::new(HashMap::new()) }
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
        let path = self.file_path(name)?;
        let bytes = tokio::fs::read(from).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", from.display())))?;
        let size = bytes.len() as u64;
        if size > MAX_BYTES {
            return Err(Error::new(Kind::TooLarge, format!("{size} bytes")));
        }
        let etag = if size <= DIRECT_MAX {
            let response = self
                .send(Method::PUT, &path, |r| {
                    condition_on(r, &condition)
                        .header(header::CONTENT_TYPE, "application/octet-stream")
                        .header(header::CONTENT_LENGTH, size)
                        .body(bytes)
                })
                .await?;
            self.written_version(response).await?
        } else {
            let response = self
                .send(Method::POST, &format!("{path}/uploads"), |r| condition_on(r, &condition).json(&serde_json::json!({ "size": size })))
                .await?;
            let begun: Begun = self.json(response).await?;
            // The store's own address: no token goes there.
            let put = self
                .session
                .client()
                .transfer()
                .put(&begun.url)
                .header(header::CONTENT_LENGTH, size)
                .body(bytes)
                .send()
                .await
                .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
            if !put.status().is_success() {
                return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", put.status())));
            }
            self.complete(&path, &begun.id).await?
        };
        self.written.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), etag.clone());
        Ok(etag)
    }

    /// Records an upload, asked again while the store has not seen it.
    /// Completing twice is answered alike, so a completion whose answer was
    /// lost is simply asked again.
    async fn complete(&self, path: &str, id: &str) -> Result<String, Error> {
        let mut wait = Duration::from_millis(500);
        for _ in 0..COMPLETE_TRIES {
            let response = self.send(Method::POST, &format!("{path}/uploads/{id}/complete"), |r| r).await?;
            if response.status() == StatusCode::CONFLICT {
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
        let response = self.send(Method::GET, &format!("/v2/sync/{}", self.app_segment()?), |r| r).await?;
        self.json(response).await
    }

    /// [name]'s kept versions, the newest first.
    pub async fn versions(&self, name: &str) -> Result<Vec<Version>, Error> {
        let response = self.send(Method::GET, &format!("{}/versions", self.file_path(name)?), |r| r).await?;
        self.json(response).await
    }

    /// What other devices write, as long as it is read: connected again after
    /// a drop, waiting longer each time up to a minute. Ends when signed out.
    pub fn events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        struct Listen<S: Store> {
            sync: Arc<SyncClient<S>>,
            body: Option<Body>,
            buffer: Vec<u8>,
            wait: Duration,
            /// Waited before the next connection, once [Event::Lost] is out.
            retry: Option<Duration>,
        }
        let start = Listen { sync: self, body: None, buffer: Vec::new(), wait: Duration::from_secs(1), retry: None };
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
                    match st.sync.listen().await {
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

    async fn listen(&self) -> Result<Body, Error> {
        let response = self.send(Method::GET, "/sse/listen?chan=sync", |r| r.header(header::ACCEPT, "text/event-stream")).await?;
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

    /// An event of this app written by another device.
    fn heard(&self, value: &Value) -> Option<Event> {
        if value["event"] != "sync" || value["app"] != self.app.as_str() {
            return None;
        }
        let name = value["name"].as_str()?.to_string();
        let etag = value["etag"].as_str().map(str::to_string);
        let own = etag.is_some() && self.written.lock().unwrap_or_else(|e| e.into_inner()).get(&name) == etag.as_ref();
        (!own).then_some(Event::Changed { name, etag })
    }

    async fn fetch(&self, path: &str, to: &Path, known: Option<&str>) -> Result<Fetched, Error> {
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
        save(body, to).await?;
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
        let status = response.status();
        if !status.is_success() {
            return Err(refusal(response).await);
        }
        let url = response.url().path().to_string();
        let body = read_limited(response, MAX_JSON).await?;
        match crate::unwrap(&url, status.as_u16(), &body) {
            Ok(data) => serde_json::from_value(data).map_err(|e| Error::new(Kind::Invalid, format!("{url}: {e}"))),
            Err(e) if e.failure == Failure::Rejected => {
                self.session.forget().await;
                Err(Error::new(Kind::SignedOut, e.detail))
            }
            Err(e) if e.failure == Failure::Unreachable => Err(Error::new(Kind::Unreachable, e.detail)),
            Err(e) => Err(Error::new(Kind::Refused(String::new()), e.detail)),
        }
    }

    async fn send(
        &self,
        method: Method,
        path: &str,
        build: impl FnOnce(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        let token = self.session.access_token().await.map_err(|e| match e.failure {
            Failure::Rejected => Error::new(Kind::SignedOut, e.detail),
            _ => Error::new(Kind::Unreachable, e.detail),
        })?;
        let client = self.session.client();
        let url = client.api_url(path);
        let sent = now_ms();
        let response = build(client.transfer().request(method, &url).bearer_auth(token))
            .send()
            .await
            .map_err(|e| Error::new(Kind::Unreachable, unreachable(&url, e).detail))?;
        self.clock.record(sent, now_ms(), &response);
        Ok(response)
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

    fn file_path(&self, name: &str) -> Result<String, Error> {
        if !valid(name, 128, true) {
            return Err(Error::new(Kind::Invalid, "not a file name"));
        }
        Ok(format!("/v2/sync/{}/{name}", self.app_segment()?))
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
        StatusCode::FORBIDDEN => {
            let body = read_limited(response, MAX_JSON).await.unwrap_or_default();
            let reason = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)).unwrap_or_default();
            return Error::new(Kind::Refused(reason.clone()), format!("HTTP 403 {reason}"));
        }
        s if s.is_server_error() => Kind::Unreachable,
        _ => Kind::Invalid,
    };
    Error::new(kind, format!("HTTP {status}"))
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
