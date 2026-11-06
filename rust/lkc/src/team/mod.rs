//! Homebase's teams (`/v2/teams/*`, `/v2/keys`): members sharing a sync
//! space under a key only their devices hold ([`crypto`] says how it is
//! derived, wrapped, attested and signed).
//!
//! [`TeamClient`] is homebase's API as it is; [`Teams`] is what a device
//! does with it once its account key is open: every key it takes checked
//! ([`Keyring::verify`]) against what it saw before ([`Trust`]), every admin
//! flow (the first key, a rotation, a grant, an invite, re-encryption), and
//! each team's sealed files and log ([`TeamSpace`]). Nothing grants or
//! confirms on its own: who is a member is homebase's word, so a grant, and
//! a key wrapped to a member no key holder attested, need the person to
//! compare a [`crypto::fingerprint`].

pub mod crypto;
pub mod identity;
mod space;
mod teams;
mod trust;
mod verify;

use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use reqwest::Method;
use reqwest::header::ACCEPT;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::session::{Session, Store};
use crate::sync;
use crate::{Failure, unreachable};
use crypto::CryptoError;
pub use space::{TeamLog, TeamSpace};
pub use teams::{MemberView, Teams, TeamStatus};
pub use trust::{Keeper, Trust};
pub use verify::Keyring;

const MAX_JSON: usize = 2 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TeamError {
    /// Homebase's refusal: its `reason` (`team_epoch_stale`,
    /// `team_key_members`, `team_signature`, …).
    Refused(String),
    NotFound,
    /// The caller's role does not allow it.
    Perm,
    SignedOut,
    Unreachable(String),
    Invalid(String),
    /// The account key's password does not open it.
    WrongPassphrase,
    Crypto(CryptoError),
    /// What homebase gave does not hold together: a key not the one its
    /// epoch's signature names, a signature by one who did not manage the
    /// team, a signing key other than the one pinned.
    Untrusted(String),
    /// A signing key other than the newest [`Trust`] holds for this user:
    /// theirs changed (a rotation), or homebase is lying. The person compares
    /// it ([`crypto::fingerprint`]) and accepts it, or not.
    SigningKeyChanged { user_id: String, signing_key: String },
    /// Members whose keys no holder of the current key attested, nor the
    /// person confirmed by fingerprint: confirmed first, then asked again.
    Unconfirmed(Vec<String>),
    /// Approved members who published no key yet: a commit needs them all.
    NoRecipient(Vec<String>),
    /// Homebase holds another account key for this account than the one
    /// open here: another device rotated it. Opened again from LK Cloud.
    AccountKeyReplaced,
    /// The team's key moved on meanwhile: the current epoch.
    StaleEpoch(i64),
    /// Approved, holding no key yet: an admin's device grants one.
    Unkeyed,
    /// This account joined after the current epoch's commit: the next is
    /// made by one of its members, or after the owner's signed promotion
    /// ([Teams::set_role]).
    PromotionNeeded,
    /// A sync request of the space failed.
    Sync(sync::Kind, String),
}

impl std::fmt::Display for TeamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for TeamError {}

impl From<CryptoError> for TeamError {
    fn from(e: CryptoError) -> Self {
        Self::Crypto(e)
    }
}

impl From<sync::Error> for TeamError {
    fn from(e: sync::Error) -> Self {
        Self::Sync(e.kind, e.detail)
    }
}

/// A team's id as its 16 bytes.
pub fn team_bytes(id: &str) -> Result<[u8; 16], TeamError> {
    let hex: String = id.chars().filter(|c| *c != '-').collect();
    if hex.len() != 32 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(TeamError::Invalid(format!("not a team id: {id}")));
    }
    let mut out = [0u8; 16];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).expect("hex");
    }
    Ok(out)
}

/// A user id as it goes into a path: homebase's own (letters, digits and
/// `-_.@:`), never one that could reach another endpoint.
pub(crate) fn user_segment(id: &str) -> Result<&str, TeamError> {
    let ok = !id.is_empty() && id != "." && id != ".." && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.@:".contains(&b));
    ok.then_some(id).ok_or_else(|| TeamError::Invalid(format!("not a user id: {id}")))
}

/// A team's id as homebase writes it: lowercase, hyphenated. What a device
/// keeps of a team is under this, however the id came.
pub fn canonical(id: &str) -> Result<String, TeamError> {
    let b = team_bytes(id)?;
    let h = crypto::hex(&b);
    Ok(format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..]))
}

pub(crate) fn b64(b: &[u8]) -> String {
    BASE64.encode(b)
}

pub(crate) fn unb64(s: &str, what: &str) -> Result<Vec<u8>, TeamError> {
    BASE64.decode(s).map_err(|_| TeamError::Invalid(format!("{what}: not base64")))
}

// Wire types, as homebase answers them.

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct PublishedKey {
    pub recipient: Option<String>,
    pub signing_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Team {
    pub id: String,
    pub name: String,
    pub epoch: i64,
    pub migrated_epoch: i64,
    pub rotation_needed: bool,
    pub approval_required: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Membership {
    #[serde(flatten)]
    pub team: Team,
    pub role: String,
    pub approved: bool,
    pub member_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Member {
    pub user_id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub role: String,
    pub approved: bool,
    pub joined_at: String,
    pub recipient: Option<String>,
    /// Base64.
    pub attestation: Option<String>,
    /// Holds the current epoch's key, wrapped to its current recipient.
    pub keyed: bool,
    #[serde(default)]
    pub signing_key: Option<String>,
}

impl Member {
    pub fn manages(&self) -> bool {
        manages(&self.role)
    }
}

pub(crate) fn manages(role: &str) -> bool {
    role == "admin" || role == "owner"
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Invite {
    pub id: String,
    pub role: String,
    pub created_by: String,
    pub epoch: i64,
    pub keyed: bool,
    pub uses_left: i32,
    pub expires_at: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TeamDetail {
    #[serde(flatten)]
    pub membership: Membership,
    pub members: Vec<Member>,
    pub invites: Option<Vec<Invite>>,
    pub max_members: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct EpochMember {
    pub user_id: String,
    pub role: String,
    pub recipient: String,
    /// Base64, 32 bytes.
    pub signing_key: String,
}

/// An epoch's signed record.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct EpochRecord {
    pub epoch: i64,
    /// Base64, 32 bytes.
    pub key_id: String,
    /// The key id of the epoch before; 32 zero bytes for the first.
    pub prev_key_id: String,
    pub committed_by: String,
    /// The committer's, when they committed.
    pub signing_key: String,
    pub signature: String,
    pub commit_mac: Option<String>,
    pub members: Vec<EpochMember>,
    /// Promotions signed during the epoch ([crypto::role_message]).
    #[serde(default)]
    pub roles: Vec<RoleGrant>,
}

/// A promotion signed during an epoch: [signed_by] (under [signer_key])
/// made [user_id] (under [signing_key]) [role]. All base64.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct RoleGrant {
    pub user_id: String,
    pub role: String,
    pub signing_key: String,
    pub signed_by: String,
    pub signer_key: String,
    pub signature: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WireWrap {
    pub epoch: i64,
    pub recipient: String,
    pub wrap: String,
    /// A grant's (an admin's, or the member's own): `None` for a commit's,
    /// which its [EpochRecord] covers.
    pub signed_by: Option<String>,
    pub signing_key: Option<String>,
    pub signature: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct KeyState {
    pub epoch: i64,
    pub migrated_epoch: i64,
    pub rotation_needed: bool,
    pub commit_mac: Option<String>,
    pub wraps: Vec<WireWrap>,
    /// From the first, oldest first.
    #[serde(default)]
    pub epochs: Vec<EpochRecord>,
    /// More records follow the last: asked again after it.
    #[serde(default)]
    pub epochs_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct InviteMade {
    #[serde(flatten)]
    pub invite: Invite,
    pub token: String,
}

/// An invite as its link's holder sees it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct InviteView {
    pub team_id: String,
    pub team_name: String,
    pub role: String,
    pub epoch: i64,
    pub approval_required: bool,
    pub recipient: Option<String>,
    pub wrap: Option<String>,
    #[serde(default)]
    pub key_id: Option<String>,
    #[serde(default)]
    pub signed_by: Option<String>,
    #[serde(default)]
    pub signing_key: Option<String>,
    #[serde(default)]
    pub signature: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Joined {
    pub team_id: String,
    pub approved: bool,
}

/// Who an invite lets in, how often and for how long.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteTerms {
    /// `member`: an admin is made by a signed promotion
    /// ([Teams::set_role]), never by a link.
    pub role: String,
    /// 1 to 100.
    pub uses: i32,
    /// 1 to 7.
    pub days: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteLink {
    pub made: InviteMade,
    /// The link's fragment (after `#`) when it carries the key: never sent to
    /// homebase.
    pub secret: Option<String>,
}

/// What [Teams::reencrypt] left to the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reencrypted {
    /// The space is of the current epoch, and homebase took it so.
    Migrated,
    /// These files are sealed under an epoch this device holds no key of
    /// (left out as unchecked): another admin's device re-encrypts them.
    Unreadable(Vec<String>),
    /// The files are; the log is not: the app writes a snapshot (sealed with
    /// the current key) up to the head, then asks again.
    SnapshotNeeded,
}

/// Homebase's teams API for the signed-in account, as it is.
pub struct TeamClient<S: Store> {
    session: Arc<Session<S>>,
}

impl<S: Store> TeamClient<S> {
    pub fn new(session: Arc<Session<S>>) -> Self {
        Self { session }
    }

    pub fn session(&self) -> &Arc<Session<S>> {
        &self.session
    }

    async fn call<T: serde::de::DeserializeOwned>(&self, method: Method, path: &str, body: Option<&Value>) -> Result<T, TeamError> {
        let client = self.session.client();
        let url = client.api_url(path);
        let token = self.session.access_token().await.map_err(|e| match e.failure {
            Failure::Rejected => TeamError::SignedOut,
            _ => TeamError::Unreachable(e.detail),
        })?;
        let mut request = client.transfer().request(method, &url).bearer_auth(token).header(ACCEPT, "application/json");
        if let Some(body) = body {
            request = request.json(body);
        }
        let mut response = request.send().await.map_err(|e| TeamError::Unreachable(unreachable(&url, e).detail))?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| TeamError::Unreachable(e.to_string()))? {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > MAX_JSON {
                return Err(TeamError::Invalid(format!("{url}: answer too large")));
            }
        }
        let data = self.answer(&url, status, &bytes).await?;
        serde_json::from_value(data).map_err(|e| TeamError::Invalid(format!("{url}: {e}")))
    }

    /// Homebase's answer: `data` on code 0, else what the refusal means.
    async fn answer(&self, url: &str, status: u16, body: &[u8]) -> Result<Value, TeamError> {
        if status >= 500 || status == 429 {
            return Err(TeamError::Unreachable(format!("{url}: HTTP {status}")));
        }
        let Some(json) = serde_json::from_slice::<Value>(body).ok().filter(Value::is_object) else {
            return Err(TeamError::Unreachable(format!("{url}: HTTP {status}")));
        };
        let reason = json["reason"].as_str().unwrap_or_default().to_string();
        match json.get("code").map(Value::as_u64) {
            None if (200..300).contains(&status) => Ok(json.get("data").cloned().unwrap_or(Value::Null)),
            Some(Some(0)) => Ok(json.get("data").cloned().unwrap_or(Value::Null)),
            Some(Some(1)) => Err(TeamError::Unreachable(format!("{url}: code 1"))),
            // `perm`: a role that does not allow it (`team_role`), else a
            // token homebase no longer takes.
            Some(Some(2)) if reason == "team_role" => Err(TeamError::Perm),
            Some(Some(2)) if reason.is_empty() => {
                self.session.forget(format!("homebase refused the session at {url}")).await;
                Err(TeamError::SignedOut)
            }
            Some(Some(3)) if reason.is_empty() => Err(TeamError::NotFound),
            Some(Some(_)) => Err(TeamError::Refused(reason)),
            _ => Err(TeamError::Invalid(format!("{url}: HTTP {status} without a code"))),
        }
    }

    // Keys of the account.

    pub async fn user_key(&self) -> Result<PublishedKey, TeamError> {
        self.call(Method::GET, "/v2/keys", None).await
    }

    pub(crate) async fn set_user_key(&self, recipient: &str, signing_key: &str) -> Result<(), TeamError> {
        self.call::<Value>(Method::PUT, "/v2/keys", Some(&serde_json::json!({ "recipient": recipient, "signing_key": signing_key }))).await.map(|_| ())
    }

    // Teams.

    pub async fn list(&self) -> Result<Vec<Membership>, TeamError> {
        self.call(Method::GET, "/v2/teams", None).await
    }

    pub async fn create(&self, name: &str) -> Result<Team, TeamError> {
        self.call(Method::POST, "/v2/teams", Some(&serde_json::json!({ "name": name }))).await
    }

    /// Deletes team [id], its synced files with it: the owner's.
    pub async fn delete(&self, id: &str) -> Result<(), TeamError> {
        team_bytes(id)?;
        self.call::<Value>(Method::DELETE, &format!("/v2/teams/{id}"), None).await.map(|_| ())
    }

    /// Removes [user_id] from team [id] (or leaves it, the caller's own):
    /// once the team has a key, it then needs a new one.
    pub async fn remove_member(&self, id: &str, user_id: &str) -> Result<(), TeamError> {
        team_bytes(id)?;
        self.call::<Value>(Method::DELETE, &format!("/v2/teams/{id}/members/{}", user_segment(user_id)?), None).await.map(|_| ())
    }

    pub async fn revoke_invite(&self, id: &str, invite: &str) -> Result<(), TeamError> {
        team_bytes(id)?;
        team_bytes(invite)?;
        self.call::<Value>(Method::DELETE, &format!("/v2/teams/{id}/invites/{invite}"), None).await.map(|_| ())
    }

    pub async fn detail(&self, id: &str) -> Result<TeamDetail, TeamError> {
        team_bytes(id)?;
        self.call(Method::GET, &format!("/v2/teams/{id}"), None).await
    }

    /// The team's key state, with every epoch's record (read page by page).
    pub async fn key_state(&self, id: &str) -> Result<KeyState, TeamError> {
        team_bytes(id)?;
        let mut state: KeyState = self.call(Method::GET, &format!("/v2/teams/{id}/keys"), None).await?;
        while state.epochs_more {
            let since = state.epochs.last().map_or(0, |r| r.epoch);
            let page: KeyState = self.call(Method::GET, &format!("/v2/teams/{id}/keys?since={since}"), None).await?;
            // A page of a later state: the key moved on meanwhile.
            if page.epoch != state.epoch {
                return Err(TeamError::StaleEpoch(page.epoch));
            }
            if page.epochs.first().is_none_or(|r| r.epoch != since + 1) {
                return Err(TeamError::Invalid("a page of records not following the last".into()));
            }
            state.epochs.extend(page.epochs);
            state.epochs_more = page.epochs_more;
        }
        Ok(state)
    }

    pub async fn request_rotation(&self, id: &str) -> Result<(), TeamError> {
        team_bytes(id)?;
        self.call::<Value>(Method::POST, &format!("/v2/teams/{id}/keys/rotation"), None).await.map(|_| ())
    }

    pub async fn invite(&self, token: &str) -> Result<InviteView, TeamError> {
        if token.len() != 43 || !token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err(TeamError::NotFound);
        }
        self.call(Method::GET, &format!("/v2/teams/invites/{token}"), None).await
    }

    pub(crate) async fn post(&self, path: &str, body: &Value) -> Result<Value, TeamError> {
        self.call(Method::POST, path, Some(body)).await
    }

    pub(crate) async fn put(&self, path: &str, body: &Value) -> Result<Value, TeamError> {
        self.call(Method::PUT, path, Some(body)).await
    }
}

#[cfg(test)]
mod tests;
