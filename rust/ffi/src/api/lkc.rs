//! LK Cloud for Dart (`fl_lkc`): the signed-in session, the one place its
//! tokens are refreshed, and homebase's sync. Dart keeps the browser sign-in
//! (AppAuth, or a loopback redirect) and hands its tokens to the session; the
//! session keeps them through [save], which Dart writes to the keychain.

use std::sync::Arc;

use flutter_rust_bridge::{DartFnFuture, frb};
use fl_lkc::sync::{Condition, Fetched, Kind, SyncClient};
use fl_lkc::{Client, Session, Stored, Tokens};
use tokio::sync::watch;

use crate::frb_generated::StreamSink;
use crate::lkc_bridge::DartStore;

/// Why a session request failed (`fl_lkc::Failure`).
pub enum LkcFailure {
    Unreachable,
    Unknown,
    InvalidResponse,
    Denied,
    Expired,
    TooEarly,
    /// Signed out, or signed out now: the IdP or homebase took the session back.
    Rejected,
    Refused,
}

#[derive(Debug)]
pub struct LkcError {
    pub failure: LkcFailure,
    pub detail: String,
}

impl From<fl_lkc::Error> for LkcError {
    fn from(e: fl_lkc::Error) -> Self {
        use fl_lkc::Failure as F;
        let failure = match e.failure {
            F::Unreachable => LkcFailure::Unreachable,
            F::Unknown => LkcFailure::Unknown,
            F::InvalidResponse => LkcFailure::InvalidResponse,
            F::Denied => LkcFailure::Denied,
            F::Expired => LkcFailure::Expired,
            F::TooEarly => LkcFailure::TooEarly,
            F::Rejected => LkcFailure::Rejected,
            F::Refused => LkcFailure::Refused,
        };
        Self { failure, detail: e.detail }
    }
}

impl std::fmt::Debug for LkcFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Unreachable => "Unreachable",
            Self::Unknown => "Unknown",
            Self::InvalidResponse => "InvalidResponse",
            Self::Denied => "Denied",
            Self::Expired => "Expired",
            Self::TooEarly => "TooEarly",
            Self::Rejected => "Rejected",
            Self::Refused => "Refused",
        })
    }
}

/// A signed-in (or signed-out) session of one app.
#[frb(opaque)]
pub struct LkcSession(Arc<Session<DartStore>>);

impl LkcSession {
    /// The session [stored] (the JSON [save] last wrote) describes. One saved
    /// in the middle of a refresh is over, and [save] is told so.
    pub async fn restore(
        issuer: String,
        client_id: String,
        api: String,
        stored: Option<String>,
        save: impl Fn(Option<String>) -> DartFnFuture<bool> + Send + Sync + 'static,
    ) -> Result<LkcSession, LkcError> {
        let client = Arc::new(Client::with(&issuer, &client_id, &api)?);
        let store = DartStore(Arc::new(save));
        // A session Dart cannot read back is one it never wrote whole.
        let stored = stored.and_then(|s| serde_json::from_str::<Stored>(&s).ok());
        Ok(Self(Arc::new(Session::restore(client, store, stored).await)))
    }

    #[frb(sync)]
    pub fn signed_in(&self) -> bool {
        self.0.signed_in()
    }

    /// The tokens a browser sign-in was granted: [expires_at_ms] is when the
    /// access token runs out, Unix milliseconds.
    pub async fn sign_in(&self, access: String, refresh: Option<String>, expires_at_ms: i64) -> Result<(), LkcError> {
        Ok(self.0.sign_in(Tokens::received(access, refresh, expires_at_ms)).await?)
    }

    /// The access token when it needs no refresh, without waiting; `None`
    /// asks [LkcSession::access_token].
    #[frb(sync)]
    pub fn fresh_access_token(&self) -> Option<String> {
        self.0.fresh_access_token()
    }

    /// The access token to send, refreshed first when due.
    pub async fn access_token(&self) -> Result<String, LkcError> {
        Ok(self.0.access_token().await?)
    }

    /// Signed out here only: homebase refused the token.
    pub async fn forget(&self) {
        self.0.forget().await;
    }

    /// Signed out, the refresh token revoked at the IdP.
    pub async fn sign_out(&self) {
        self.0.sign_out().await;
    }
}

pub enum LkcSyncErrorKind {
    /// Another version is there now: read, merge, write again.
    Changed,
    Missing,
    TooLarge,
    NotAge,
    /// Homebase's `reason` in [LkcSyncError::reason].
    Refused,
    Busy,
    SignedOut,
    Unreachable,
    Invalid,
}

#[derive(Debug)]
pub struct LkcSyncError {
    pub kind: LkcSyncErrorKind,
    /// `sync_unavailable`, `sync_quota` or `sync_daily_limit` when [kind] is
    /// [LkcSyncErrorKind::Refused].
    pub reason: Option<String>,
    pub detail: String,
}

impl std::fmt::Debug for LkcSyncErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Changed => "Changed",
            Self::Missing => "Missing",
            Self::TooLarge => "TooLarge",
            Self::NotAge => "NotAge",
            Self::Refused => "Refused",
            Self::Busy => "Busy",
            Self::SignedOut => "SignedOut",
            Self::Unreachable => "Unreachable",
            Self::Invalid => "Invalid",
        })
    }
}

impl From<fl_lkc::sync::Error> for LkcSyncError {
    fn from(e: fl_lkc::sync::Error) -> Self {
        let (kind, reason) = match e.kind {
            Kind::Changed => (LkcSyncErrorKind::Changed, None),
            Kind::Missing => (LkcSyncErrorKind::Missing, None),
            Kind::TooLarge => (LkcSyncErrorKind::TooLarge, None),
            Kind::NotAge => (LkcSyncErrorKind::NotAge, None),
            Kind::Refused(r) => (LkcSyncErrorKind::Refused, Some(r).filter(|r| !r.is_empty())),
            Kind::Busy => (LkcSyncErrorKind::Busy, None),
            Kind::SignedOut => (LkcSyncErrorKind::SignedOut, None),
            Kind::Unreachable => (LkcSyncErrorKind::Unreachable, None),
            Kind::Invalid => (LkcSyncErrorKind::Invalid, None),
        };
        Self { kind, reason, detail: e.detail }
    }
}

/// What a download did: [etag] is the version saved, or the one the caller
/// named when unchanged; [missing] when there is no such file.
pub struct LkcFetched {
    pub missing: bool,
    pub saved: bool,
    pub etag: Option<String>,
}

pub struct LkcSyncFile {
    pub name: String,
    pub etag: String,
    pub size: u64,
    pub updated_at: String,
}

pub struct LkcSyncVersion {
    pub etag: String,
    pub size: u64,
    pub written_at: String,
    pub replaced_at: String,
}

/// What another device did: [name] now at [etag], or removed (`None`).
/// [connected]: listening (again), so anything written meanwhile was missed.
pub struct LkcSyncEvent {
    pub connected: bool,
    pub name: Option<String>,
    pub etag: Option<String>,
}

/// One app's files on homebase, on a session.
#[frb(opaque)]
pub struct LkcSync {
    client: Arc<SyncClient<DartStore>>,
    /// The listening going on, stopped when replaced: one connection at most.
    listening: std::sync::Mutex<Option<watch::Sender<bool>>>,
}

impl LkcSync {
    /// [app]: `serverbox`, `gptbox`, …
    #[frb(sync)]
    pub fn new(session: &LkcSession, app: String) -> LkcSync {
        Self { client: Arc::new(SyncClient::new(session.0.clone(), &app)), listening: std::sync::Mutex::new(None) }
    }

    /// Homebase's clock minus this one's, in milliseconds; 0 before an answer.
    #[frb(sync)]
    pub fn offset_ms(&self) -> i64 {
        self.client.offset_ms()
    }

    pub async fn head(&self, name: String) -> Result<Option<String>, LkcSyncError> {
        Ok(self.client.head(&name).await?)
    }

    pub async fn download(&self, name: String, to: String, known: Option<String>) -> Result<LkcFetched, LkcSyncError> {
        let fetched = self.client.download(&name, std::path::Path::new(&to), known.as_deref()).await?;
        Ok(fetched_of(fetched, known))
    }

    pub async fn download_version(&self, name: String, etag: String, to: String) -> Result<LkcFetched, LkcSyncError> {
        Ok(fetched_of(self.client.download_version(&name, &etag, std::path::Path::new(&to)).await?, None))
    }

    /// [from] as [name]'s new version: if it is at [if_match], or, `None`, if
    /// there is none. Answers the new version.
    pub async fn upload(&self, name: String, from: String, if_match: Option<String>) -> Result<String, LkcSyncError> {
        let condition = if_match.map_or(Condition::Absent, Condition::Match);
        Ok(self.client.upload(&name, std::path::Path::new(&from), condition).await?)
    }

    pub async fn delete(&self, name: String, if_match: Option<String>) -> Result<bool, LkcSyncError> {
        Ok(self.client.delete(&name, if_match.as_deref()).await?)
    }

    pub async fn list(&self) -> Result<Vec<LkcSyncFile>, LkcSyncError> {
        Ok(self
            .client
            .list()
            .await?
            .into_iter()
            .map(|f| LkcSyncFile { name: f.name, etag: f.etag, size: f.size, updated_at: f.updated_at })
            .collect())
    }

    pub async fn versions(&self, name: String) -> Result<Vec<LkcSyncVersion>, LkcSyncError> {
        Ok(self
            .client
            .versions(&name)
            .await?
            .into_iter()
            .map(|v| LkcSyncVersion { etag: v.etag, size: v.size, written_at: v.written_at, replaced_at: v.replaced_at })
            .collect())
    }

    /// Other devices' writes, until [LkcSync::stop_listening] or another
    /// [LkcSync::listen], which takes the place of this one.
    #[frb(sync)]
    pub fn listen(&self, sink: StreamSink<LkcSyncEvent>) {
        let (stop, stopped) = watch::channel(false);
        if let Some(previous) = self.listening.lock().unwrap_or_else(|e| e.into_inner()).replace(stop) {
            let _ = previous.send(true);
        }
        flutter_rust_bridge::spawn(crate::lkc_bridge::forward(self.client.clone(), sink, stopped));
    }

    /// Closes the connection [LkcSync::listen] holds.
    #[frb(sync)]
    pub fn stop_listening(&self) {
        if let Some(stop) = self.listening.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = stop.send(true);
        }
    }
}

impl Drop for LkcSync {
    fn drop(&mut self) {
        self.stop_listening();
    }
}

fn fetched_of(fetched: Fetched, known: Option<String>) -> LkcFetched {
    match fetched {
        Fetched::Missing => LkcFetched { missing: true, saved: false, etag: None },
        Fetched::Unchanged => LkcFetched { missing: false, saved: false, etag: known },
        Fetched::Saved(etag) => LkcFetched { missing: false, saved: true, etag: Some(etag) },
    }
}
