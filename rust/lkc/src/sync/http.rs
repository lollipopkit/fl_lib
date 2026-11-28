//! Requests to homebase and what its answers say.

use super::*;

impl<S: Store> SyncClient<S> {
    /// The version a write's `204` names.
    pub(super) async fn written_version_for(&self, expected_session: Option<u64>, response: reqwest::Response) -> Result<String, Error> {
        match response.status() {
            StatusCode::NO_CONTENT => self.etag(&response).ok_or_else(|| Error::new(Kind::Invalid, "a write without its version")),
            StatusCode::OK => Err(self.json_for::<Value>(expected_session, response, MAX_JSON).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a write answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    pub(super) async fn json<T: DeserializeOwned>(&self, response: reqwest::Response) -> Result<T, Error> {
        self.json_within(response, MAX_JSON).await
    }

    pub(super) async fn json_within<T: DeserializeOwned>(&self, response: reqwest::Response, max: usize) -> Result<T, Error> {
        self.json_for(None, response, max).await
    }

    pub(super) async fn json_for<T: DeserializeOwned>(
        &self,
        expected_session: Option<u64>,
        response: reqwest::Response,
        max: usize,
    ) -> Result<T, Error> {
        let status = response.status();
        if !status.is_success() {
            return Err(refusal(response).await);
        }
        let url = response.url().path().to_string();
        let body = read_limited(response, max).await?;
        match crate::unwrap(&url, status.as_u16(), &body) {
            Ok(data) => serde_json::from_value(data).map_err(|e| Error::new(Kind::Invalid, format!("{url}: {e}"))),
            Err(e) if e.failure == Failure::Rejected => {
                self.session.forget_for(expected_session, format!("homebase refused the session at {url}: {}", e.detail)).await;
                Err(Error::new(Kind::SignedOut, e.detail))
            }
            Err(e) if e.failure == Failure::Unreachable => Err(Error::new(Kind::Unreachable, e.detail)),
            Err(e) => Err(Error::new(Kind::Refused(String::new()), e.detail)),
        }
    }

    /// Sends a request; a `503` homebase asks to be retried shortly
    /// (`Retry-After` up to [`RETRY_AFTER_MAX`]) is sent once more, when the
    /// request may be: any but a `POST` without an `Idempotency-Key`.
    pub(super) async fn send(
        &self,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        self.send_for(None, method, path, build).await
    }

    pub(super) async fn send_for(
        &self,
        bound: Option<(u64, u64, bool)>,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, Error> {
        let client = self.session.client();
        let url = client.api_url(path);
        let mut again = true;
        loop {
            if let Some((expected_session, expected_personal_gen, personal_was_attached)) = bound
                && (self.session.identity() != Some(expected_session)
                    || (personal_was_attached && self.personal_generation() != expected_personal_gen))
            {
                return Err(Error::new(Kind::SignedOut, "session changed during request"));
            }
            let token_res = match bound {
                Some((expected_session, _, _)) => self.session.access_token_for(expected_session).await,
                None => self.session.access_token().await,
            };
            let token = token_res.map_err(|e| match e.failure {
                Failure::Rejected => Error::new(Kind::SignedOut, e.detail),
                _ => Error::new(Kind::Unreachable, e.detail),
            })?;
            if let Some((_, expected_personal_gen, true)) = bound
                && self.personal_generation() != expected_personal_gen
            {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed during request"));
            }
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

    pub(super) fn etag(&self, response: &reqwest::Response) -> Option<String> {
        let tag = response.headers().get(header::ETAG)?.to_str().ok()?;
        Some(tag.trim_matches('"').to_string()).filter(|t| !t.is_empty())
    }

    /// A bodiless `200` without the `ETag` every file answer carries: homebase
    /// refusing the session, or something in front of it (a captive portal, a
    /// proxy). Only homebase's own word, read from a body, signs out.
    pub(super) async fn without_version(&self) -> Error {
        match self.list().await {
            Err(e) => e,
            Ok(_) => Error::new(Kind::Unreachable, "an answer without its version"),
        }
    }

    fn app_segment(&self) -> Result<&str, Error> {
        valid(&self.app, 64, false).then_some(self.app.as_str()).ok_or_else(|| Error::new(Kind::Invalid, "not an app name"))
    }

    pub(super) fn app_path(&self) -> Result<String, Error> {
        let app = self.app_segment()?;
        match &self.team {
            None => Ok(format!("/v2/sync/{app}")),
            Some(t) if team_bytes(&t.id).is_ok() => Ok(format!("/v2/teams/{}/sync/{app}", t.id)),
            Some(_) => Err(Error::new(Kind::Invalid, "not a team id")),
        }
    }

    pub(super) fn file_path(&self, name: &str) -> Result<String, Error> {
        if !valid(name, 128, true) {
            return Err(Error::new(Kind::Invalid, "not a file name"));
        }
        Ok(format!("{}/{name}", self.app_path()?))
    }
}

/// Homebase's names: `[a-z0-9._-]` for an app, uppercase too for a file, not
/// starting with a dot.
pub(super) fn valid(s: &str, max: usize, upper: bool) -> bool {
    !s.is_empty()
        && s.len() <= max
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-') || (upper && b.is_ascii_uppercase()))
}

pub(super) fn valid_log_id(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

/// The snapshot a `/snapshot` answer names (`Sync-Log`, `Sync-Seq`): none
/// without both, or with a log id [valid_log_id] does not take.
pub(super) fn answered_snapshot(response: &reqwest::Response) -> Option<Snapshot> {
    let log = header_non_empty(response, "sync-log").filter(|l| valid_log_id(l))?;
    let seq = header_non_empty(response, "sync-seq")?.parse().ok()?;
    Some(Snapshot { log, seq, signed: Signed::of(response) })
}

/// A log id homebase answered with: none, or one [valid_log_id] takes, so a
/// malformed one is never kept as observed (and refused later as a cursor).
pub(super) fn answered_log(log: Option<String>) -> Result<Option<String>, Error> {
    match log {
        Some(l) if !valid_log_id(&l) => Err(Error::new(Kind::Invalid, "a malformed log id")),
        other => Ok(other),
    }
}

pub(super) fn quote(etag: &str) -> String {
    format!("\"{etag}\"")
}

pub(super) fn header_non_empty(response: &reqwest::Response, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub(super) fn condition_on(request: reqwest::RequestBuilder, condition: &Condition) -> reqwest::RequestBuilder {
    match condition {
        Condition::Match(etag) => request.header(header::IF_MATCH, quote(etag)),
        Condition::Absent => request.header(header::IF_NONE_MATCH, "*"),
    }
}

/// A refusal by its status; a `403` by homebase's `reason`.
pub(super) async fn refusal(response: reqwest::Response) -> Error {
    let status = response.status();
    let kind = match status {
        StatusCode::PRECONDITION_FAILED => Kind::Changed,
        StatusCode::NOT_FOUND => Kind::Missing,
        StatusCode::UNSUPPORTED_MEDIA_TYPE => Kind::NotAge,
        StatusCode::TOO_MANY_REQUESTS => Kind::Busy,
        StatusCode::UNAUTHORIZED => Kind::SignedOut,
        StatusCode::FORBIDDEN | StatusCode::CONFLICT | StatusCode::UNPROCESSABLE_ENTITY | StatusCode::PAYLOAD_TOO_LARGE => {
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
            // A bare 413: over what one request carries, not the plan's.
            if status == StatusCode::PAYLOAD_TOO_LARGE && reason.is_empty() {
                return Error::new(Kind::TooLarge, format!("HTTP {status}"));
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
pub(super) fn stale_epoch(response: &reqwest::Response, sent: Option<i64>) -> Option<i64> {
    let current = response.headers().get("x-team-epoch")?.to_str().ok()?.parse().ok()?;
    (Some(current) != sent).then_some(current)
}
