use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::json;

use super::*;
use crate::fake::{Fake, Request, Response, discovery};

/// Every save, in order; a save fails while [fail] is set.
#[derive(Clone, Default)]
struct Memory {
    saves: Arc<Mutex<Vec<Option<Stored>>>>,
    fail: Arc<AtomicBool>,
}

impl Store for Memory {
    async fn save(&self, state: Option<Stored>) -> Result<(), String> {
        if self.fail.load(Ordering::SeqCst) {
            return Err("full".into());
        }
        self.saves.lock().unwrap().push(state);
        Ok(())
    }
}

impl Memory {
    fn last(&self) -> Option<Option<Stored>> {
        self.saves.lock().unwrap().last().cloned()
    }
}

/// The IdP, answering a refresh with [token].
async fn idp(token: impl Fn(&Request) -> Response + Send + Sync + 'static) -> Fake {
    Fake::start(move |r| {
        let base = format!("http://{}", r.header("host").unwrap());
        match r.path() {
            "/auth/v1/.well-known/openid-configuration" => Response::json(200, discovery(&base)),
            "/auth/v1/oidc/token" => token(r),
            "/auth/v1/oidc/token/revoke" => Response::status(200),
            _ => Response::status(404),
        }
    })
    .await
}

fn granted() -> Response {
    Response::json(200, json!({ "access_token": "a2", "refresh_token": "r2", "expires_in": 300 }))
}

fn client(fake: &Fake) -> Arc<Client> {
    Arc::new(Client::with(&fake.issuer(), "app", &fake.base).unwrap())
}

/// Saved tokens [secs] from running out.
fn stored(secs: i64) -> Stored {
    Stored { access: "a1".into(), refresh: Some("r1".into()), expires_at: now_ms() + secs * 1000, refreshing: false }
}

#[tokio::test]
async fn a_token_not_due_is_not_refreshed() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(3600))).await;
    assert_eq!(session.access_token().await.unwrap(), "a1");
    assert_eq!(session.fresh_access_token().as_deref(), Some("a1"));
    assert!(fake.requests("/auth/v1/oidc/token").is_empty());

    let due = Session::restore(client(&fake), Memory::default(), Some(stored(10))).await;
    assert_eq!(due.fresh_access_token(), None, "a due one is the refresh's");
}

#[tokio::test]
async fn a_refresh_is_marked_before_it_is_sent_and_saved_after() {
    let store = Memory::default();
    let seen = store.clone();
    let fake = idp(move |r| {
        // What was saved when the refresh arrived.
        assert!(seen.last().unwrap().unwrap().refreshing, "sent before the mark was saved");
        assert_eq!(r.form("refresh_token").as_deref(), Some("r1"));
        granted()
    })
    .await;
    let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
    assert_eq!(session.access_token().await.unwrap(), "a2");
    let last = store.last().unwrap().unwrap();
    assert_eq!((last.access.as_str(), last.refresh.as_deref(), last.refreshing), ("a2", Some("r2"), false));
    // Fresh now: not sent again.
    assert_eq!(session.access_token().await.unwrap(), "a2");
    assert_eq!(fake.requests("/auth/v1/oidc/token").len(), 1);
}

#[tokio::test]
async fn a_refresh_whose_answer_is_lost_signs_out() {
    let fake = idp(|_| Response::dropped()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
    assert_eq!(session.access_token().await.unwrap_err().failure, Failure::Rejected);
    assert!(!session.signed_in());
    assert_eq!(store.last(), Some(None));
}

#[tokio::test]
async fn a_session_saved_marked_is_over() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(Stored { refreshing: true, ..stored(3600) })).await;
    assert!(!session.signed_in());
    assert_eq!(store.last(), Some(None));
    assert!(fake.seen.lock().unwrap().is_empty(), "nothing is sent for it");
}

#[tokio::test]
async fn a_refresh_token_the_idp_says_is_gone_signs_out() {
    let fake = idp(|_| Response::json(401, json!({ "error": "JwtToken", "message": "Invalid `iss`" }))).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
    assert_eq!(session.access_token().await.unwrap_err().failure, Failure::Rejected);
    assert_eq!(store.last(), Some(None));
}

#[tokio::test]
async fn a_refresh_that_never_reached_the_idp_keeps_the_session() {
    // A rate limit, and a refusal that says nothing of the token.
    for answer in [Response::status(429), Response::json(401, json!({ "error": "JwtToken", "message": "Token is not valid yet" }))] {
        let answer = Arc::new(Mutex::new(Some(answer)));
        let fake = idp(move |_| answer.lock().unwrap().take().unwrap_or_else(granted)).await;
        let store = Memory::default();
        let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
        assert_eq!(session.access_token().await.unwrap(), "a1", "the old token, good until it runs out");
        assert!(session.signed_in());
        assert!(!store.last().unwrap().unwrap().refreshing, "the mark is cleared");
    }
}

#[tokio::test]
async fn a_discovery_that_fails_keeps_the_session() {
    // A captive portal's page where the discovery document should be.
    let fake = Fake::start(|r| match r.path() {
        "/auth/v1/.well-known/openid-configuration" => Response::status(200).body("<html>"),
        _ => granted(),
    })
    .await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
    assert_eq!(session.access_token().await.unwrap(), "a1");
    assert!(session.signed_in());
    assert!(fake.requests("/auth/v1/oidc/token").is_empty());
}

#[tokio::test]
async fn tokens_due_on_receipt_are_refused() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), None).await;
    let tokens = Tokens::received("b1".into(), Some("s1".into()), now_ms());
    assert_eq!(session.sign_in(tokens).await.unwrap_err().failure, Failure::InvalidResponse);
    assert!(!session.signed_in());
    assert_eq!(fake.requests("/auth/v1/oidc/token/revoke")[0].form("token").as_deref(), Some("s1"));
}

#[tokio::test]
async fn a_refresh_is_not_sent_when_its_mark_cannot_be_saved() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(10))).await;
    store.fail.store(true, Ordering::SeqCst);
    assert_eq!(session.access_token().await.unwrap_err().failure, Failure::Unreachable);
    assert!(fake.requests("/auth/v1/oidc/token").is_empty());
    assert!(session.signed_in());
}

#[tokio::test]
async fn callers_at_once_share_one_refresh() {
    let fake = idp(|_| granted()).await;
    let session = Arc::new(Session::restore(client(&fake), Memory::default(), Some(stored(10))).await);
    let calls = (0..5).map(|_| {
        let s = session.clone();
        tokio::spawn(async move { s.access_token().await.unwrap() })
    });
    for call in calls {
        assert_eq!(call.await.unwrap(), "a2");
    }
    assert_eq!(fake.requests("/auth/v1/oidc/token").len(), 1);
}

#[tokio::test]
async fn a_sign_in_saves_and_lets_the_session_it_replaces_go() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(3600))).await;
    let tokens = Tokens::received("b1".into(), Some("s1".into()), now_ms() + 300_000);
    session.sign_in(tokens).await.unwrap();
    assert_eq!(session.access_token().await.unwrap(), "b1");
    assert_eq!(store.last().unwrap().unwrap().access, "b1");
    let revoked = fake.requests("/auth/v1/oidc/token/revoke");
    assert_eq!(revoked.len(), 1);
    assert_eq!(revoked[0].form("token").as_deref(), Some("r1"));
}

#[tokio::test]
async fn signing_out_revokes_and_forgetting_does_not() {
    let fake = idp(|_| granted()).await;
    let store = Memory::default();
    let session = Session::restore(client(&fake), store.clone(), Some(stored(3600))).await;
    session.forget().await;
    assert!(!session.signed_in());
    assert!(fake.requests("/auth/v1/oidc/token/revoke").is_empty());

    let session = Session::restore(client(&fake), store.clone(), Some(stored(3600))).await;
    session.sign_out().await;
    assert_eq!(store.last(), Some(None));
    assert_eq!(fake.requests("/auth/v1/oidc/token/revoke").len(), 1);
}
