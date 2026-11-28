//! Writes that committed while their watermark save failed.

use super::*;

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
