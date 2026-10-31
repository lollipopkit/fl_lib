//! A signed-in session: its tokens, the one place they are refreshed.
//!
//! A refresh is sent only once due ([`Tokens::due`]), one at a time, and only
//! after the [`Store`] has saved it as marked: a refresh whose answer is lost
//! (the process killed, the connection dropped) leaves the mark behind, and
//! a session restored marked is over. The token it sent may be spent, and
//! the IdP answers a spent one sent again by ending every session of the
//! person. The monitor agent keeps the same rule in its own row
//! (`monitor/src/lkc.rs`).

use std::future::Future;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::{Client, Error, Failure, Tokens, now_ms};

/// Where a session is kept between runs: the app's keychain, through Dart.
pub trait Store: Send + Sync + 'static {
    /// Saves [state]; `None` is signed out. A refresh is sent only after the
    /// save of its mark answered `Ok`.
    fn save(&self, state: Option<Stored>) -> impl Future<Output = Result<(), String>> + Send;
}

/// A session as saved. The keys are those fl_lib's Dart `LkcTokens` wrote,
/// so a session saved by a build before this one is read as it is.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stored {
    pub access: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh: Option<String>,
    /// Unix milliseconds.
    pub expires_at: i64,
    /// A refresh was sent and its answer not yet saved.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub refreshing: bool,
}

impl Stored {
    fn of(tokens: &Tokens, refreshing: bool) -> Self {
        Self { access: tokens.access.clone(), refresh: tokens.refresh.clone(), expires_at: tokens.expires_at_ms, refreshing }
    }
}

impl std::fmt::Debug for Stored {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Stored").field("expires_at", &self.expires_at).field("refreshing", &self.refreshing).finish_non_exhaustive()
    }
}

pub struct Session<S: Store> {
    client: Arc<Client>,
    store: S,
    tokens: Mutex<Option<Tokens>>,
    /// Held across a refresh, and by everything that replaces the tokens.
    refreshing: tokio::sync::Mutex<()>,
}

impl<S: Store> Session<S> {
    /// The session [stored] last saved. One saved marked lost its refresh's
    /// answer: it is over, and [store] is told so.
    pub async fn restore(client: Arc<Client>, store: S, stored: Option<Stored>) -> Self {
        let tokens = match stored {
            Some(s) if s.refreshing => {
                let _ = store.save(None).await;
                None
            }
            Some(s) => Some(Tokens::stored(s.access, s.refresh, s.expires_at)),
            None => None,
        };
        Self { client, store, tokens: Mutex::new(tokens), refreshing: tokio::sync::Mutex::new(()) }
    }

    pub fn client(&self) -> &Arc<Client> {
        &self.client
    }

    pub fn signed_in(&self) -> bool {
        self.current().is_some()
    }

    fn current(&self) -> Option<Tokens> {
        self.tokens.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn set(&self, tokens: Option<Tokens>) {
        *self.tokens.lock().unwrap_or_else(|e| e.into_inner()) = tokens;
    }

    /// Tokens a sign-in was granted, saved. A session they replace is let go
    /// of at the IdP; tokens that cannot be saved are revoked, as nothing
    /// would hold them.
    pub async fn sign_in(&self, tokens: Tokens) -> Result<(), Error> {
        let _guard = self.refreshing.lock().await;
        // No expiry, or one already near: the first request would refresh at
        // once, and a refresh that early ends every session of the person.
        if tokens.due(now_ms()) {
            self.revoke(tokens.refresh).await;
            return Err(Error::new(Failure::InvalidResponse, "the access token is due on receipt"));
        }
        if let Err(e) = self.store.save(Some(Stored::of(&tokens, false))).await {
            self.revoke(tokens.refresh).await;
            return Err(Error::new(Failure::Unknown, format!("saving the session: {e}")));
        }
        let previous = self.current().and_then(|t| t.refresh);
        if previous != tokens.refresh {
            self.revoke(previous).await;
        }
        self.set(Some(tokens));
        Ok(())
    }

    /// The access token, when it can be sent without a refresh: not yet due.
    /// `None` asks [`Session::access_token`], which refreshes it.
    pub fn fresh_access_token(&self) -> Option<String> {
        self.current().filter(|t| !t.due(now_ms())).map(|t| t.access)
    }

    /// The access token to send, refreshed first when due. Signed out, or
    /// signed out now because the session is over: [`Failure::Rejected`].
    pub async fn access_token(&self) -> Result<String, Error> {
        let _guard = self.refreshing.lock().await;
        let Some(tokens) = self.current() else {
            return Err(Error::new(Failure::Rejected, "signed out"));
        };
        if !tokens.due(now_ms()) {
            return Ok(tokens.access);
        }
        if tokens.refresh.is_none() {
            // Due, with nothing to renew it by: it is over.
            self.drop_session().await;
            return Err(Error::new(Failure::Rejected, "the access token ran out and there is no refresh token"));
        }
        // Not sent when the mark cannot be saved.
        if let Err(e) = self.store.save(Some(Stored::of(&tokens, true))).await {
            return Err(Error::new(Failure::Unreachable, format!("not refreshing, the session cannot be saved: {e}")));
        }
        match self.client.refresh(&tokens).await {
            Ok(fresh) => {
                if let Err(e) = self.store.save(Some(Stored::of(&fresh, false))).await {
                    // Nothing would hold the renewed token: revoked, and the
                    // one sent is spent.
                    self.drop_session().await;
                    self.revoke(fresh.refresh).await;
                    return Err(Error::new(Failure::Rejected, format!("saving a refresh: {e}")));
                }
                let access = fresh.access.clone();
                self.set(Some(fresh));
                Ok(access)
            }
            // Never reached the IdP, or refused without saying the token is
            // gone (a clock off, a user disabled for now): the session stays,
            // its access token good until it runs out.
            Err(e) if matches!(e.failure, Failure::Unreachable | Failure::Refused | Failure::Denied | Failure::TooEarly) => {
                // Left marked, the next start signs out instead: safe either way.
                let _ = self.store.save(Some(Stored::of(&tokens, false))).await;
                Ok(tokens.access)
            }
            // Taken back or run out, or sent with no answer this can use:
            // possibly spent.
            Err(e) => {
                self.drop_session().await;
                Err(Error::new(Failure::Rejected, e.detail))
            }
        }
    }

    /// Signed out here only: homebase refused the token, which says nothing
    /// a revocation could still reach.
    pub async fn forget(&self) {
        let _guard = self.refreshing.lock().await;
        self.drop_session().await;
    }

    /// Signed out, and the refresh token revoked at the IdP, best effort.
    pub async fn sign_out(&self) {
        let _guard = self.refreshing.lock().await;
        let refresh = self.current().and_then(|t| t.refresh);
        self.drop_session().await;
        self.revoke(refresh).await;
    }

    async fn drop_session(&self) {
        self.set(None);
        let _ = self.store.save(None).await;
    }

    async fn revoke(&self, refresh: Option<String>) {
        if let Some(refresh) = refresh {
            let _ = self.client.revoke(&refresh).await;
        }
    }
}

#[cfg(test)]
mod tests;
