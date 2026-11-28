//! Personal auth and session identity held across a request.

use super::*;

#[tokio::test]
async fn stale_auth_cannot_insert_or_reuse_pending_commit_after_set_personal() {
    let key1 = AccountKey::generate("u1");
    let pub1 = key1.signing_public();
    let rec1 = key1.recipient();
    let key2 = AccountKey::generate("u2");
    let pub2 = key2.signing_public();
    let rec2 = key2.recipient();
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let (fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => {
            if seen.load(Ordering::SeqCst) == 0 {
                Response::json(200, json!({ "data": { "recipient": rec1, "signing_key": pub1, "next_seq": 2, "prev_signing_key": pub1 } }))
            } else {
                Response::json(200, json!({ "data": { "recipient": rec2, "signing_key": pub2, "next_seq": 2, "prev_signing_key": pub2 } }))
            }
        }
        ("PUT", p) if p.ends_with(NAME) => {
            let n = seen.fetch_add(1, Ordering::SeqCst);
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
    let auth2 = Arc::new(PersonalAuth::new(key2, PersonalVersions::default(), keeper2));
    let keeper1 = Arc::new(SwitchingKeeper { sync: sync.clone(), next_auth: StdMutex::new(Some(auth2)) });
    let auth1 = Arc::new(PersonalAuth::new(key1, PersonalVersions::default(), keeper1));
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
async fn detaching_personal_auth_during_recovery_flush_never_sends_unsigned_write() {
    let key = AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let unsigned_writes = Arc::new(AtomicUsize::new(0));
    let puts = Arc::new(AtomicUsize::new(0));
    let appends = Arc::new(AtomicUsize::new(0));
    let snaps = Arc::new(AtomicUsize::new(0));
    let file_etag: Arc<StdMutex<Option<String>>> = Arc::new(StdMutex::new(None));
    let uw = unsigned_writes.clone();
    let pc = puts.clone();
    let ac = appends.clone();
    let sc = snaps.clone();
    let fe = file_etag.clone();

    let (_fake, sync) = homebase(move |r| {
        if matches!(r.method.as_str(), "PUT" | "POST") && r.header("x-signature").is_none() {
            uw.fetch_add(1, Ordering::SeqCst);
        }
        match (r.method.as_str(), r.path()) {
            ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
            ("PUT", p) if p.ends_with(NAME) => {
                pc.fetch_add(1, Ordering::SeqCst);
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
                ac.fetch_add(1, Ordering::SeqCst);
                Response::json(200, json!({ "data": { "log": "1a01", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } }))
            }
            ("PUT", p) if p.ends_with("/snapshot") => {
                sc.fetch_add(1, Ordering::SeqCst);
                written("snap-1")
            }
            _ => Response::status(404),
        }
    })
    .await;

    struct DetachOnSecondSave {
        sync: Arc<SyncClient<Kept>>,
        mode: AtomicUsize, // 0 = fail, 1 = detach & ok
    }
    impl crate::personal::VersionKeeper for DetachOnSecondSave {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                if self.mode.load(Ordering::SeqCst) == 0 {
                    Err("save failed".into())
                } else {
                    self.sync.set_personal(None);
                    Ok(())
                }
            })
        }
    }

    let keeper = Arc::new(DetachOnSecondSave { sync: sync.clone(), mode: AtomicUsize::new(0) });
    let auth = Arc::new(PersonalAuth::new(key, PersonalVersions::default(), keeper.clone()));

    // 1. upload_bytes: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    sync.set_personal(Some(auth.clone()));
    assert!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.is_err());
    keeper.mode.store(1, Ordering::SeqCst);
    let err = sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(puts.load(Ordering::SeqCst), 1);

    // 2. append: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    keeper.mode.store(0, Ordering::SeqCst);
    sync.set_personal(Some(auth.clone()));
    let idem = "idempotency-key-5678";
    assert!(sync.append(idem, b"b".to_vec()).await.is_err());
    keeper.mode.store(1, Ordering::SeqCst);
    let err = sync.append(idem, b"b".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(appends.load(Ordering::SeqCst), 1);

    // 3. put_snapshot_bytes: cache entry, then detach auth during retry flush -> MUST return SignedOut, no unsigned write.
    keeper.mode.store(0, Ordering::SeqCst);
    sync.set_personal(Some(auth.clone()));
    assert!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.is_err());
    keeper.mode.store(1, Ordering::SeqCst);
    let err = sync.put_snapshot_bytes(1, b"s".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut);
    assert_eq!(snaps.load(Ordering::SeqCst), 1);

    assert_eq!(unsigned_writes.load(Ordering::SeqCst), 0, "no unsigned write may be dispatched after personal auth detaches");

    // 4. Calls that BEGIN without personal auth preserve the existing unsigned path
    //    against the committed `e1` version of NAME.
    assert_eq!(sync.upload_bytes(NAME, b"u".to_vec(), Condition::Match("e1".into())).await.unwrap(), "e2");
    assert_eq!(unsigned_writes.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn switching_personal_auth_during_recovery_flush_rejects_in_flight_write() {
    let key1 = AccountKey::generate("u1");
    let pub1 = key1.signing_public();
    let rec1 = key1.recipient();
    let key2 = AccountKey::generate("u2");
    let auth2 = Arc::new(PersonalAuth::new(key2, PersonalVersions::default(), TestKeeper::new()));

    let puts = Arc::new(AtomicUsize::new(0));
    let appends = Arc::new(AtomicUsize::new(0));
    let snaps = Arc::new(AtomicUsize::new(0));
    let pc = puts.clone();
    let ac = appends.clone();
    let sc = snaps.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": rec1, "signing_key": pub1, "next_seq": 2, "prev_signing_key": pub1 } })),
        ("PUT", p) if p.ends_with(NAME) => {
            pc.fetch_add(1, Ordering::SeqCst);
            written("e1")
        }
        ("POST", p) if p.ends_with("/log") => {
            ac.fetch_add(1, Ordering::SeqCst);
            Response::json(200, json!({ "data": { "log": "1a01", "seq": 1, "live": { "batches": 1, "bytes": 4 }, "compact": false } }))
        }
        ("PUT", p) if p.ends_with("/snapshot") => {
            sc.fetch_add(1, Ordering::SeqCst);
            written("snap-1")
        }
        _ => Response::status(404),
    })
    .await;

    struct SwitchOnSecondSave {
        sync: Arc<SyncClient<Kept>>,
        replacement: Arc<PersonalAuth>,
        mode: AtomicUsize,
    }
    impl crate::personal::VersionKeeper for SwitchOnSecondSave {
        fn save(&self, _json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
            Box::pin(async move {
                if self.mode.load(Ordering::SeqCst) == 0 {
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
        mode: AtomicUsize::new(0),
    });
    let auth1 = Arc::new(PersonalAuth::new(key1, PersonalVersions::default(), keeper1.clone()));

    // 1. upload_bytes MUST NOT adopt auth2 for u1's in-flight write.
    sync.set_personal(Some(auth1.clone()));
    assert!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.is_err());
    keeper1.mode.store(1, Ordering::SeqCst);
    assert_eq!(sync.upload_bytes(NAME, b"f".to_vec(), Condition::Absent).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(puts.load(Ordering::SeqCst), 1);

    // 2. append MUST NOT adopt auth2 for u1's in-flight write.
    keeper1.mode.store(0, Ordering::SeqCst);
    sync.set_personal(Some(auth1.clone()));
    let idem = "idempotency-key-9012";
    assert!(sync.append(idem, b"b".to_vec()).await.is_err());
    keeper1.mode.store(1, Ordering::SeqCst);
    assert_eq!(sync.append(idem, b"b".to_vec()).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(appends.load(Ordering::SeqCst), 1);

    // 3. put_snapshot_bytes MUST NOT adopt auth2 for u1's in-flight write.
    keeper1.mode.store(0, Ordering::SeqCst);
    sync.set_personal(Some(auth1));
    assert!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.is_err());
    keeper1.mode.store(1, Ordering::SeqCst);
    assert_eq!(sync.put_snapshot_bytes(1, b"s".to_vec()).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(snaps.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn download_bytes_captures_auth_before_fetch_and_rejects_mid_flight_detach() {
    let key = AccountKey::generate("u1");
    let sync_slot: Arc< OnceLock<Arc<SyncClient<Kept>>> > = Arc::new(OnceLock::new());
    let detach_on_get = Arc::new(AtomicBool::new(true));
    let slot_c = sync_slot.clone();
    let det_c = detach_on_get.clone();

    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", p) if p.ends_with(NAME) => {
            if det_c.swap(false, Ordering::SeqCst)
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

    let auth = Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()));
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
async fn delete_binds_session_identity_across_lock_and_retry_while_waiting_on_same_account_put() {
    let delete_503 = Arc::new(AtomicBool::new(false));
    let retry_received = Arc::new(Notify::new());
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
            if d503.swap(false, Ordering::SeqCst) {
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
    let before_lock = Arc::new(Notify::new());
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
    delete_503.store(true, Ordering::SeqCst);
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
    let store_started = Arc::new(Notify::new());
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
    let before_lock = Arc::new(Notify::new());
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
async fn a_personal_append_is_not_sent_again_under_an_auth_set_meanwhile() {
    let key = AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let next = Arc::new(PersonalAuth::new(key.clone(), PersonalVersions::default(), TestKeeper::new()));
    let client: Arc<OnceLock<Arc<SyncClient<Kept>>>> = Arc::default();
    let posts = Arc::new(AtomicUsize::new(0));
    let (_fake, sync) = homebase({
        let (client, posts) = (client.clone(), posts.clone());
        move |r| match (r.method.as_str(), r.path()) {
            ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
            ("POST", p) if p.ends_with("/log") => {
                posts.fetch_add(1, Ordering::SeqCst);
                // The auth is replaced while the client waits to try again.
                client.get().unwrap().set_personal(Some(next.clone()));
                Response::status(503).header("retry-after", "0")
            }
            _ => Response::status(404),
        }
    })
    .await;
    client.set(sync.clone()).ok().unwrap();
    sync.set_personal(Some(Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()))));
    let err = sync.append("idempotency-key-1234", b"batch".to_vec()).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut, "{err:?}");
    assert_eq!(posts.load(Ordering::SeqCst), 1, "nothing sent under the other auth");
}

#[tokio::test]
async fn a_snapshot_upload_is_not_completed_under_an_auth_set_meanwhile() {
    let key = AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let next = Arc::new(PersonalAuth::new(key.clone(), PersonalVersions::default(), TestKeeper::new()));
    let client: Arc<OnceLock<Arc<SyncClient<Kept>>>> = Arc::default();
    let (fake, sync) = homebase({
        let client = client.clone();
        move |r| {
            let base = format!("http://{}", r.header("host").unwrap());
            match (r.method.as_str(), r.path()) {
                ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
                ("POST", "/v2/sync/serverbox/snapshot/uploads") => Response::json(200, json!({ "data": { "id": "u1", "url": format!("{base}/store/u1") } })),
                ("PUT", "/store/u1") => {
                    // The auth is replaced while the body goes to the store.
                    client.get().unwrap().set_personal(Some(next.clone()));
                    Response::status(200)
                }
                _ => written("snap-1").header("sync-log", "1a0a"),
            }
        }
    })
    .await;
    client.set(sync.clone()).ok().unwrap();
    sync.set_personal(Some(Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()))));
    let err = sync.put_snapshot_bytes(9, vec![1u8; (DIRECT_MAX + 1) as usize]).await.unwrap_err();
    assert_eq!(err.kind, Kind::SignedOut, "{err:?}");
    assert_eq!(fake.requests("/store/u1").len(), 1, "the body went to the store, under which the auth was replaced");
    assert!(fake.requests("/v2/sync/serverbox/snapshot/uploads/u1/complete").is_empty(), "not completed under the other auth");
}
