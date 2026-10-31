use std::sync::Arc;
use std::sync::Mutex as StdMutex;

use futures_util::StreamExt;
use serde_json::json;

use super::*;
use crate::fake::{Fake, Request, Response};
use crate::session::{Session, Store, Stored};
use crate::{Client, now_ms};

#[derive(Clone, Default)]
struct Kept(Arc<StdMutex<Vec<Option<Stored>>>>);

impl Store for Kept {
    async fn save(&self, state: Option<Stored>) -> Result<(), String> {
        self.0.lock().unwrap().push(state);
        Ok(())
    }
}

/// Homebase, answering every request with [answer]; the session's token
/// is good for an hour, so the IdP is never asked.
async fn homebase(answer: impl Fn(&Request) -> Response + Send + Sync + 'static) -> (Fake, Arc<SyncClient<Kept>>) {
    let fake = Fake::start(answer).await;
    let client = Arc::new(Client::with(&fake.issuer(), "app", &fake.base).unwrap());
    let stored = Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(Session::restore(client, Kept::default(), Some(stored)).await);
    (fake, Arc::new(SyncClient::new(session, "serverbox")))
}

fn file(dir: &tempdir::Dir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

mod tempdir {
    pub struct Dir(std::path::PathBuf);
    impl Dir {
        pub fn new() -> Self {
            let p = std::env::temp_dir().join(format!("fl-lkc-sync-{}-{}", std::process::id(), rand()));
            std::fs::create_dir_all(&p).unwrap();
            Self(p)
        }
        pub fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn rand() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64
    }
}

const NAME: &str = "srvbox_bak_v4.age";

fn written(etag: &str) -> Response {
    Response::status(204).header("ETag", &format!("\"{etag}\""))
}

#[tokio::test]
async fn a_small_file_is_put_with_its_condition_and_answers_its_version() {
    let (fake, sync) = homebase(|r| match r.header("if-none-match") {
        Some("*") => written("e1"),
        _ => match r.header("if-match") {
            Some("\"e1\"") => written("e2"),
            _ => Response::status(412),
        },
    })
    .await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "bak", b"age-encryption.org/v1\n...");

    assert_eq!(sync.upload(NAME, &from, Condition::Absent).await.unwrap(), "e1");
    assert_eq!(sync.upload(NAME, &from, Condition::Match("e1".into())).await.unwrap(), "e2");
    assert_eq!(sync.upload(NAME, &from, Condition::Match("e0".into())).await.unwrap_err().kind, Kind::Changed);

    let put = &fake.requests(&format!("/v2/sync/serverbox/{NAME}"))[0];
    assert_eq!(put.method, "PUT");
    assert_eq!(put.header("authorization"), Some("Bearer tok"));
    assert_eq!(put.header("content-length"), Some("25"));
}

#[tokio::test]
async fn a_large_file_goes_to_the_store_without_the_token() {
    let completes = Arc::new(StdMutex::new(0));
    let seen = completes.clone();
    let (fake, sync) = homebase(move |r| {
        let base = format!("http://{}", r.header("host").unwrap());
        match (r.method.as_str(), r.path()) {
            ("POST", p) if p.ends_with("/uploads") => {
                assert_eq!(r.header("if-match"), Some("\"e1\""));
                Response::json(200, json!({ "data": { "id": "u1", "url": format!("{base}/store/u1"), "expires_at": "x", "etag": "e2" } }))
            }
            ("PUT", "/store/u1") => Response::status(200),
            ("POST", p) if p.ends_with("/uploads/u1/complete") => {
                let mut n = seen.lock().unwrap();
                *n += 1;
                // Not yet seen by homebase the first time.
                if *n == 1 { Response::status(409) } else { written("e2") }
            }
            _ => Response::status(500),
        }
    })
    .await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "bak", &vec![7u8; (DIRECT_MAX + 1) as usize]);

    assert_eq!(sync.upload(NAME, &from, Condition::Match("e1".into())).await.unwrap(), "e2");
    let stored = &fake.requests("/store/u1")[0];
    assert_eq!(stored.header("authorization"), None, "the store is not sent the token");
    assert_eq!(stored.body.len() as u64, DIRECT_MAX + 1);
    assert_eq!(*completes.lock().unwrap(), 2);
}

#[tokio::test]
async fn a_download_follows_the_store_by_hand_and_keeps_the_version() {
    let (fake, sync) = homebase(|r| {
        let base = format!("http://{}", r.header("host").unwrap());
        match r.path() {
            "/store/obj" => Response::status(200).body("large bytes"),
            "/v2/sync/serverbox/small.age" => match r.header("if-none-match") {
                Some("\"s1\"") => Response::status(304).header("ETag", "\"s1\""),
                _ => Response::status(200).header("ETag", "\"s1\"").body("small bytes"),
            },
            "/v2/sync/serverbox/large.age" => Response::status(302).header("ETag", "\"l1\"").header("Location", &format!("{base}/store/obj")),
            _ => Response::status(404),
        }
    })
    .await;
    let dir = tempdir::Dir::new();
    let to = dir.path().join("got");

    assert_eq!(sync.download("small.age", &to, None).await.unwrap(), Fetched::Saved("s1".into()));
    assert_eq!(std::fs::read(&to).unwrap(), b"small bytes");
    assert_eq!(sync.download("small.age", &to, Some("s1")).await.unwrap(), Fetched::Unchanged);
    assert_eq!(sync.download("none.age", &to, None).await.unwrap(), Fetched::Missing);

    assert_eq!(sync.download("large.age", &to, None).await.unwrap(), Fetched::Saved("l1".into()));
    assert_eq!(std::fs::read(&to).unwrap(), b"large bytes");
    assert_eq!(fake.requests("/store/obj")[0].header("authorization"), None);
}

#[tokio::test]
async fn a_plan_without_sync_is_refused_and_keeps_the_session() {
    // The rejection carries code 2 too: only the reason says what it is.
    let (_fake, sync) = homebase(|_| Response::json(403, json!({ "code": 2, "msg": "No perm", "reason": "sync_unavailable", "data": "" }))).await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "bak", b"x");
    let e = sync.upload(NAME, &from, Condition::Absent).await.unwrap_err();
    assert_eq!(e.kind, Kind::Refused("sync_unavailable".into()));
    assert!(sync.session().signed_in());
}

#[tokio::test]
async fn homebase_refusing_the_session_signs_out() {
    // Its way of saying so: a 200 with `{"code": 2}`.
    let (_fake, sync) = homebase(|_| Response::json(200, json!({ "code": 2, "msg": "No perm" }))).await;
    assert_eq!(sync.list().await.unwrap_err().kind, Kind::SignedOut);
    assert!(!sync.session().signed_in());

    let (_fake, sync) = homebase(|_| Response::json(200, json!({ "code": 2, "msg": "No perm" }))).await;
    let dir = tempdir::Dir::new();
    assert_eq!(sync.download(NAME, &dir.path().join("x"), None).await.unwrap_err().kind, Kind::SignedOut);
    assert!(!sync.session().signed_in());
}

#[tokio::test]
async fn an_answer_without_a_version_signs_out_only_on_homebase_s_word() {
    // Something in front of homebase answering a HEAD with a bare 200.
    let (_fake, sync) = homebase(|r| match r.path() {
        "/v2/sync/serverbox" => Response::status(200).body("<html>"),
        _ => Response::status(200),
    })
    .await;
    assert_eq!(sync.head(NAME).await.unwrap_err().kind, Kind::Unreachable);
    assert!(sync.session().signed_in());

    let (_fake, sync) = homebase(|r| match r.path() {
        "/v2/sync/serverbox" => Response::json(200, json!({ "code": 2, "msg": "No perm" })),
        _ => Response::status(200),
    })
    .await;
    assert_eq!(sync.head(NAME).await.unwrap_err().kind, Kind::SignedOut);
    assert!(!sync.session().signed_in());
}

#[tokio::test]
async fn files_and_versions_are_listed() {
    let (_fake, sync) = homebase(|r| match r.path() {
        "/v2/sync/serverbox" => Response::json(200, json!({ "data": [{ "name": NAME, "etag": "e1", "size": 9, "updated_at": "2026-11-01T00:00:00Z" }] })),
        p if p.ends_with("/versions") => Response::json(200, json!({ "data": [{ "etag": "e0", "size": 8, "written_at": "a", "replaced_at": "b" }] })),
        _ => Response::status(404),
    })
    .await;
    assert_eq!(sync.list().await.unwrap()[0].etag, "e1");
    assert_eq!(sync.versions(NAME).await.unwrap()[0].etag, "e0");
}

#[tokio::test]
async fn events_say_what_others_wrote_and_not_this_devices_own() {
    let (_fake, sync) = homebase(|r| match r.path() {
        "/sse/listen" => {
            let events = [
                ": ping\n\n".to_string(),
                format!("data: {}\n\n", json!({ "event": "sync", "app": "serverbox", "name": NAME, "etag": "mine" })),
                format!("data: {}\n\n", json!({ "event": "sync", "app": "gptbox", "name": NAME, "etag": "x" })),
                format!("data: {}\n\n", json!({ "event": "sync", "app": "serverbox", "name": NAME, "etag": "theirs" })),
                format!("data: {}\n\n", json!({ "event": "sync", "app": "serverbox", "name": NAME, "etag": null })),
            ];
            Response::status(200).header("content-type", "text/event-stream").body(events.concat())
        }
        _ => written("mine"),
    })
    .await;
    let dir = tempdir::Dir::new();
    sync.upload(NAME, &file(&dir, "bak", b"x"), Condition::Absent).await.unwrap();

    let got: Vec<Event> = sync.clone().events().take(3).collect().await;
    assert_eq!(
        got,
        [
            Event::Connected,
            Event::Changed { name: NAME.into(), etag: Some("theirs".into()) },
            Event::Changed { name: NAME.into(), etag: None },
        ]
    );
}

#[tokio::test]
async fn the_clock_is_read_from_homebases_answers() {
    let (_fake, sync) = homebase(|_| Response::status(404).header("X-Server-Time", &(now_ms() + 5_000).to_string())).await;
    assert_eq!(sync.offset_ms(), 0);
    sync.head(NAME).await.unwrap();
    assert!((sync.offset_ms() - 5_000).abs() < 500, "{}", sync.offset_ms());
}

#[test]
fn names_are_homebases() {
    assert!(valid("srvbox_bak_v4.age", 128, true));
    assert!(!valid(".hidden", 128, true));
    assert!(!valid("a/b", 128, true));
    assert!(!valid("Upper", 64, false));
}
