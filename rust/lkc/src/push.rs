//! Homebase's push from a signed-in sender (`/v2/push/senders`,
//! `/v2/push/send`): a program of the person's own, such as the ServerBox
//! Monitor, notifies every device the person registered for push.
//!
//! A sender is registered once per install under a key the program makes and
//! keeps; the same key is the same sender after signing in again, so a mute
//! the person set on it holds.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Client, Failure};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Sender {
    pub id: String,
    pub key: String,
    pub name: String,
    /// Muted by the person for every device: a push is taken and sent nowhere.
    pub muted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Info,
    Warning,
    Critical,
}

/// A notification for every device of the person.
#[derive(Debug, Clone, Serialize)]
pub struct Push<'a> {
    /// [Sender::id].
    pub sender: &'a str,
    pub body: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<&'a str>,
    pub level: Level,
    /// What a newer push replaces on the device: letters, digits and `._:-`,
    /// up to 64.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<&'a Value>,
    /// The same key within a day is sent once.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dedupe_key: Option<&'a str>,
}

/// What a push reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Sent {
    pub devices: u32,
    pub sent: u32,
    pub channels: u32,
    /// Devices left out because the person muted them or this sender.
    pub muted: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushFailure {
    /// No such sender (removed by the person): register again.
    SenderUnknown,
    /// Over a limit (per sender, per person); a refused push counts against
    /// none of them.
    RateLimited,
    TooLarge,
    /// The same `dedupe_key` is being sent now.
    InFlight,
    /// Homebase no longer takes the session.
    SignedOut,
    /// Nothing reached homebase, or no answer: worth trying later.
    Unreachable,
    /// Refused for this `reason` (`push_thread`, `push_sender_invalid`, …).
    Refused(String),
    Invalid,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushError {
    pub failure: PushFailure,
    /// For logs; never a token.
    pub detail: String,
}

impl std::fmt::Display for PushError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.failure, self.detail)
    }
}

impl std::error::Error for PushError {}

impl Client {
    /// The sender [key] names, registered now or before; [name] is what the
    /// person sees it as, updated when it changed.
    pub async fn register_sender(&self, access: &str, key: &str, name: &str) -> Result<Sender, PushError> {
        self.push_call(access, "/v2/push/senders", &serde_json::json!({ "key": key, "name": name })).await
    }

    /// Sends [push] as its sender.
    pub async fn push(&self, access: &str, push: &Push<'_>) -> Result<Sent, PushError> {
        self.push_call(access, "/v2/push/send", push).await
    }

    async fn push_call<T: serde::de::DeserializeOwned>(&self, access: &str, path: &str, body: &impl Serialize) -> Result<T, PushError> {
        let url = self.api_url(path);
        let request = self.http.post(&url).bearer_auth(access).header(reqwest::header::ACCEPT, "application/json").json(body);
        let (status, body) = self.send(request, &url).await.map_err(|e| PushError {
            failure: match e.failure {
                Failure::InvalidResponse => PushFailure::Invalid,
                _ => PushFailure::Unreachable,
            },
            detail: e.detail,
        })?;
        let data = answer(&url, status, &body)?;
        serde_json::from_value(data).map_err(|e| PushError { failure: PushFailure::Invalid, detail: format!("{url}: {e}") })
    }
}

/// Homebase's answer: `data` on code 0, else what the refusal means.
fn answer(url: &str, status: u16, body: &[u8]) -> Result<Value, PushError> {
    let error = |failure, detail: String| Err(PushError { failure, detail });
    if status == 409 {
        return error(PushFailure::InFlight, format!("{url}: already pushing this key"));
    }
    if status >= 500 {
        return error(PushFailure::Unreachable, format!("{url}: HTTP {status}"));
    }
    if status == 429 {
        return error(PushFailure::RateLimited, format!("{url}: HTTP 429"));
    }
    let value: Option<Value> = serde_json::from_slice(body).ok();
    let Some(json) = value.filter(Value::is_object) else {
        return error(PushFailure::Unreachable, format!("{url}: HTTP {status}"));
    };
    let reason = json["reason"].as_str().unwrap_or_default().to_string();
    match json.get("code").map(Value::as_u64) {
        None if (200..300).contains(&status) => Ok(json.get("data").cloned().unwrap_or(Value::Null)),
        Some(Some(0)) => Ok(json.get("data").cloned().unwrap_or(Value::Null)),
        Some(Some(2)) => error(PushFailure::SignedOut, format!("{url}: perm {reason}")),
        Some(Some(1)) => error(PushFailure::Unreachable, format!("{url}: code 1")),
        Some(Some(code)) => {
            let failure = match reason.as_str() {
                "push_sender_unknown" => PushFailure::SenderUnknown,
                "push_rate_limited" => PushFailure::RateLimited,
                "push_too_large" => PushFailure::TooLarge,
                _ => PushFailure::Refused(reason.clone()),
            };
            error(failure, format!("{url}: code {code} {reason}"))
        }
        _ => error(PushFailure::Invalid, format!("{url}: HTTP {status} without a code")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusals_read_by_reason() {
        let url = "/v2/push/send";
        let ok = answer(url, 200, br#"{"code":0,"data":{"devices":2,"sent":1,"channels":0,"muted":1}}"#).unwrap();
        assert_eq!(serde_json::from_value::<Sent>(ok).unwrap(), Sent { devices: 2, sent: 1, channels: 0, muted: 1 });
        let failure = |status, body: &str| answer(url, status, body.as_bytes()).unwrap_err().failure;
        assert_eq!(failure(200, r#"{"code":3,"msg":"x","reason":"push_sender_unknown"}"#), PushFailure::SenderUnknown);
        assert_eq!(failure(200, r#"{"code":5,"msg":"Rate limited","reason":"push_rate_limited"}"#), PushFailure::RateLimited);
        assert_eq!(failure(200, r#"{"code":4,"reason":"push_thread"}"#), PushFailure::Refused("push_thread".into()));
        assert_eq!(failure(200, r#"{"code":2,"msg":"perm"}"#), PushFailure::SignedOut);
        assert_eq!(failure(409, r#"{"code":4,"msg":"Pushing this key already"}"#), PushFailure::InFlight);
        assert_eq!(failure(502, "<html>bad gateway</html>"), PushFailure::Unreachable);
        assert_eq!(failure(200, r#"{"code":1}"#), PushFailure::Unreachable);
        assert_eq!(failure(503, r#"{"code":0,"data":{}}"#), PushFailure::Unreachable);
        assert_eq!(failure(429, r#"{"code":0,"data":{}}"#), PushFailure::RateLimited);
    }

    #[test]
    fn a_push_leaves_out_what_it_has_not() {
        let push = Push { sender: "s", body: "CPU 95%", title: None, level: Level::Warning, thread: Some("cpu"), data: None, dedupe_key: None };
        assert_eq!(serde_json::to_value(&push).unwrap(), serde_json::json!({ "sender": "s", "body": "CPU 95%", "level": "warning", "thread": "cpu" }));
    }
}
