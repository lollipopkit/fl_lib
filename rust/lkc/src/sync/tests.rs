use std::sync::Arc;
use std::sync::Mutex as StdMutex;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
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
                format!("data: {}\n\n", json!({ "event": "log", "app": "gptbox", "seq": 9 })),
                format!("data: {}\n\n", json!({ "event": "log", "app": "serverbox", "seq": 4 })),
            ];
            Response::status(200).header("content-type", "text/event-stream").body(events.concat())
        }
        _ => written("mine"),
    })
    .await;
    let dir = tempdir::Dir::new();
    sync.upload(NAME, &file(&dir, "bak", b"x"), Condition::Absent).await.unwrap();

    let got: Vec<Event> = sync.clone().events().take(4).collect().await;
    assert_eq!(
        got,
        [
            Event::Connected,
            Event::Changed { name: NAME.into(), etag: Some("theirs".into()) },
            Event::Changed { name: NAME.into(), etag: None },
            Event::Log { seq: 4 },
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

const KEY: &str = "0000019a3f2b1c000000000000000007";

fn page(batches: &[(i64, &[u8])], head: i64, more: bool) -> Response {
    let batches: Vec<_> = batches
        .iter()
        .map(|(seq, body)| json!({ "seq": seq, "size": body.len(), "digest": blake3::hash(body).to_hex().as_str(), "body": BASE64.encode(body) }))
        .collect();
    Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "batches": batches, "head": head, "snapshot_seq": 0, "more": more } }))
}

#[tokio::test]
async fn a_batch_is_appended_once_under_its_key() {
    let (fake, sync) = homebase(|_| Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "seq": 3, "live": { "batches": 3, "bytes": 90 }, "compact": false } }))).await;
    let appended = sync.append(KEY, b"age batch".to_vec()).await.unwrap();
    assert_eq!(appended, Appended { log: "6f1c".into(), seq: 3, live: Live { batches: 3, bytes: 90 }, compact: false });
    let post = &fake.requests("/v2/sync/serverbox/log")[0];
    assert_eq!((post.method.as_str(), post.header("idempotency-key"), post.body.as_slice()), ("POST", Some(KEY), b"age batch".as_slice()));

    assert_eq!(sync.append("short", vec![]).await.unwrap_err().kind, Kind::Invalid);
    assert_eq!(sync.append(KEY, vec![0; BATCH_MAX + 1]).await.unwrap_err().kind, Kind::TooLarge);
}

#[tokio::test]
async fn log_refusals_carry_their_reason() {
    let (_fake, sync) = homebase(|r| match r.method.as_str() {
        "POST" => Response::json(409, json!({ "code": 4, "msg": "x", "reason": "sync_log_full", "data": "" })),
        _ => Response::json(422, json!({ "code": 4, "msg": "x", "reason": "sync_key_reused", "data": "" })),
    })
    .await;
    assert_eq!(sync.append(KEY, b"b".to_vec()).await.unwrap_err().kind, Kind::Refused("sync_log_full".into()));
    let dir = tempdir::Dir::new();
    let from = file(&dir, "snap", b"s");
    assert_eq!(sync.put_snapshot(1, &from).await.unwrap_err().kind, Kind::Refused("sync_key_reused".into()));
}

#[tokio::test]
async fn a_page_is_read_from_the_cursor_with_its_digests_checked() {
    let (fake, sync) = homebase(|r| match r.target.as_str() {
        "/v2/sync/serverbox/log?after=0" => page(&[(1, b"one"), (2, b"two")], 3, true),
        "/v2/sync/serverbox/log?after=2&log=6f1c&limit=1" => page(&[(3, b"three")], 3, false),
        _ => Response::json(410, json!({ "code": 4, "reason": "sync_compacted", "data": "" })).header("Sync-Snapshot-Seq", "40").header("Sync-Log", "7a2d"),
    })
    .await;
    let LogRead::Page { log, batches, head, more, .. } = sync.read_log(0, None, None).await.unwrap() else { panic!() };
    assert_eq!((log.as_deref(), head, more), (Some("6f1c"), 3, true));
    assert_eq!(batches, vec![Batch { seq: 1, body: b"one".to_vec() }, Batch { seq: 2, body: b"two".to_vec() }]);
    let LogRead::Page { batches, more, .. } = sync.read_log(2, Some("6f1c"), Some(1)).await.unwrap() else { panic!() };
    assert_eq!((batches.len(), more), (1, false));

    assert_eq!(sync.read_log(2, Some("0bad"), None).await.unwrap(), LogRead::Compacted { log: Some("7a2d".into()), snapshot_seq: 40 });
    assert_eq!(sync.read_log(0, Some("../x"), None).await.unwrap_err().kind, Kind::Invalid);
    assert_eq!(fake.requests("/v2/sync/serverbox/log").len(), 3);
}

#[tokio::test]
async fn a_batch_whose_digest_differs_is_refused() {
    let (_fake, sync) = homebase(|_| {
        let body = BASE64.encode(b"tampered");
        Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "batches": [{ "seq": 1, "size": 8, "digest": blake3::hash(b"original").to_hex().as_str(), "body": body }], "head": 1, "snapshot_seq": 0, "more": false } }))
    })
    .await;
    assert_eq!(sync.read_log(0, None, None).await.unwrap_err().kind, Kind::Invalid);
}

#[tokio::test]
async fn a_snapshot_is_written_at_its_seq_and_read_with_its_log() {
    let (fake, sync) = homebase(|r| match (r.method.as_str(), r.target.as_str()) {
        ("PUT", "/v2/sync/serverbox/snapshot?seq=7") => written("s7"),
        ("GET", "/v2/sync/serverbox/snapshot") => Response::status(200).header("ETag", "\"s7\"").header("Sync-Seq", "7").header("Sync-Log", "6f1c").body("snap"),
        _ => Response::status(404),
    })
    .await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "snap", b"snap");
    assert_eq!(sync.put_snapshot(7, &from).await.unwrap(), "s7");
    assert_eq!(fake.requests("/v2/sync/serverbox/snapshot")[0].body, b"snap");

    let to = dir.path().join("got");
    assert_eq!(sync.download_snapshot(&to).await.unwrap(), Some(Snapshot { log: "6f1c".into(), seq: 7 }));
    assert_eq!(std::fs::read(&to).unwrap(), b"snap");

    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    assert_eq!(sync.download_snapshot(&to).await.unwrap(), None);
}

#[tokio::test]
async fn a_large_snapshot_is_uploaded_and_a_stale_one_refused() {
    let (_fake, sync) = homebase(|r| {
        let base = format!("http://{}", r.header("host").unwrap());
        match (r.method.as_str(), r.path()) {
            ("POST", "/v2/sync/serverbox/snapshot/uploads") => {
                assert_eq!(r.target, "/v2/sync/serverbox/snapshot/uploads?seq=9");
                Response::json(200, json!({ "data": { "id": "u1", "url": format!("{base}/store/u1") } }))
            }
            ("PUT", "/store/u1") => Response::status(200),
            _ => Response::json(409, json!({ "code": 4, "reason": "sync_snapshot_stale", "data": "" })),
        }
    })
    .await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "snap", &vec![1u8; (DIRECT_MAX + 1) as usize]);
    assert_eq!(sync.put_snapshot(9, &from).await.unwrap_err().kind, Kind::Refused("sync_snapshot_stale".into()));
}

#[tokio::test]
async fn a_503_asking_for_a_short_wait_is_tried_once_more_when_it_may_be() {
    let tries = Arc::new(StdMutex::new(0));
    let seen = tries.clone();
    let (fake, sync) = homebase(move |r| {
        let mut n = seen.lock().unwrap();
        *n += 1;
        match (r.method.as_str(), *n) {
            ("GET", 1) => Response::status(503).header("Retry-After", "1"),
            ("GET", _) => page(&[], 0, false),
            _ => Response::status(503).header("Retry-After", "1"),
        }
    })
    .await;
    assert!(matches!(sync.read_log(0, None, None).await.unwrap(), LogRead::Page { .. }));
    // Appends carry their key, so they are tried again too, once.
    assert_eq!(sync.append(KEY, b"b".to_vec()).await.unwrap_err().kind, Kind::Unreachable);
    assert_eq!(fake.requests("/v2/sync/serverbox/log").len(), 4);

    // A POST without a key is not.
    let (fake, sync) = homebase(|_| Response::status(503).header("Retry-After", "1")).await;
    let dir = tempdir::Dir::new();
    let from = file(&dir, "big", &vec![1u8; (DIRECT_MAX + 1) as usize]);
    assert_eq!(sync.upload(NAME, &from, Condition::Absent).await.unwrap_err().kind, Kind::Unreachable);
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}/uploads")).len(), 1);

    // Nor a long wait.
    let (fake, sync) = homebase(|_| Response::status(503).header("Retry-After", "30")).await;
    assert_eq!(sync.list().await.unwrap_err().kind, Kind::Unreachable);
    assert_eq!(fake.requests("/v2/sync/serverbox").len(), 1);
}

#[tokio::test]
async fn a_full_page_of_large_batches_is_read() {
    // Homebase's page: under 1 MiB before the last batch, so five of 256 KiB.
    let big = vec![9u8; BATCH_MAX];
    let (_fake, sync) = homebase(move |_| page(&[(1, &big), (2, &big), (3, &big), (4, &big), (5, &big)], 5, false)).await;
    let LogRead::Page { batches, .. } = sync.read_log(0, None, None).await.unwrap() else { panic!() };
    assert_eq!(batches.len(), 5);
}
