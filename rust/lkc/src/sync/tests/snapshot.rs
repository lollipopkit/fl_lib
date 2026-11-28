//! Snapshot recovery and its log binding.

use super::*;

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
    let auth3 = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth3.clone()));
    let _ = sync.read_log(0, None, None).await.unwrap(); // 410 Sync-Log: a2 -> sets observed_log = Some("a2")
    assert!(!sync.flush_committed_snapshot("u1", Some("a1"), 5).await.unwrap());
    assert_eq!(auth3.signed_log_id("serverbox").await, None, "conflicting flush must not pollute signed_log_ids");
    assert!(sync.flush_committed_snapshot("u1", Some("a2"), 6).await.unwrap());
    assert_eq!(auth3.signed_log_id("serverbox").await.as_deref(), Some("a2"));

    // 5b. Detached recovery of the old seq whose `/snapshot` is gone (404) records the
    //     signed-snapshot marker, leaving the replacement log binding and its floor. A fresh
    //     auth per case keeps an earlier marker from satisfying the assertion.
    let persisted = |keeper: &TestKeeper| {
        let saved: serde_json::Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
        (
            saved["signed_log_ids"]["serverbox"].as_str().map(str::to_string),
            saved["signed_log_from"]["serverbox"].as_i64(),
            saved["signed_snapshots"].as_array().is_some_and(|apps| apps.iter().any(|a| a == "serverbox")),
        )
    };
    *served.lock().unwrap() = None;
    for log in [Some("a1"), None] {
        let keeper = TestKeeper::new();
        let auth = Arc::new(PersonalAuth::new(key.clone(), crate::personal::PersonalVersions::default(), keeper.clone()));
        sync.set_personal(Some(auth.clone()));
        auth.record_batch_written("serverbox", "a2", 6).await.unwrap();
        assert_eq!(persisted(&keeper), (Some("a2".into()), Some(6), false), "{log:?}");
        let (recovered, resolved) = sync.flush_committed_snapshot_bytes("u1", log, 5, &snap_body).await.unwrap();
        assert!(!recovered && resolved.is_none(), "{log:?}");
        assert_eq!(persisted(&keeper), (Some("a2".into()), Some(6), true), "{log:?}");
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

#[tokio::test]
async fn a_404_settles_only_the_reconciled_snapshot_entry_once_its_marker_is_persisted() {
    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    let body = b"snap-body";
    let hit = (5i64, *blake3::hash(body).as_bytes());
    let unrelated = [(3i64, [1u8; 32]), (4i64, [2u8; 32])];
    let attach = |hit_too: bool| {
        let keeper = TestKeeper::new();
        sync.set_personal(Some(Arc::new(PersonalAuth::new(crate::team::identity::AccountKey::generate("u1"), Default::default(), keeper.clone()))));
        let mut guard = sync.pending_commits.lock().unwrap();
        let id = guard.next_id();
        guard.snapshots.insert(unrelated[0], (id, SnapshotLogBinding::Unknown, "e3".into()));
        let id = guard.next_id();
        guard.snapshots.insert(unrelated[1], (id, SnapshotLogBinding::Assumed("a1".into()), "e4".into()));
        if hit_too {
            let id = guard.next_id();
            guard.snapshots.insert(hit, (id, SnapshotLogBinding::Unknown, "e5".into()));
        }
        keeper
    };
    let pending = |key: &SnapshotCommitKey| sync.pending_commits.lock().unwrap().snapshots.contains_key(key);

    // Cache miss: the 404 is settled without pruning unrelated entries.
    let keeper = attach(false);
    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap(), (false, None));
    let saved: serde_json::Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert!(saved["signed_snapshots"].as_array().is_some_and(|apps| apps.iter().any(|a| a == "serverbox")));
    assert!(unrelated.iter().all(pending));

    // Cache hit: the checked entry stays until the marker is persisted, then only it goes.
    let keeper = attach(true);
    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap_err().kind, Kind::Invalid);
    assert!(pending(&hit));
    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap(), (false, None));
    assert!(!pending(&hit));
    assert!(unrelated.iter().all(pending));
}

#[tokio::test]
async fn a_replaced_remote_snapshot_settles_the_checked_entry_only_after_verification_persists() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let remote_sig = PersonalAuth::new(key.clone(), Default::default(), TestKeeper::new()).sign_snapshot("serverbox", 9, b"remote").await.signature;
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", p) if p.ends_with("/snapshot") => Response::status(200)
            .header("ETag", "\"r-e\"")
            .header("Sync-Log", "c1")
            .header("Sync-Seq", "9")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pub_key)
            .header("X-Signature", &remote_sig)
            .body("remote"),
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, Default::default(), keeper.clone()));
    sync.set_personal(Some(auth.clone()));
    let body = b"snap-body";
    let hit = (5i64, *blake3::hash(body).as_bytes());
    let unrelated = (3i64, [1u8; 32]);
    {
        let mut guard = sync.pending_commits.lock().unwrap();
        let id = guard.next_id();
        guard.snapshots.insert(unrelated, (id, SnapshotLogBinding::Unknown, "e3".into()));
        let id = guard.next_id();
        guard.snapshots.insert(hit, (id, SnapshotLogBinding::Unknown, "e5".into()));
    }
    let pending = |key: &SnapshotCommitKey| sync.pending_commits.lock().unwrap().snapshots.contains_key(key);

    keeper.fail.store(true, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap_err().kind, Kind::Invalid);
    assert!(pending(&hit), "the checked entry stays until the replacement is persisted");

    keeper.fail.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap(), (false, None));
    assert!(!pending(&hit));
    assert!(pending(&unrelated));
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("c1"));
}

#[tokio::test]
async fn a_cached_snapshot_on_another_log_than_the_observed_one_settles_nothing() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let body = b"snap-body";
    let sig = PersonalAuth::new(key.clone(), Default::default(), TestKeeper::new()).sign_snapshot("serverbox", 5, body).await.signature;
    let (_fake, sync) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", p) if p.ends_with("/snapshot") => Response::status(200)
            .header("ETag", "\"e5\"")
            .header("Sync-Log", "c1")
            .header("Sync-Seq", "5")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pub_key)
            .header("X-Signature", &sig)
            .body("snap-body"),
        _ => Response::status(404),
    })
    .await;
    let keeper = TestKeeper::new();
    let auth = Arc::new(PersonalAuth::new(key, Default::default(), keeper.clone()));
    sync.set_personal(Some(auth.clone()));
    let hit = (5i64, *blake3::hash(body).as_bytes());
    let confirmed = (3i64, [1u8; 32]);
    {
        let mut guard = sync.pending_commits.lock().unwrap();
        guard.observed_log = Some("a2".into());
        let id = guard.next_id();
        guard.snapshots.insert(confirmed, (id, SnapshotLogBinding::Confirmed("a2".into()), "e3".into()));
        let id = guard.next_id();
        guard.snapshots.insert(hit, (id, SnapshotLogBinding::Unknown, "e5".into()));
    }

    assert_eq!(sync.flush_committed_snapshot_bytes("u1", None, 5, body).await.unwrap(), (false, None));
    {
        let guard = sync.pending_commits.lock().unwrap();
        assert_eq!(guard.observed_log.as_deref(), Some("a2"), "the live observation stays");
        assert!(guard.snapshots.contains_key(&hit));
        assert!(matches!(guard.snapshots.get(&confirmed), Some((_, SnapshotLogBinding::Confirmed(l), _)) if l == "a2"));
    }
    assert_eq!(auth.signed_log_id("serverbox").await, None, "the conflicting log binds nothing");
    assert!(!keeper.saved.lock().unwrap().contains("c1"), "nor is it saved");
}

#[tokio::test]
async fn a_signature_counts_as_verified_only_when_personal_auth_checked_it() {
    let key = crate::team::identity::AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let signer = PersonalAuth::new(key.clone(), Default::default(), TestKeeper::new());
    let batch_sig = signer.sign_batch("serverbox", "k1", b"one").await.signature;
    let snap_sig = signer.sign_snapshot("serverbox", 5, b"snap").await.signature;
    let (_fake, sync) = homebase(move |r| match r.path() {
        "/v2/sync/serverbox/log" => Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "batches": [{
            "seq": 1, "size": 3, "digest": blake3::hash(b"one").to_hex().as_str(), "body": BASE64.encode(b"one"),
            "idempotency_key": "k1", "signer": "u1", "signing_key": &pub_key, "signature": &batch_sig,
        }], "head": 1, "snapshot_seq": 0, "more": false } })),
        "/v2/sync/serverbox/snapshot" => Response::status(200)
            .header("ETag", "\"e5\"")
            .header("Sync-Log", "6f1c")
            .header("Sync-Seq", "5")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pub_key)
            .header("X-Signature", &snap_sig)
            .body("snap"),
        _ => Response::status(404),
    })
    .await;
    let signed_batch = |read: &LogRead| matches!(read, LogRead::Page { batches, .. } if batches[0].signed.is_some());

    // Signature fields alone, with nothing to check them.
    let (read, verified) = sync.read_log_checked(0, None, None).await.unwrap();
    assert!(signed_batch(&read) && !verified);
    let (found, verified) = sync.download_snapshot_bytes_checked().await.unwrap();
    assert!(found.unwrap().0.signed.is_some() && !verified);

    sync.set_personal(Some(Arc::new(PersonalAuth::new(key, Default::default(), TestKeeper::new()))));
    let (read, verified) = sync.read_log_checked(0, None, None).await.unwrap();
    assert!(signed_batch(&read) && verified);
    let (found, verified) = sync.download_snapshot_bytes_checked().await.unwrap();
    assert!(found.is_some() && verified);
}
