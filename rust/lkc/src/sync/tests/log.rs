//! The log: batches, pages, snapshots and retries.

use super::*;

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

#[tokio::test]
async fn a_malformed_log_id_is_refused_before_it_is_kept() {
    let (_fake, sync) = homebase(|r| match r.method.as_str() {
        "POST" => Response::json(200, json!({ "code": 0, "data": { "log": "log/old", "seq": 3, "live": { "batches": 3, "bytes": 90 }, "compact": false } })),
        _ => Response::json(200, json!({ "code": 0, "data": { "log": "log/old", "batches": [], "head": 0, "snapshot_seq": 0, "more": false } })),
    })
    .await;
    assert_eq!(sync.read_log(0, None, None).await.unwrap_err().kind, Kind::Invalid);
    assert_eq!(sync.append(KEY, b"b".to_vec()).await.unwrap_err().kind, Kind::Invalid);
    assert_eq!(sync.pending_commits.lock().unwrap().observed_log, None);
}
