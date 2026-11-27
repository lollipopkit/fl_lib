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
    assert_eq!(batches, vec![Batch { seq: 1, body: b"one".to_vec(), epoch: None, idempotency_key: None, signed: None }, Batch { seq: 2, body: b"two".to_vec(), epoch: None, idempotency_key: None, signed: None }]);
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
    assert_eq!(sync.download_snapshot(&to).await.unwrap(), Some(Snapshot { log: "6f1c".into(), seq: 7, signed: None }));
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

struct TestKeeper {
    saved: StdMutex<String>,
    fail: std::sync::atomic::AtomicBool,
}

impl TestKeeper {
    fn new() -> Arc<Self> {
        Arc::new(Self { saved: StdMutex::new(String::new()), fail: std::sync::atomic::AtomicBool::new(false) })
    }
}

impl crate::personal::VersionKeeper for TestKeeper {
    fn save(&self, json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
        if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
            return Box::pin(async { Err("disk full".into()) });
        }
        *self.saved.lock().unwrap() = json;
        Box::pin(async { Ok(()) })
    }
}

#[tokio::test]
async fn committed_write_survives_keeper_failure_and_retries_without_resending() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let (fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => written("e-committed"),
        ("POST", "/v2/sync/serverbox/log") => Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } })),
        ("PUT", "/v2/sync/serverbox/snapshot") => written("s-committed"),
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // 1. File upload commits remotely, local persistence fails -> error retains ETag; retry does NOT resend PUT.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"file-body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::File { etag: "e-committed".into(), version: 1 }));
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}")).len(), 1);

    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.upload_bytes(NAME, b"file-body".to_vec(), Condition::Absent).await.unwrap(), "e-committed");
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}")).len(), 1);

    // 2. Log append commits remotely, local persistence fails -> error retains Appended; retry does NOT resend POST.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.append(KEY, b"b1".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert!(matches!(err.committed, Some(Committed::Batch(Appended { seq: 1, .. }))));
    assert_eq!(fake.requests("/v2/sync/serverbox/log").len(), 1);

    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.append(KEY, b"b1".to_vec()).await.unwrap().seq, 1);
    assert_eq!(fake.requests("/v2/sync/serverbox/log").len(), 1);

    // 3. Snapshot write commits remotely, local persistence fails -> error retains ETag; retry does NOT resend PUT.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(1, b"snap".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "s-committed".into(), seq: 1, log: None }));
    assert_eq!(fake.requests("/v2/sync/serverbox/snapshot").len(), 1);

    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.put_snapshot_bytes(1, b"snap".to_vec()).await.unwrap(), "s-committed");
    assert_eq!(fake.requests("/v2/sync/serverbox/snapshot").len(), 1);

    // 4. Detaching/replacing personal auth clears pending_commits so a new auth instance cannot skip writes.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"file-body-2".to_vec(), Condition::Match("e-committed".into())).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    sync.set_personal(None);
    assert!(sync.pending_commits.lock().unwrap().files.is_empty());
}

#[tokio::test]
async fn failed_download_cleans_up_staged_part_file() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let (_fake, sync) = homebase(|_| {
        // Return an invalid signature so verification fails after staging `.part`.
        Response::status(200)
            .header("ETag", "\"e1\"")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", "AAAA")
            .header("X-Signature", "AAAA")
            .header("X-Sync-Version", "1")
            .body("tampered-body")
    })
    .await;
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth));

    let dir = tempdir::Dir::new();
    let to = dir.path().join("bak.age");
    assert_eq!(sync.download(NAME, &to, None).await.unwrap_err().kind, Kind::Untrusted);
    let leftover: Vec<_> = std::fs::read_dir(dir.path()).unwrap().collect();
    assert!(leftover.is_empty(), "expected no leftover .part files");
}

#[tokio::test]
async fn concurrent_downloads_do_not_overwrite_newer_version_with_older() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let auth = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), TestKeeper::new()));
    let sig1 = auth.sign_file("serverbox", NAME, 1, b"v1-body").await;
    let sig2 = auth.sign_file("serverbox", NAME, 2, b"v2-body").await;
    let pk = key.signing_public();
    let req_n = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = req_n.clone();
    let (_fake, sync) = homebase(move |_| {
        let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let (etag, ver, sig, body) = if n == 0 {
            ("\"e1\"", "1", sig1.signature.as_str(), "v1-body")
        } else {
            ("\"e2\"", "2", sig2.signature.as_str(), "v2-body")
        };
        Response::status(200)
            .header("ETag", etag)
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pk)
            .header("X-Signature", sig)
            .header("X-Sync-Version", ver)
            .body(body)
    })
    .await;
    sync.set_personal(Some(auth));

    let v1_verified = Arc::new(tokio::sync::Notify::new());
    let release_v1 = Arc::new(tokio::sync::Notify::new());
    let hook_fired = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let v1_ver_c = v1_verified.clone();
        let rel_v1_c = release_v1.clone();
        let fired_c = hook_fired.clone();
        *sync.after_verify_before_rename.lock().unwrap() = Some(Arc::new(move || {
            let v1_ver = v1_ver_c.clone();
            let rel_v1 = rel_v1_c.clone();
            let first = !fired_c.swap(true, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async move {
                if first {
                    v1_ver.notify_one();
                    rel_v1.notified().await;
                }
            })
        }));
    }

    let dir = tempdir::Dir::new();
    let to = dir.path().join("bak.age");
    let sync1 = sync.clone();
    let to1 = to.clone();
    let t1 = tokio::spawn(async move { sync1.download(NAME, &to1, None).await });
    // Wait until version 1 has finished signature/version verification and is paused right before rename.
    v1_verified.notified().await;
    assert!(!to.exists(), "v1 must pause before rename");

    // Start version 2 targeting the same destination; it MUST remain blocked on `dest_lock` until v1 finishes.
    let sync2 = sync.clone();
    let to2 = to.clone();
    let mut t2 = tokio::spawn(async move { sync2.download(NAME, &to2, None).await });
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut t2).await.is_err(),
        "v2 download must remain blocked on destination lock while v1 holds it"
    );
    assert_eq!(req_n.load(std::sync::atomic::Ordering::SeqCst), 1, "v2 must not even fetch before acquiring dest_lock");

    release_v1.notify_one();
    assert_eq!(t1.await.unwrap().unwrap(), Fetched::Saved("e1".into()));
    assert_eq!(t2.await.unwrap().unwrap(), Fetched::Saved("e2".into()));
    assert_eq!(std::fs::read(&to).unwrap(), b"v2-body");
}

#[tokio::test]
async fn stale_auth_cannot_insert_or_reuse_pending_commit_after_set_personal() {
    let key1 = crate::team::identity::AccountKey::generate("u1");
    let pub1 = key1.signing_public();
    let rec1 = key1.recipient();
    let key2 = crate::team::identity::AccountKey::generate("u2");
    let pub2 = key2.signing_public();
    let rec2 = key2.recipient();
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = calls.clone();
    let (fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => {
            if seen.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                Response::json(200, json!({ "data": { "recipient": rec1, "signing_key": pub1, "next_seq": 2, "prev_signing_key": pub1 } }))
            } else {
                Response::json(200, json!({ "data": { "recipient": rec2, "signing_key": pub2, "next_seq": 2, "prev_signing_key": pub2 } }))
            }
        }
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            written(if n == 0 { "e-auth1" } else { "e-auth2" })
        }
        _ => Response::status(404),
    })
    .await;

    // Switching auth while a keeper failure occurs on auth1 must not let auth1
    // pollute auth2's pending_commits or let auth2 skip its remote PUT.
    struct SwitchingKeeper {
        sync: Arc<SyncClient<Kept>>,
        next_auth: StdMutex<Option<Arc<PersonalAuth>>>,
    }
    impl crate::personal::VersionKeeper for SwitchingKeeper {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            if let Some(next) = self.next_auth.lock().unwrap().take() {
                self.sync.set_personal(Some(next));
            }
            Box::pin(async { Err("stale auth save failed".into()) })
        }
    }

    let keeper2 = TestKeeper::new();
    let auth2 = Arc::new(PersonalAuth::new(key2, crate::personal::PersonalVersions::default(), keeper2));
    let keeper1 = Arc::new(SwitchingKeeper { sync: sync.clone(), next_auth: StdMutex::new(Some(auth2)) });
    let auth1 = Arc::new(PersonalAuth::new(key1, crate::personal::PersonalVersions::default(), keeper1));
    sync.set_personal(Some(auth1));

    // Upload under auth1 commits remotely; during save(), set_personal switches to auth2 and save fails.
    let err = sync.upload_bytes(NAME, b"same-body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert!(sync.pending_commits.lock().unwrap().files.is_empty(), "stale auth1 must not insert into auth2's pending_commits");

    // Subsequent upload of the exact same bytes under auth2 MUST actually send PUT to the server.
    assert_eq!(sync.upload_bytes(NAME, b"same-body".to_vec(), Condition::Absent).await.unwrap(), "e-auth2");
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}")).len(), 2);
}

#[tokio::test]
async fn idle_read_log_flushes_dirty_watermark_after_append_persist_failure() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let (fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("POST", "/v2/sync/serverbox/log") => Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } })),
        ("GET", "/v2/sync/serverbox/log") => Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "batches": [], "head": 1, "snapshot_seq": 0, "more": false } })),
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // Append commits seq 1 remotely, but local keeper fails -> watermark stays dirty in memory.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.append(KEY, b"b1".to_vec()).await.unwrap_err();
    assert!(matches!(err.committed, Some(Committed::Batch(Appended { seq: 1, .. }))));
    assert!(keeper.saved.lock().unwrap().is_empty());

    // Keeper recovers. Subsequent idle sync only calls read_log(after=1) which
    // returns an empty page; it MUST flush the dirty watermark to keeper without resending POST.
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    let page = sync.read_log(1, Some("6f1c"), None).await.unwrap();
    assert!(matches!(page, LogRead::Page { ref batches, .. } if batches.is_empty()));
    let saved = keeper.saved.lock().unwrap().clone();
    assert!(!saved.is_empty(), "empty read_log must flush dirty PersonalVersions");
    assert!(saved.contains(r#""signed_log_from":{"serverbox":1}"#), "saved versions must mark the log signed: {saved}");
    assert_eq!(fake.requests("/v2/sync/serverbox/log").iter().filter(|r| r.method == "POST").count(), 1);
}

#[tokio::test]
async fn delete_invalidates_cached_pending_file_commit() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let deletes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let del_seen = deletes.clone();
    let (fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            match n {
                0 => written("e-first"),
                1 => written("e-second"),
                2 => written("e-third"),
                _ if r.header("if-match").is_some() => Response::status(412),
                _ => written("e-fourth"),
            }
        }
        ("DELETE", p) if p.ends_with(NAME) => {
            let d = del_seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Response::status(if d == 0 { 204 } else { 404 })
        }
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // 1. Upload commits remotely, local persistence fails -> cached pending commit.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"same-body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e-first".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. Retrying with no intervening delete still fails local flush WITHOUT resending PUT
    //    and preserves `err.committed`.
    let err = sync.upload_bytes(NAME, b"same-body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::File { etag: "e-first".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 3. Intervening delete succeeds (204) -> invalidates the cached pending file result,
    //    so once keeper recovers a subsequent create MUST issue a fresh PUT.
    assert!(sync.delete(NAME, Some("e-first")).await.unwrap());
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.upload_bytes(NAME, b"same-body".to_vec(), Condition::Absent).await.unwrap(), "e-second");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 4. Another upload commits remotely then fails local save -> cached pending commit ("e-third").
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"body-2".to_vec(), Condition::Match("e-second".into())).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e-third".into(), version: 3 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 3);

    // 5. Intervening delete answering 404 (already deleted remotely) MUST ALSO invalidate
    //    the cached pending file result so a subsequent conditional write sends PUT #4
    //    and observes 412 Kind::Changed rather than returning cached "e-third".
    assert!(!sync.delete(NAME, None).await.unwrap());
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(
        sync.upload_bytes(NAME, b"body-2".to_vec(), Condition::Match("e-second".into())).await.unwrap_err().kind,
        Kind::Changed,
    );
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 4);
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}")).iter().filter(|r| r.method == "PUT").count(), 4);
}

#[tokio::test]
async fn upload_signed_replacement_invalidates_cached_pending_commit_only_on_success() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            match n {
                0 => written("e1"),
                1 => Response::status(412),
                2 => written("e2-signed"),
                _ => Response::status(412),
            }
        }
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // 1. upload_bytes commits remotely ("e1"), local persistence fails -> caches recovery entry.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e1".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. Failed upload_signed (412) MUST retain the cached recovery entry.
    assert_eq!(sync.upload_signed(NAME, b"other".to_vec(), Condition::Match("wrong".into()), None).await.unwrap_err().kind, Kind::Changed);
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);
    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e1".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 3. Successful upload_signed replacement invalidates the cached entry so a later
    //    upload_bytes sends a fresh PUT and hits 412 Kind::Changed rather than returning stale "e1".
    assert_eq!(sync.upload_signed(NAME, b"replaced".to_vec(), Condition::Match("e1".into()), None).await.unwrap(), "e2-signed");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 3);
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err().kind, Kind::Changed);
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 4);
}

#[tokio::test]
async fn concurrent_delete_during_record_file_version_prevents_stale_pending_insert() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            written(if n == 0 { "e1" } else { "e2" })
        }
        ("DELETE", p) if p.ends_with(NAME) => Response::status(204),
        _ => Response::status(404),
    })
    .await;

    // Keeper that runs a DELETE of NAME after PUT #1 committed and before
    // returning a persistence error, simulating an overlapping DELETE.
    struct DeletingKeeper {
        sync: Arc<SyncClient<Kept>>,
        fail: std::sync::atomic::AtomicBool,
    }
    impl crate::personal::VersionKeeper for DeletingKeeper {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                if self.fail.swap(false, std::sync::atomic::Ordering::SeqCst) {
                    assert!(self.sync.delete(NAME, Some("e1")).await.unwrap());
                    return Err("save failed after delete".into());
                }
                Ok(())
            })
        }
    }

    let keeper = Arc::new(DeletingKeeper { sync: sync.clone(), fail: std::sync::atomic::AtomicBool::new(true) });
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper));
    sync.set_personal(Some(auth));

    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert!(sync.pending_commits.lock().unwrap().files.is_empty(), "delete after PUT must block stale recovery insert");

    // Next create MUST send PUT #2 rather than returning deleted "e1".
    assert_eq!(sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap(), "e2");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[tokio::test]
async fn stale_upload_does_not_insert_written_marker_after_set_personal() {
    let key1 = crate::team::identity::AccountKey::generate("u1");
    let pub1 = key1.signing_public();
    let rec1 = key1.recipient();
    let key2 = crate::team::identity::AccountKey::generate("u2");
    let pub2 = key2.signing_public();
    let rec2 = key2.recipient();
    let auth2 = Arc::new(PersonalAuth::new(key2, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    let sync_slot: Arc<std::sync::OnceLock<Arc<SyncClient<Kept>>>> = Arc::new(std::sync::OnceLock::new());
    let next_auth = Arc::new(StdMutex::new(Some(auth2)));
    let put_n = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let slot_c = sync_slot.clone();
    let next_c = next_auth.clone();
    let put_c = put_n.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => {
            if put_c.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                Response::json(200, json!({ "data": { "recipient": rec1, "signing_key": pub1, "next_seq": 2, "prev_signing_key": pub1 } }))
            } else {
                Response::json(200, json!({ "data": { "recipient": rec2, "signing_key": pub2, "next_seq": 2, "prev_signing_key": pub2 } }))
            }
        }
        ("PUT", p) if p.ends_with(NAME) => {
            let n = put_c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if n == 0 {
                // Switch auth while PUT #1 is in flight before upload_signed_bytes records `written`.
                if let (Some(s), Some(a2)) = (slot_c.get(), next_c.lock().unwrap().take()) {
                    s.set_personal(Some(a2));
                }
                written("e-stale")
            } else {
                written("e-fresh")
            }
        }
        _ => Response::status(404),
    })
    .await;

    let _ = sync_slot.set(sync.clone());
    let auth1 = Arc::new(PersonalAuth::new(key1, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth1));

    assert_eq!(sync.upload_bytes(NAME, b"v1".to_vec(), Condition::Absent).await.unwrap(), "e-stale");

    // Stale PUT #1 MUST NOT pollute auth2's `written` map, so SSE event for "e-stale" is NOT suppressed.
    let stale_ev = json!({ "event": "sync", "app": "serverbox", "name": NAME, "etag": "e-stale" });
    assert_eq!(sync.heard(&stale_ev), Some(Event::Changed { name: NAME.into(), etag: Some("e-stale".into()) }));

    // Same-generation upload under auth2 DOES record `written`, so `heard` suppresses its own SSE event.
    assert_eq!(sync.upload_bytes(NAME, b"v2".to_vec(), Condition::Absent).await.unwrap(), "e-fresh");
    let fresh_ev = json!({ "event": "sync", "app": "serverbox", "name": NAME, "etag": "e-fresh" });
    assert_eq!(sync.heard(&fresh_ev), None);
}

#[tokio::test]
async fn file_mutations_stays_bounded_across_deletes_404s_and_non_personal_clients() {
    let (_fake, sync) = homebase(|r| match (r.method.as_str(), r.path()) {
        ("PUT", _) => written("e1"),
        ("DELETE", p) if p.ends_with("present.age") => Response::status(204),
        ("DELETE", _) => Response::status(404),
        _ => Response::status(404),
    })
    .await;

    // Without personal auth: uploads, deletes, and 404s must not leave entries in file_mutations.
    assert_eq!(sync.upload_bytes("present.age", b"a".to_vec(), Condition::Absent).await.unwrap(), "e1");
    assert!(sync.delete("present.age", None).await.unwrap());
    assert!(!sync.delete("never-existed.age", None).await.unwrap());
    assert!(sync.pending_commits.lock().unwrap().file_mutations.is_empty());

    // With personal auth: completed upload clears its tracking entry, and untracked deletes/404s do not insert.
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let (_fake2, sync2) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", _) => written("e1"),
        ("DELETE", _) => Response::status(404),
        _ => Response::status(404),
    })
    .await;
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync2.set_personal(Some(auth));

    assert_eq!(sync2.upload_bytes("tracked.age", b"body".to_vec(), Condition::Absent).await.unwrap(), "e1");
    assert!(sync2.pending_commits.lock().unwrap().file_mutations.is_empty());
    assert!(!sync2.delete("untracked.age", None).await.unwrap());
    assert!(sync2.pending_commits.lock().unwrap().file_mutations.is_empty());
}

#[tokio::test]
async fn download_404_leaves_existing_destination_and_unrelated_part_file_untouched() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth));

    let dir = tempdir::Dir::new();
    let dest = file(&dir, "bak.age", b"existing-dest");
    let unrelated_part = file(&dir, "bak.age.part", b"unrelated-staged");

    assert_eq!(sync.download("bak.age", &dest, None).await.unwrap(), Fetched::Missing);
    assert_eq!(std::fs::read(&dest).unwrap(), b"existing-dest");
    assert_eq!(std::fs::read(&unrelated_part).unwrap(), b"unrelated-staged");

    assert!(sync.download_snapshot(&dest).await.unwrap().is_none());
    assert_eq!(std::fs::read(&dest).unwrap(), b"existing-dest");
    assert_eq!(std::fs::read(&unrelated_part).unwrap(), b"unrelated-staged");
}

#[tokio::test]
async fn concurrent_delete_after_put_does_not_leave_put_etag_cached() {
    let put_arrived = Arc::new(tokio::sync::Notify::new());
    let delete_arrived = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (release_tx, release_rx) = tokio::sync::oneshot::channel();
    let release_slot = Arc::new(StdMutex::new(Some(release_rx)));

    let arrived_c = put_arrived.clone();
    let del_c = delete_arrived.clone();
    let rx_c = release_slot.clone();
    let (_fake, sync) = homebase(move |r| match r.method.as_str() {
        "PUT" => {
            arrived_c.notify_one();
            let mut resp = written("e-put");
            if let Some(rx) = rx_c.lock().unwrap().take() {
                resp = resp.hold(rx);
            }
            resp
        }
        "DELETE" => {
            del_c.store(true, std::sync::atomic::Ordering::SeqCst);
            Response::status(204)
        }
        _ => Response::status(404),
    })
    .await;

    let s1 = sync.clone();
    let s2 = sync.clone();
    let put = tokio::spawn(async move { s1.upload_signed(NAME, b"x".to_vec(), Condition::Absent, None).await.unwrap() });
    put_arrived.notified().await;

    let del = tokio::spawn(async move { s2.delete(NAME, None).await.unwrap() });
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    assert!(!delete_arrived.load(std::sync::atomic::Ordering::SeqCst), "DELETE must wait until PUT response and ETag commit complete");

    release_tx.send(()).unwrap();
    assert_eq!(put.await.unwrap(), "e-put");
    assert!(del.await.unwrap());
    assert!(delete_arrived.load(std::sync::atomic::Ordering::SeqCst));
    assert!(sync.written.lock().unwrap().get(NAME).is_none(), "DELETE completing after PUT must leave no PUT ETag marker");
}

#[tokio::test]
async fn upload_recovery_key_separates_blob_and_file_modes_and_invalidates_both_on_change() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", _) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            match n {
                0 => written("e-blob"),
                1 => Response::status(412),
                _ => written("e-new"),
            }
        }
        ("DELETE", _) => Response::status(204),
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // 1. Blob upload commits remotely, local save fails -> caches Blob recovery entry.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_blob_bytes("op-notes.age", b"same".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e-blob".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. Retrying in the SAME mode (blob) flushes without resending PUT.
    let err = sync.upload_blob_bytes("op-notes.age", b"same".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e-blob".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 3. Mutable file upload with identical (name, Condition::Absent, body) MUST NOT reuse
    //    the blob recovery entry; it issues PUT #2 (hitting 412).
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.upload_bytes("op-notes.age", b"same".to_vec(), Condition::Absent).await.unwrap_err().kind, Kind::Changed);
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 4. Deleting the file invalidates recovery entries across both modes so a
    //    subsequent blob upload issues PUT #3.
    assert!(sync.delete("op-notes.age", None).await.unwrap());
    assert_eq!(sync.upload_blob_bytes("op-notes.age", b"same".to_vec()).await.unwrap(), "e-new");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 3);
}

#[tokio::test]
async fn cached_commit_invalidated_during_flush_falls_through_and_drops_stale_committed_error() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            match n {
                0 => written("e1"),
                1 => written("e2"),
                _ => written("e3"),
            }
        }
        ("DELETE", p) if p.ends_with(NAME) => Response::status(204),
        _ => Response::status(404),
    })
    .await;

    // Modes for keeper.save:
    // 0 -> fail save (caches e1)
    // 1 -> delete NAME while flushing, then succeed (must fall through and send PUT #2 -> e2)
    // 2 -> fail save again (caches e2)
    // 3 -> delete NAME while flushing, then fail save (must return Kind::Invalid WITHOUT Committed::File)
    struct ScriptedKeeper {
        sync: Arc<SyncClient<Kept>>,
        step: std::sync::atomic::AtomicUsize,
    }
    impl crate::personal::VersionKeeper for ScriptedKeeper {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                match self.step.fetch_add(1, std::sync::atomic::Ordering::SeqCst) {
                    0 => Err("initial save failed".into()),
                    1 => {
                        assert!(self.sync.delete(NAME, Some("e1")).await.unwrap());
                        Ok(())
                    }
                    2 => Err("second upload save failed".into()),
                    3 => {
                        assert!(self.sync.delete(NAME, Some("e2")).await.unwrap());
                        Err("flush failed after delete".into())
                    }
                    _ => Ok(()),
                }
            })
        }
    }

    let keeper = Arc::new(ScriptedKeeper { sync: sync.clone(), step: std::sync::atomic::AtomicUsize::new(0) });
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper));
    sync.set_personal(Some(auth));

    // 1. PUT #1 commits "e1", local save fails (step 0) -> caches ("e1", 1).
    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::File { etag: "e1".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. Retry enters cached-commit branch, flushes versions (step 1 deletes NAME and
    //    succeeds). Recheck under file_lock -> personal -> pending_commits sees the
    //    cached entry is gone and continues to PUT #2 ("e2"). Step 2 fails save on PUT #2
    //    so ("e2", 2) is now cached.
    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::File { etag: "e2".into(), version: 2 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 3. Retry enters cached-commit branch for ("e2", 2); step 3 deletes NAME during
    //    flush and fails with Kind::Invalid. Because the cached entry was invalidated,
    //    the Kind::Invalid error MUST NOT attach stale Committed::File("e2").
    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, None, "stale Committed::File must not be attached after invalidation");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 4. Subsequent upload succeeds via PUT #3 ("e3").
    assert_eq!(sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap(), "e3");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 3);
}

#[tokio::test]
async fn cached_upload_entry_replaced_during_flush_must_not_return_on_earlier_flush() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = puts.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", p) if p.ends_with(NAME) => {
            seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            written("e1")
        }
        _ => Response::status(404),
    })
    .await;

    // save step 0: fail PUT #1 watermark -> caches id1 ("e1", v1).
    // save step 1: succeed for retry's first flush (v1), notifying the test while
    //              `file_lock` is held so the test can inject a newer dirty id2 ("e2", v2).
    // save step 2: fail for injected v2 -> leaves `dirty = true`.
    // save step 3: fail for retry's re-flush of id2 -> proves retry re-flushed instead of
    //              returning Ok("e2") on step 1's earlier flush!
    // save step 4: succeed -> next retry returns Ok("e2") with no extra PUT.
    struct StepKeeper {
        step: std::sync::atomic::AtomicUsize,
        first_flushed: Arc<tokio::sync::Notify>,
    }
    impl crate::personal::VersionKeeper for StepKeeper {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                match self.step.fetch_add(1, std::sync::atomic::Ordering::SeqCst) {
                    0 => Err("save 0 failed".into()),
                    1 => {
                        self.first_flushed.notify_one();
                        Ok(())
                    }
                    2 => Err("save 2 failed (v2 dirty)".into()),
                    3 => Err("save 3 failed (re-flush for id2)".into()),
                    _ => Ok(()),
                }
            })
        }
    }

    let first_flushed = Arc::new(tokio::sync::Notify::new());
    let keeper = Arc::new(StepKeeper { step: std::sync::atomic::AtomicUsize::new(0), first_flushed: first_flushed.clone() });
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper));
    sync.set_personal(Some(auth.clone()));

    let err = sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::File { etag: "e1".into(), version: 1 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // Hold file_lock(NAME) so the retry flushes v1 (step 1) and then waits on file_lock.
    let lock = sync.file_lock(NAME);
    let hold = lock.lock().await;
    let s = sync.clone();
    let retry = tokio::spawn(async move { s.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await });

    first_flushed.notified().await;
    // Before releasing file_lock, advance personal watermark to v2 (dirty, step 2 fails)
    // and replace the cached entry under commit_key with a new entry id2 ("e2", 2).
    assert!(auth.record_file_version("serverbox", NAME, 2).await.is_err());
    {
        let commit_key = (NAME.to_string(), Condition::Absent, *blake3::hash(b"body").as_bytes(), UploadMode::File);
        let mut guard = sync.pending_commits.lock().unwrap();
        let next_id = guard.next_id();
        guard.files.insert(commit_key, (next_id, "e2".into(), 2));
    }
    drop(hold);

    // Retry MUST notice entry id changed, refuse to return Ok("e2") based on step 1's flush,
    // and re-flush (hitting step 3 error with the new Committed::File("e2", 2)).
    let err = retry.await.unwrap().unwrap_err();
    assert_eq!(err.kind, Kind::Invalid);
    assert_eq!(err.committed, Some(Committed::File { etag: "e2".into(), version: 2 }));
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // Next retry flushes v2 successfully (step 4) and returns "e2" without resending PUT.
    assert_eq!(sync.upload_bytes(NAME, b"body".to_vec(), Condition::Absent).await.unwrap(), "e2");
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cached_append_and_snapshot_invalidated_when_personal_log_changes() {
    struct LogState {
        log: Option<String>,
        head: i64,
        snapshot_seq: i64,
    }
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let state = Arc::new(StdMutex::new(LogState {
        log: Some("log-1".to_string()),
        head: 0,
        snapshot_seq: 0,
    }));
    let append_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let snap_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let st_c = state.clone();
    let app_c = append_calls.clone();
    let snp_c = snap_calls.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("POST", p) if p.ends_with("/log") => {
            app_c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let mut st = st_c.lock().unwrap();
            let cur_log = st.log.get_or_insert_with(|| "log-fresh".into()).clone();
            st.head += 1;
            let seq = st.head;
            Response::json(200, json!({ "data": { "log": cur_log, "seq": seq, "live": { "batches": 1, "bytes": 4 }, "compact": false } }))
        }
        ("GET", p) if p.ends_with("/log") => {
            let st = st_c.lock().unwrap();
            Response::json(
                200,
                json!({ "data": { "log": st.log, "batches": [], "head": st.head, "snapshot_seq": st.snapshot_seq, "more": false } }),
            )
        }
        ("PUT", p) if p.ends_with("/snapshot") => {
            let n = snp_c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let seq = r
                .target
                .split_once("seq=")
                .and_then(|(_, v)| v.split('&').next()?.parse::<i64>().ok())
                .unwrap_or(0);
            let mut st = st_c.lock().unwrap();
            if st.log.is_none() || seq <= st.snapshot_seq || seq > st.head {
                return Response::json(409, json!({ "code": 4, "reason": "sync_snapshot_stale", "data": "" }));
            }
            st.snapshot_seq = seq;
            written(if n == 0 { "snap-log2" } else { "snap-other" })
        }
        _ => Response::status(404),
    })
    .await;

    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth));

    // 1. Append on log-1 fails local persistence -> cached for log-1 at seq 1 (head = 1).
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let idem = "idempotency-key-1234";
    let err = sync.append(idem, b"batch".to_vec()).await.unwrap_err();
    assert!(matches!(err.committed, Some(Committed::Batch(ref a)) if a.log == "log-1" && a.seq == 1));
    assert_eq!(append_calls.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. Server replaces log with log-2 (head = 0); client observes log-2 via read_log.
    *state.lock().unwrap() = LogState { log: Some("log-2".into()), head: 0, snapshot_seq: 0 };
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    let _ = sync.read_log(0, None, None).await.unwrap();

    // 3. Retrying append MUST NOT reuse log-1 cached result; sends a fresh append to log-2 (head = 1).
    let appended = sync.append(idem, b"batch".to_vec()).await.unwrap();
    assert_eq!(appended.log, "log-2");
    assert_eq!(appended.seq, 1);
    assert_eq!(append_calls.load(std::sync::atomic::Ordering::SeqCst), 2);

    // 4. Snapshot at seq 1 (<= head 1) on log-2 fails local persistence -> cached for log-2.
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(1, b"snap".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "snap-log2".into(), seq: 1, log: None }));
    assert_eq!(snap_calls.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 5. Server resets log to empty (`log: None`, `head: 0`); read_log clears stale cached entries.
    *state.lock().unwrap() = LogState { log: None, head: 0, snapshot_seq: 0 };
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    let _ = sync.read_log(0, None, None).await.unwrap();

    // 6. Retrying put_snapshot_bytes MUST NOT reuse log-2 cached result; it sends PUT #2,
    //    which the server rejects because seq 1 exceeds empty head 0.
    let snap_err = sync.put_snapshot_bytes(1, b"snap".to_vec()).await.unwrap_err();
    assert_eq!(snap_err.kind, Kind::Refused("sync_snapshot_stale".into()));
    assert_eq!(snap_calls.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[tokio::test]
async fn detaching_personal_auth_during_recovery_flush_never_sends_unsigned_write() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let unsigned_writes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let appends = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let snaps = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let file_etag: Arc<StdMutex<Option<String>>> = Arc::new(StdMutex::new(None));
    let uw = unsigned_writes.clone();
    let pc = puts.clone();
    let ac = appends.clone();
    let sc = snaps.clone();
    let fe = file_etag.clone();

    let (_fake, sync) = homebase(move |r| {
        if matches!(r.method.as_str(), "PUT" | "POST") && r.header("x-signature").is_none() {
            uw.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        match (r.method.as_str(), r.path()) {
            ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
            ("PUT", p) if p.ends_with(NAME) => {
                pc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let mut cur = fe.lock().unwrap();
                let ok = if r.header("if-none-match") == Some("*") {
                    cur.is_none()
                } else if let Some(im) = r.header("if-match") {
                    cur.as_ref().is_some_and(|e| format!("\"{e}\"") == im)
                } else {
                    false
                };
                if !ok {
                    return Response::status(412);
                }
                let next = if cur.is_none() { "e1" } else { "e2" };
                *cur = Some(next.to_string());
                written(next)
            }
            ("POST", p) if p.ends_with("/log") => {
                ac.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Response::json(200, json!({ "data": { "log": "log-1", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } }))
            }
            ("PUT", p) if p.ends_with("/snapshot") => {
                sc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                written("snap-1")
            }
            _ => Response::status(404),
        }
    })
    .await;

    struct DetachOnSecondSave {
        sync: Arc<SyncClient<Kept>>,
        mode: std::sync::atomic::AtomicUsize, // 0 = fail, 1 = detach & ok
    }
    impl crate::personal::VersionKeeper for DetachOnSecondSave {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                if self.mode.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                    Err("save failed".into())
                } else {
                    self.sync.set_personal(None);
                    Ok(())
                }
            })
        }
    }

    let keeper = Arc::new(DetachOnSecondSave { sync: sync.clone(), mode: std::sync::atomic::AtomicUsize::new(0) });
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper.clone()));

    // 1. upload_bytes: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    sync.set_personal(Some(auth.clone()));
    assert!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.is_err());
    keeper.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. append: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    keeper.mode.store(0, std::sync::atomic::Ordering::SeqCst);
    sync.set_personal(Some(auth.clone()));
    let idem = "idempotency-key-5678";
    assert!(sync.append(idem, b"b".to_vec()).await.is_err());
    keeper.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    let err = sync.append(idem, b"b".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(appends.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 3. put_snapshot_bytes: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    keeper.mode.store(0, std::sync::atomic::Ordering::SeqCst);
    sync.set_personal(Some(auth.clone()));
    assert!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.is_err());
    keeper.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(1, b"s".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(snaps.load(std::sync::atomic::Ordering::SeqCst), 1);

    assert_eq!(unsigned_writes.load(std::sync::atomic::Ordering::SeqCst), 0, "no unsigned write may be dispatched after personal auth detaches");

    // 4. Calls that BEGIN without personal auth preserve the existing unsigned path
    //    against the committed `e1` version of NAME.
    assert_eq!(sync.upload_bytes(NAME, b"u".to_vec(), Condition::Match("e1".into())).await.unwrap(), "e2");
    assert_eq!(unsigned_writes.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn switching_personal_auth_during_recovery_flush_rejects_in_flight_write() {
    let key1 = crate::team::identity::AccountKey::generate("u1");
    let pub1 = key1.signing_public();
    let rec1 = key1.recipient();
    let key2 = crate::team::identity::AccountKey::generate("u2");
    let auth2 = Arc::new(PersonalAuth::new(key2, crate::personal::PersonalVersions::default(), TestKeeper::new()));

    let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let appends = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let snaps = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let pc = puts.clone();
    let ac = appends.clone();
    let sc = snaps.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": rec1, "signing_key": pub1, "next_seq": 2, "prev_signing_key": pub1 } })),
        ("PUT", p) if p.ends_with(NAME) => {
            pc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            written("e1")
        }
        ("POST", p) if p.ends_with("/log") => {
            ac.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Response::json(200, json!({ "data": { "log": "log-1", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } }))
        }
        ("PUT", p) if p.ends_with("/snapshot") => {
            sc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            written("snap-1")
        }
        _ => Response::status(404),
    })
    .await;

    struct SwitchOnSecondSave {
        sync: Arc<SyncClient<Kept>>,
        replacement: Arc<PersonalAuth>,
        mode: std::sync::atomic::AtomicUsize,
    }
    impl crate::personal::VersionKeeper for SwitchOnSecondSave {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                if self.mode.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                    Err("save failed".into())
                } else {
                    self.sync.set_personal(Some(self.replacement.clone()));
                    Ok(())
                }
            })
        }
    }

    let keeper1 = Arc::new(SwitchOnSecondSave {
        sync: sync.clone(),
        replacement: auth2,
        mode: std::sync::atomic::AtomicUsize::new(0),
    });
    let auth1 = Arc::new(PersonalAuth::new(key1, crate::personal::PersonalVersions::default(), keeper1.clone()));

    // 1. upload_bytes MUST NOT adopt auth2 for u1's in-flight write.
    sync.set_personal(Some(auth1.clone()));
    assert!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.is_err());
    keeper1.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. append MUST NOT adopt auth2 for u1's in-flight write.
    keeper1.mode.store(0, std::sync::atomic::Ordering::SeqCst);
    sync.set_personal(Some(auth1.clone()));
    let idem = "idempotency-key-9012";
    assert!(sync.append(idem, b"b".to_vec()).await.is_err());
    keeper1.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.append(idem, b"b".to_vec()).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(appends.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 3. put_snapshot_bytes MUST NOT adopt auth2 for u1's in-flight write.
    keeper1.mode.store(0, std::sync::atomic::Ordering::SeqCst);
    sync.set_personal(Some(auth1));
    assert!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.is_err());
    keeper1.mode.store(1, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(snaps.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn fresh_auth_snapshot_recovery_reconciles_unknown_log_without_dropping_or_blind_matching() {
    type RemoteSnapshot = (String, String, i64, Vec<u8>, Option<String>);
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let remote_snap: Arc<StdMutex<Option<RemoteSnapshot>>> = Arc::new(StdMutex::new(None));
    let put_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let rs = remote_snap.clone();
    let pc = put_calls.clone();
    let pk_srv = pub_key.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("GET", p) if p.ends_with("/log") => {
            Response::json(200, json!({ "data": { "log": "log-1", "batches": [], "head": 5, "snapshot_seq": 5, "more": false } }))
        }
        ("PUT", p) if p.ends_with("/snapshot") => {
            let n = pc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let seq = r
                .target
                .split_once("seq=")
                .and_then(|(_, v)| v.split('&').next()?.parse::<i64>().ok())
                .unwrap_or(0);
            let mut cur = rs.lock().unwrap();
            if cur.as_ref().is_some_and(|(_, l, s, _, _)| l == "log-1" && seq <= *s) {
                return Response::json(409, json!({ "code": 4, "reason": "sync_snapshot_stale", "data": "" }));
            }
            let etag = format!("snap-{}", n + 1);
            let sig = r.header("x-signature").map(str::to_string);
            let log_id = if n == 0 { "log-1" } else { "log-2" };
            *cur = Some((etag.clone(), log_id.to_string(), seq, r.body.clone(), sig));
            // 204 carries ETag only (no Sync-Log header).
            written(&etag)
        }
        ("GET", p) if p.ends_with("/snapshot") => {
            let cur = rs.lock().unwrap();
            match cur.as_ref() {
                None => Response::status(404),
                Some((etag, log_id, seq, body, sig)) => {
                    let mut resp = Response::status(200)
                        .header("ETag", &format!("\"{etag}\""))
                        .header("Sync-Log", log_id)
                        .header("Sync-Seq", &seq.to_string());
                    if let Some(sig) = sig {
                        resp = resp
                            .header("X-Signer", "u1")
                            .header("X-Signing-Key", &pk_srv)
                            .header("X-Signature", sig);
                    }
                    resp.body(std::str::from_utf8(body).unwrap())
                }
            }
        }
        _ => Response::status(404),
    })
    .await;

    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), keeper.clone()));
    sync.set_personal(Some(auth.clone()));

    // Case A: Fresh auth (`signed_log_id == None`) commits snapshot on existing `log-1`,
    // keeper fails -> subsequent `read_log` observes `log-1` -> retry MUST reconcile and
    // recover `"snap-1"` without resending PUT (which would fail with `sync_snapshot_stale`).
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(5, b"snap-body".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "snap-1".into(), seq: 5, log: None }));
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 1);

    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    let _ = sync.read_log(0, None, None).await.unwrap();
    assert_eq!(sync.put_snapshot_bytes(5, b"snap-body".to_vec()).await.unwrap(), "snap-1");
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("log-1"));

    // Case B: Fresh auth (`signed_log_id == None`) commits snapshot, keeper fails ->
    // remote snapshot is wiped before retry WITHOUT any `read_log` -> retry MUST NOT treat
    // `Unknown == None` as a blind cache hit; it reconciles (404) and sends PUT #2.
    let keeper_b = TestKeeper::new();
    let auth_b = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper_b.clone()));
    sync.set_personal(Some(auth_b));
    *remote_snap.lock().unwrap() = None;

    keeper_b.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(5, b"snap-body".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "snap-2".into(), seq: 5, log: None }));
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 2);

    // Wipe remote snapshot (simulating log reset while local `signed_log_id` is still None).
    *remote_snap.lock().unwrap() = None;
    keeper_b.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.put_snapshot_bytes(5, b"snap-body".to_vec()).await.unwrap(), "snap-3");
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 3);
}

#[tokio::test]
async fn flush_committed_file_installs_watermark_into_replacement_auth_on_rebind() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let (_fake, sync) = homebase(|_| Response::status(404)).await;

    let keeper2 = TestKeeper::new();
    let v1_json = r#"{"v":2,"files":{"serverbox/identity.age":1}}"#;
    let auth2 = Arc::new(PersonalAuth::new(
        key.clone(),
        crate::personal::PersonalVersions::from_json(v1_json).unwrap(),
        keeper2.clone(),
    ));

    struct RebindDuringSave {
        sync: Arc<SyncClient<Kept>>,
        replacement: StdMutex<Option<Arc<PersonalAuth>>>,
    }
    impl crate::personal::VersionKeeper for RebindDuringSave {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            if let Some(next) = self.replacement.lock().unwrap().take() {
                self.sync.set_personal(Some(next));
            }
            Box::pin(async { Ok(()) })
        }
    }

    let keeper1 = Arc::new(RebindDuringSave {
        sync: sync.clone(),
        replacement: StdMutex::new(Some(auth2.clone())),
    });
    let auth1 = Arc::new(PersonalAuth::new(
        key,
        crate::personal::PersonalVersions::from_json(v1_json).unwrap(),
        keeper1,
    ));
    sync.set_personal(Some(auth1));

    // Rebinding `auth2` while `auth1` saves version 2 MUST NOT return `Ok(())`
    // until `auth2` itself installs and persists version 2!
    sync.flush_committed_file("u1", "identity.age", 2).await.unwrap();
    assert_eq!(auth2.next_file_version("serverbox", "identity.age").await.unwrap(), 3);
    let saved: serde_json::Value = serde_json::from_str(&keeper2.saved.lock().unwrap()).unwrap();
    assert_eq!(saved["files"]["serverbox/identity.age"], json!(2));
}

#[tokio::test]
async fn flush_committed_snapshot_with_none_log_preserves_other_log_entries() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), keeper));
    sync.set_personal(Some(auth));

    let k_confirmed = (3i64, [1u8; 32]);
    let k_assumed = (4i64, [2u8; 32]);
    let k_unknown = (5i64, [3u8; 32]);
    {
        let mut guard = sync.pending_commits.lock().unwrap();
        let c1 = guard.next_id();
        guard.snapshots.insert(k_confirmed, (c1, SnapshotLogBinding::Confirmed("other-log".into()), "e-conf".into()));
        let c2 = guard.next_id();
        guard.snapshots.insert(k_assumed, (c2, SnapshotLogBinding::Assumed("other-log".into()), "e-assm".into()));
        let c3 = guard.next_id();
        guard.snapshots.insert(k_unknown, (c3, SnapshotLogBinding::Unknown, "e-unk".into()));
    }

    // Mismatched `expected_user` MUST fail with `SignedOut` without mutating or cleaning up.
    assert_eq!(sync.flush_committed_snapshot("u2", None, 5).await.unwrap_err().kind, Kind::SignedOut);
    assert!(sync.pending_commits.lock().unwrap().snapshots.contains_key(&k_unknown));

    assert!(sync.flush_committed_snapshot("u1", None, 5).await.unwrap());
    let guard = sync.pending_commits.lock().unwrap();
    assert!(guard.snapshots.contains_key(&k_confirmed), "Confirmed entry for another log must be preserved");
    assert!(guard.snapshots.contains_key(&k_assumed), "Assumed entry for another log must be preserved");
    assert!(!guard.snapshots.contains_key(&k_unknown));
}

#[tokio::test]
async fn download_bytes_captures_auth_before_fetch_and_rejects_mid_flight_detach() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let sync_slot: Arc< std::sync::OnceLock<Arc<SyncClient<Kept>>> > = Arc::new(std::sync::OnceLock::new());
    let detach_on_get = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let slot_c = sync_slot.clone();
    let det_c = detach_on_get.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", p) if p.ends_with(NAME) => {
            if det_c.swap(false, std::sync::atomic::Ordering::SeqCst)
                && let Some(s) = slot_c.get()
            {
                s.set_personal(None);
            }
            // Unsigned response body!
            Response::status(200).header("ETag", "\"e1\"").body("unsigned-payload")
        }
        _ => Response::status(404),
    })
    .await;
    let _ = sync_slot.set(sync.clone());

    let auth = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth));

    // 1. Started with personal auth attached, detached mid-flight -> MUST fail with SignedOut,
    //    never returning unverified unsigned bytes.
    let err = sync.download_bytes(NAME).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);

    // 2. Call that BEGINS without personal auth preserves the unsigned path.
    let (body, etag, signed) = sync.download_bytes(NAME).await.unwrap().unwrap();
    assert_eq!(body, b"unsigned-payload");
    assert_eq!(etag, "e1");
    assert!(signed.is_none());
}

#[tokio::test]
async fn snapshot_reconcile_save_failure_keeps_entry_retryable_across_log_mismatch() {
    type RemoteSnapshot = (String, String, i64, Vec<u8>, Option<String>);
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let remote_snap: Arc<StdMutex<Option<RemoteSnapshot>>> = Arc::new(StdMutex::new(None));
    let put_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let rs = remote_snap.clone();
    let pc = put_calls.clone();
    let pk_srv = pub_key.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("GET", p) if p.ends_with("/log") => {
            Response::json(410, json!({ "code": 4, "reason": "sync_compacted", "data": "" }))
                .header("Sync-Log", "a2")
                .header("Sync-Snapshot-Seq", "5")
        }
        ("PUT", p) if p.ends_with("/snapshot") => {
            let n = pc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if n > 0 {
                return Response::json(409, json!({ "code": 4, "reason": "sync_snapshot_stale", "data": "" }));
            }
            let sig = r.header("x-signature").map(str::to_string);
            *rs.lock().unwrap() = Some(("snap-a2".into(), "a2".into(), 5, r.body.clone(), sig));
            // 204 without Sync-Log header.
            written("snap-a2")
        }
        ("GET", p) if p.ends_with("/snapshot") => {
            let cur = rs.lock().unwrap();
            let (etag, log_id, seq, body, sig) = cur.as_ref().unwrap();
            Response::status(200)
                .header("ETag", &format!("\"{etag}\""))
                .header("Sync-Log", log_id)
                .header("Sync-Seq", &seq.to_string())
                .header("X-Signer", "u1")
                .header("X-Signing-Key", &pk_srv)
                .header("X-Signature", sig.as_deref().unwrap())
                .body(std::str::from_utf8(body).unwrap())
        }
        _ => Response::status(404),
    })
    .await;

    // Step 0: fail PUT's record_snapshot_written (caches Assumed("a1"), dirty=true)
    // Step 1: succeed 410's flush_pending_versions (clears dirty, PersonalAuth still has a1; 410 turns Assumed("a1") -> Unknown)
    // Step 2: fail reconcile's verify_snapshot_digest save (PersonalAuth STILL has a1!)
    // Step 3+: succeed -> next retry MUST reconcile again and return "snap-a2" without resending PUT!
    struct StepSaveKeeper {
        step: std::sync::atomic::AtomicUsize,
    }
    impl crate::personal::VersionKeeper for StepSaveKeeper {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            let s = self.step.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async move {
                match s {
                    0 | 2 => Err("save failed".into()),
                    _ => Ok(()),
                }
            })
        }
    }

    let keeper = Arc::new(StepSaveKeeper { step: std::sync::atomic::AtomicUsize::new(0) });
    let initial_a1 = crate::personal::PersonalVersions::from_json(
        r#"{"v":2,"signed_log_from":{"serverbox":1},"signed_log_ids":{"serverbox":"a1"}}"#,
    )
    .unwrap();
    let auth = Arc::new(PersonalAuth::new(key, initial_a1, keeper));
    sync.set_personal(Some(auth.clone()));

    // 1. PUT commits on a2 without Sync-Log header; save fails -> cached as Assumed("a1").
    let err = sync.put_snapshot_bytes(5, b"snap-a2-body".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "snap-a2".into(), seq: 5, log: None }));
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 2. 410 identifies a2 -> retains entry as Unknown and flushes step 1 (`PersonalAuth` still reports a1).
    let compacted = sync.read_log(1, Some("a1"), None).await.unwrap();
    assert_eq!(compacted, LogRead::Compacted { log: Some("a2".into()), snapshot_seq: 5 });
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("a1"));

    // 3. First retry reconciles `/snapshot`, confirms match, but step 2 fails saving a2.
    let err = sync.put_snapshot_bytes(5, b"snap-a2-body".to_vec()).await.unwrap_err();
    assert_eq!(err.committed, Some(Committed::Snapshot { etag: "snap-a2".into(), seq: 5, log: Some("a2".into()) }));
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 1);

    // 4. Second retry MUST NOT discard the entry due to PersonalAuth still reporting a1;
    //    it reconciles again, saves a2, and returns "snap-a2" with 0 additional PUTs!
    assert_eq!(sync.put_snapshot_bytes(5, b"snap-a2-body".to_vec()).await.unwrap(), "snap-a2");
    assert_eq!(put_calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("a2"));
}

/// Waits until [task] reaches the fixture's [reached] notification, failing
/// with [stage] if it finishes first or does not get there in time.
async fn reach<T: std::fmt::Debug>(stage: &str, reached: &tokio::sync::Notify, task: &mut tokio::task::JoinHandle<T>) {
    tokio::select! {
        biased;
        () = reached.notified() => {}
        done = task => panic!("{stage}: request finished before reaching the fixture: {done:?}"),
        () = tokio::time::sleep(Duration::from_secs(5)) => panic!("{stage}: timed out"),
    }
}

#[tokio::test]
async fn delete_binds_session_identity_across_lock_and_retry_while_waiting_on_same_account_put() {
    let delete_503 = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let retry_received = Arc::new(tokio::sync::Notify::new());
    let (release_503_tx, release_503_rx) = tokio::sync::oneshot::channel::<()>();
    let hold_503 = Arc::new(StdMutex::new(Some(release_503_rx)));
    let delete_tokens = Arc::new(StdMutex::new(Vec::<String>::new()));

    let d503 = delete_503.clone();
    let rr = retry_received.clone();
    let h503 = hold_503.clone();
    let dt = delete_tokens.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("DELETE", p) if p.ends_with(NAME) => {
            let auth_hdr = r.header("authorization").unwrap_or("").to_string();
            dt.lock().unwrap().push(auth_hdr);
            if d503.swap(false, std::sync::atomic::Ordering::SeqCst) {
                rr.notify_one();
                let rx = h503.lock().unwrap().take().expect("hold receiver");
                return Response::status(503).header("Retry-After", "0").hold(rx);
            }
            Response::status(204)
        }
        _ => Response::status(404),
    })
    .await;

    // 1. Same-account DELETE waits on per-name lock behind an in-flight lock holder, then dispatches.
    let before_lock = Arc::new(tokio::sync::Notify::new());
    *sync.before_file_lock.lock().unwrap() = Some(before_lock.clone());
    let lock = sync.file_lock(NAME);
    let guard = lock.lock().await;
    let sync_same = sync.clone();
    let mut del_same = tokio::spawn(async move { sync_same.delete(NAME, None).await });
    reach("queued DELETE", &before_lock, &mut del_same).await;
    tokio::task::yield_now().await;
    assert!(tokio::time::timeout(Duration::from_millis(20), &mut del_same).await.is_err());
    assert!(delete_tokens.lock().unwrap().is_empty());
    drop(guard);
    assert!(del_same.await.unwrap().unwrap());
    assert_eq!(delete_tokens.lock().unwrap().len(), 1);

    // 2. Session switch while DELETE is held at `_file_guard` MUST reject BEFORE dispatch!
    delete_tokens.lock().unwrap().clear();
    let guard2 = lock.lock().await;
    let sync_switch = sync.clone();
    let mut del_switch = tokio::spawn(async move { sync_switch.delete(NAME, None).await });
    reach("DELETE held before the session switch", &before_lock, &mut del_switch).await;
    tokio::task::yield_now().await;
    sync.session()
        .sign_in(crate::Tokens::stored("tok-u2".into(), Some("ref-u2".into()), crate::now_ms() + 3_600_000))
        .await
        .unwrap();
    drop(guard2);
    assert_eq!(del_switch.await.unwrap().unwrap_err().kind, Kind::SignedOut);
    assert!(delete_tokens.lock().unwrap().is_empty(), "stale session DELETE must not dispatch after session switch");
    *sync.before_file_lock.lock().unwrap() = None;

    // 3. Session switch while fixture holds the `503 Retry-After` response MUST abort the retry before sending with u3's token!
    delete_503.store(true, std::sync::atomic::Ordering::SeqCst);
    let sync_retry = sync.clone();
    let mut del_retry = tokio::spawn(async move { sync_retry.delete(NAME, None).await });
    reach("DELETE answered 503", &retry_received, &mut del_retry).await;
    assert_eq!(delete_tokens.lock().unwrap().as_slice(), &["Bearer tok-u2".to_string()]);
    sync.session()
        .sign_in(crate::Tokens::stored("tok-u3".into(), Some("ref-u3".into()), crate::now_ms() + 3_600_000))
        .await
        .unwrap();
    let _ = release_503_tx.send(());
    assert_eq!(del_retry.await.unwrap().unwrap_err().kind, Kind::SignedOut);
    assert_eq!(delete_tokens.lock().unwrap().as_slice(), &["Bearer tok-u2".to_string()], "retry must not send under u3 token");
}

#[tokio::test]
async fn upload_binds_session_identity_across_lock_and_multipart() {
    let put_tokens = Arc::new(StdMutex::new(Vec::<String>::new()));
    let multipart_tokens = Arc::new(StdMutex::new(Vec::<(String, String)>::new()));
    let store_started = Arc::new(tokio::sync::Notify::new());
    let (release_store_tx, release_store_rx) = tokio::sync::oneshot::channel::<()>();
    let hold_store = Arc::new(StdMutex::new(Some(release_store_rx)));

    let pt = put_tokens.clone();
    let mt = multipart_tokens.clone();
    let ss = store_started.clone();
    let hs = hold_store.clone();

    let (_fake, sync) = homebase(move |r| {
        let base = format!("http://{}", r.header("host").unwrap());
        let auth_hdr = r.header("authorization").unwrap_or("").to_string();
        match (r.method.as_str(), r.path()) {
            ("PUT", p) if p.ends_with(NAME) => {
                pt.lock().unwrap().push(auth_hdr);
                written("e-put")
            }
            ("POST", p) if p.ends_with("/uploads") => {
                mt.lock().unwrap().push(("init".into(), auth_hdr));
                Response::json(200, json!({ "data": { "id": "mp1", "url": format!("{base}/store/mp1"), "expires_at": "x", "etag": "e-mp" } }))
            }
            ("PUT", "/store/mp1") => {
                ss.notify_one();
                if let Some(rx) = hs.lock().unwrap().take() {
                    Response::status(200).hold(rx)
                } else {
                    Response::status(200)
                }
            }
            ("POST", p) if p.ends_with("/uploads/mp1/complete") => {
                mt.lock().unwrap().push(("complete".into(), auth_hdr));
                written("e-mp")
            }
            _ => Response::status(404),
        }
    })
    .await;

    // 1. Direct PUT held on per-name lock MUST reject before dispatch when session switches!
    let before_lock = Arc::new(tokio::sync::Notify::new());
    *sync.before_file_lock.lock().unwrap() = Some(before_lock.clone());
    let lock = sync.file_lock(NAME);
    let guard = lock.lock().await;
    let sync_put = sync.clone();
    let mut put_task = tokio::spawn(async move { sync_put.upload_bytes(NAME, b"small".to_vec(), Condition::Absent).await });
    reach("PUT held before the session switch", &before_lock, &mut put_task).await;
    tokio::task::yield_now().await;
    sync.session()
        .sign_in(crate::Tokens::stored("tok-u2".into(), Some("ref-u2".into()), crate::now_ms() + 3_600_000))
        .await
        .unwrap();
    drop(guard);
    assert_eq!(put_task.await.unwrap().unwrap_err().kind, Kind::SignedOut);
    assert!(put_tokens.lock().unwrap().is_empty(), "queued PUT must not send under replacement session");
    *sync.before_file_lock.lock().unwrap() = None;

    // 2. Direct PUT with unchanged session succeeds with tok-u2.
    assert_eq!(sync.upload_bytes(NAME, b"small".to_vec(), Condition::Absent).await.unwrap(), "e-put");
    assert_eq!(put_tokens.lock().unwrap().as_slice(), &["Bearer tok-u2".to_string()]);

    // 3. Multipart upload where session switches during store upload MUST reject completion under tok-u3!
    let big = vec![9u8; (DIRECT_MAX + 1) as usize];
    let sync_mp = sync.clone();
    let big_c = big.clone();
    let mut mp_task = tokio::spawn(async move { sync_mp.upload_bytes(NAME, big_c, Condition::Absent).await });
    reach("multipart store upload", &store_started, &mut mp_task).await;
    sync.session()
        .sign_in(crate::Tokens::stored("tok-u3".into(), Some("ref-u3".into()), crate::now_ms() + 3_600_000))
        .await
        .unwrap();
    let _ = release_store_tx.send(());
    assert_eq!(mp_task.await.unwrap().unwrap_err().kind, Kind::SignedOut);
    assert_eq!(
        multipart_tokens.lock().unwrap().as_slice(),
        &[("init".to_string(), "Bearer tok-u2".to_string())],
        "multipart completion must not dispatch under replacement session"
    );

    // 4. Multipart upload with unchanged session completes normally under tok-u3.
    multipart_tokens.lock().unwrap().clear();
    assert_eq!(sync.upload_bytes(NAME, big, Condition::Absent).await.unwrap(), "e-mp");
    assert_eq!(
        multipart_tokens.lock().unwrap().as_slice(),
        &[
            ("init".to_string(), "Bearer tok-u3".to_string()),
            ("complete".to_string(), "Bearer tok-u3".to_string()),
        ]
    );
}

#[tokio::test]
async fn detached_snapshot_recovery_requires_signature_and_preserves_recorded_log_binding() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let snap_body = b"snap-recovery-body".to_vec();
    let snap_sig = {
        let auth_tmp = PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), TestKeeper::new());
        auth_tmp.sign_snapshot("serverbox", 5, &snap_body).await.signature
    };

    // (log_id, seq, signed); `None` answers 404.
    let served: Arc<StdMutex<Option<(String, i64, bool)>>> = Arc::new(StdMutex::new(Some(("a1".into(), 5, false))));
    let served_srv = served.clone();
    let body_srv = snap_body.clone();
    let sig_srv = snap_sig.clone();
    let pk_srv = pub_key.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("GET", p) if p.ends_with("/log") => {
            Response::json(410, json!({ "code": 4, "reason": "sync_compacted", "data": "" }))
                .header("Sync-Log", "a2")
                .header("Sync-Snapshot-Seq", "1")
        }
        ("GET", p) if p.ends_with("/snapshot") => {
            let Some((log_id, seq, signed)) = served_srv.lock().unwrap().clone() else {
                return Response::status(404);
            };
            let mut resp = Response::status(200)
                .header("ETag", "\"snap-e\"")
                .header("Sync-Log", &log_id)
                .header("Sync-Seq", &seq.to_string());
            if signed {
                resp = resp
                    .header("X-Signer", "u1")
                    .header("X-Signing-Key", &pk_srv)
                    .header("X-Signature", &sig_srv);
            }
            resp.body(body_srv.clone())
        }
        _ => Response::status(404),
    })
    .await;

    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), keeper));
    sync.set_personal(Some(auth.clone()));

    // 1. Ordinary download path still accepts an unsigned legacy snapshot.
    let (legacy_snap, legacy_bytes) = sync.download_snapshot_bytes().await.unwrap().unwrap();
    assert_eq!(legacy_snap.log, "a1");
    assert!(legacy_snap.signed.is_none());
    assert_eq!(legacy_bytes, snap_body);

    // 2. Detached snapshot recovery MUST reject a matching unsigned snapshot as Untrusted!
    let err = sync.flush_committed_snapshot_bytes("u1", None, 5, &snap_body).await.unwrap_err();
    assert_eq!(err.kind, Kind::Untrusted);

    // 3. Matching signed snapshot completes detached recovery without another PUT when no conflicting binding exists.
    *served.lock().unwrap() = Some(("a1".into(), 5, true));
    let (recovered, resolved) = sync.flush_committed_snapshot_bytes("u1", None, 5, &snap_body).await.unwrap();
    assert!(recovered);
    assert_eq!(resolved.as_deref(), Some("a1"));
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("a1"));

    // 4. Once a different log binding (`a2`) is recorded under the same auth generation,
    //    detached recovery observing a verified signed snapshot for `a1` MUST NOT replace `a2`
    //    or evict pending commits for `a2`!
    let auth2 = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth2.clone()));
    auth2.record_batch_written("serverbox", "a2", 1).await.unwrap();
    let _ = sync.read_log(0, Some("a2"), None).await.unwrap();
    let batch_key = ("idem-a2-12345678".to_string(), [7u8; 32]);
    {
        let mut guard = sync.pending_commits.lock().unwrap();
        let id = guard.next_id();
        guard.batches.insert(
            batch_key.clone(),
            (id, Appended { log: "a2".into(), seq: 2, live: Live { batches: 1, bytes: 10 }, compact: false }),
        );
    }

    let (recovered2, resolved2) = sync.flush_committed_snapshot_bytes("u1", None, 5, &snap_body).await.unwrap();
    assert!(!recovered2);
    assert!(resolved2.is_none());
    assert_eq!(auth2.signed_log_id("serverbox").await.as_deref(), Some("a2"));
    assert!(sync.pending_commits.lock().unwrap().batches.contains_key(&batch_key));

    // 5. When `observed_log` is `Some("a2")` (from 410) while `PersonalAuth.signed_log_ids` is still
    //    `None`, flushing with conflicting `log = Some("a1")` MUST NOT bind `PersonalAuth` to `"a1"`.
    let auth3_keeper = TestKeeper::new();
    let auth3 = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), auth3_keeper.clone()));
    sync.set_personal(Some(auth3.clone()));
    let _ = sync.read_log(0, None, None).await.unwrap(); // 410 Sync-Log: a2 -> sets observed_log = Some("a2")
    assert!(!sync.flush_committed_snapshot("u1", Some("a1"), 5).await.unwrap());
    assert_eq!(auth3.signed_log_id("serverbox").await, None, "conflicting flush must not pollute signed_log_ids");
    assert!(sync.flush_committed_snapshot("u1", Some("a2"), 6).await.unwrap());
    assert_eq!(auth3.signed_log_id("serverbox").await.as_deref(), Some("a2"));

    // 5b. Detached recovery of the old seq whose `/snapshot` is gone (404) records only the
    //     signed-snapshot marker: neither the replacement log binding nor its floor moves.
    let floor = |keeper: &TestKeeper| {
        let saved: serde_json::Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
        (saved["signed_log_ids"]["serverbox"].as_str().map(str::to_string), saved["signed_log_from"]["serverbox"].as_i64())
    };
    assert_eq!(floor(&auth3_keeper), (Some("a2".into()), Some(6)));
    *served.lock().unwrap() = None;
    for log in [Some("a1"), None] {
        let (recovered, resolved) = sync.flush_committed_snapshot_bytes("u1", log, 5, &snap_body).await.unwrap();
        assert!(!recovered && resolved.is_none(), "{log:?}");
        assert_eq!(auth3.signed_log_id("serverbox").await.as_deref(), Some("a2"));
        assert_eq!(floor(&auth3_keeper), (Some("a2".into()), Some(6)), "{log:?}");
    }

    // 6. Concurrent `read_log` 410 setting `observed_log = Some("a2")` DURING `keeper.save` of
    //    `reconcile_detached_snapshot` (for `"a1"`) MUST NOT leave `PersonalAuth` bound to `"a1"`!
    *served.lock().unwrap() = Some(("a1".into(), 5, true));
    struct RaceOnSaveKeeper {
        sync: Arc<SyncClient<Kept>>,
        raced: std::sync::atomic::AtomicBool,
        saved: StdMutex<String>,
    }
    impl crate::personal::VersionKeeper for RaceOnSaveKeeper {
        fn save(&self, json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            *self.saved.lock().unwrap() = json;
            let should_race = !self.raced.swap(true, std::sync::atomic::Ordering::SeqCst);
            let sync = self.sync.clone();
            Box::pin(async move {
                if should_race {
                    // Simulate concurrent `read_log` 410 observing `"a2"` while `keeper.save` awaits!
                    let auth_gen = sync.personal_generation();
                    sync.retain_log_commits(auth_gen, Some("a2"));
                }
                Ok(())
            })
        }
    }
    let race_keeper = Arc::new(RaceOnSaveKeeper {
        sync: sync.clone(),
        raced: std::sync::atomic::AtomicBool::new(false),
        saved: StdMutex::new(String::new()),
    });
    let auth4 = Arc::new(PersonalAuth::new(key, crate::personal::PersonalVersions::default(), race_keeper.clone()));
    sync.set_personal(Some(auth4.clone()));
    let (recovered4, resolved4) = sync.flush_committed_snapshot_bytes("u1", None, 5, &snap_body).await.unwrap();
    assert!(!recovered4);
    assert!(resolved4.is_none());
    assert_eq!(auth4.signed_log_id("serverbox").await, None, "raced detached save must not commit a1");
    let reloaded = crate::personal::PersonalVersions::from_json(&race_keeper.saved.lock().unwrap()).unwrap();
    let auth4_reloaded = PersonalAuth::new(
        crate::team::identity::AccountKey::generate("u1"),
        reloaded,
        TestKeeper::new(),
    );
    assert_eq!(auth4_reloaded.signed_log_id("serverbox").await, None, "persisted fallback must not contain a1");
}

#[tokio::test]
async fn snapshot_flush_yields_to_a_log_observed_while_its_binding_is_saved() {
    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    /// Observes `b2` live during save number [race_at].
    struct RaceKeeper {
        sync: Arc<SyncClient<Kept>>,
        race_at: usize,
        saves: std::sync::atomic::AtomicUsize,
        saved: StdMutex<Vec<String>>,
    }
    impl crate::personal::VersionKeeper for RaceKeeper {
        fn save(&self, json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            self.saved.lock().unwrap().push(json);
            if self.saves.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == self.race_at {
                self.sync.retain_log_commits(self.sync.personal_generation(), Some("b2"));
            }
            Box::pin(async { Ok(()) })
        }
    }
    // Save 0 persists the signed-snapshot marker, save 1 the binding to `a1`.
    for race_at in [0, 1, usize::MAX] {
        let keeper = Arc::new(RaceKeeper { sync: sync.clone(), race_at, saves: Default::default(), saved: Default::default() });
        let auth = Arc::new(PersonalAuth::new(crate::team::identity::AccountKey::generate("u1"), Default::default(), keeper.clone()));
        sync.set_personal(Some(auth.clone()));
        let compatible = sync.flush_committed_snapshot("u1", Some("a1"), 5).await.unwrap();
        let observed = sync.pending_commits.lock().unwrap().observed_log.clone();
        if race_at == usize::MAX {
            assert!(compatible);
            assert_eq!(observed.as_deref(), Some("a1"));
            assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("a1"));
            continue;
        }
        assert!(!compatible, "race at save {race_at}");
        assert_eq!(observed.as_deref(), Some("b2"), "race at save {race_at}: the live observation must be kept");
        if race_at == 0 {
            assert_eq!(auth.signed_log_id("serverbox").await, None);
            assert!(keeper.saved.lock().unwrap().iter().all(|json| !json.contains("\"a1\"")));
        }
    }
}

#[tokio::test]
async fn a_malformed_410_keeps_pending_commits() {
    let snapshot_seq: Arc<StdMutex<Option<&'static str>>> = Arc::new(StdMutex::new(None));
    let seq_srv = snapshot_seq.clone();
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", p) if p.ends_with("/log") => {
            let mut resp = Response::json(410, json!({ "code": 4, "reason": "sync_compacted", "data": "" })).header("Sync-Log", "b2");
            if let Some(seq) = *seq_srv.lock().unwrap() {
                resp = resp.header("Sync-Snapshot-Seq", seq);
            }
            resp
        }
        _ => Response::status(404),
    })
    .await;
    let auth = Arc::new(PersonalAuth::new(crate::team::identity::AccountKey::generate("u1"), Default::default(), TestKeeper::new()));
    sync.set_personal(Some(auth));
    let batch_key = ("idem-a1-123456789".to_string(), [7u8; 32]);
    {
        let mut guard = sync.pending_commits.lock().unwrap();
        let id = guard.next_id();
        guard.batches.insert(batch_key.clone(), (id, Appended { log: "a1".into(), seq: 2, live: Live { batches: 1, bytes: 10 }, compact: false }));
    }

    for bad in [None, Some("x"), Some("-1")] {
        *snapshot_seq.lock().unwrap() = bad;
        assert_eq!(sync.read_log(1, Some("a1"), None).await.unwrap_err().kind, Kind::Invalid, "{bad:?}");
        let guard = sync.pending_commits.lock().unwrap();
        assert!(guard.batches.contains_key(&batch_key), "{bad:?}");
        assert_eq!(guard.observed_log, None, "{bad:?}");
    }

    // A valid 410 naming a replaced log still invalidates its entries.
    *snapshot_seq.lock().unwrap() = Some("7");
    assert_eq!(sync.read_log(1, Some("a1"), None).await.unwrap(), LogRead::Compacted { log: Some("b2".into()), snapshot_seq: 7 });
    let guard = sync.pending_commits.lock().unwrap();
    assert!(!guard.batches.contains_key(&batch_key));
    assert_eq!(guard.observed_log.as_deref(), Some("b2"));
}
