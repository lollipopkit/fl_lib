//! Snapshots and blobs: recovery, sweeps, and what binds a blob.

use super::*;

/// Whether saved personal versions record a signed snapshot of `serverbox`.
fn snapshot_signed(versions: &Value) -> bool {
    versions["signed_snapshots"].as_array().is_some_and(|apps| apps.iter().any(|a| a == "serverbox"))
}

#[tokio::test]
async fn snapshot_persist_failure_retries_without_resending_and_sweeps_blobs() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct SnapshotTestKeeper {
        saved: Mutex<String>,
        fail_snapshot: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for SnapshotTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            let has_snap = serde_json::from_str::<Value>(&json).ok().is_some_and(|v| snapshot_signed(&v));
            if self.fail_snapshot.load(Ordering::SeqCst) && has_snap {
                return Box::pin(async { Err("snapshot watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    type StoredSnap = (Vec<u8>, Option<String>);
    let snapshot_puts = Arc::new(AtomicU64::new(0));
    let stored_snapshot: Arc<Mutex<Option<StoredSnap>>> = Arc::new(Mutex::new(None));
    let deleted_blobs = Arc::new(Mutex::new(Vec::<String>::new()));
    let head = Arc::new(AtomicU64::new(0));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let snap_puts_srv = snapshot_puts.clone();
    let stored_snap_srv = stored_snapshot.clone();
    let deleted_srv = deleted_blobs.clone();
    let head_srv = head.clone();
    let pub_key_srv = pub_key.clone();
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let header_end = loop {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(pos + 4);
                }
            };
            let Some(header_end) = header_end else { continue };
            let head_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let first_line = head_str.lines().next().unwrap_or("");
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("");
            let full_path = parts.next().unwrap_or("");
            let path = full_path.split('?').next().unwrap_or(full_path);
            let content_len: usize = head_str
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok()).flatten()
                })
                .unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }

            let req_sig = head_str
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("x-signature").then(|| v.trim().to_string())
                });
            let req_body = buf[header_end..header_end + content_len].to_vec();

            let (status, extra_headers, body_bytes): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } }).to_string().into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/log") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "code": 0, "data": { "log": "6f1c", "batches": [], "head": head_srv.load(Ordering::SeqCst), "snapshot_seq": 0, "more": false } }).to_string().into_bytes(),
                ),
                ("POST", "/v2/sync/serverbox/log") => {
                    let seq = head_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "seq": seq, "live": { "batches": seq, "bytes": 4 }, "compact": true } }).to_string().into_bytes(),
                    )
                }
                ("PUT", "/v2/sync/serverbox/snapshot") => {
                    snap_puts_srv.fetch_add(1, Ordering::SeqCst);
                    *stored_snap_srv.lock().unwrap() = Some((req_body, req_sig));
                    ("204 No Content", "ETag: \"snap-e1\"\r\n".into(), Vec::new())
                }
                ("GET", "/v2/sync/serverbox/snapshot") => match stored_snap_srv.lock().unwrap().clone() {
                    None => ("404 Not Found", String::new(), Vec::new()),
                    Some((b, sig)) => {
                        let mut hdrs = "ETag: \"snap-e1\"\r\nSync-Log: 6f1c\r\nSync-Seq: 1\r\n".to_string();
                        if let Some(s) = sig {
                            hdrs.push_str(&format!("X-Signer: u1\r\nX-Signing-Key: {pub_key_srv}\r\nX-Signature: {s}\r\n"));
                        }
                        ("200 OK", hdrs, b)
                    }
                },
                ("GET", "/v2/sync/serverbox") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": [{ "name": "op-old-dead.age", "etag": "b1", "size": 10, "updated_at": "2020-01-01T00:00:00Z" }] }).to_string().into_bytes(),
                ),
                ("DELETE", p) if p.starts_with("/v2/sync/serverbox/") => {
                    deleted_srv.lock().unwrap().push(p.trim_start_matches("/v2/sync/serverbox/").to_string());
                    ("204 No Content", String::new(), Vec::new())
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body_bytes.len()
            );
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&body_bytes).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let transport = Arc::new(crate::lkc::LkcLog { client: sync_client, account: "u1".into() });
    let log_sync = LogSync::new(d.host.clone(), transport, key);

    // 1. Append commits seq 1 (compact=true) -> snapshot PUT commits remotely,
    //    then `record_snapshot_written` fails -> surfaces Host error, blobs NOT swept yet.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);
    assert!(deleted_blobs.lock().unwrap().is_empty());
    let before_retry: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert!(!snapshot_signed(&before_retry));

    // 2. While keeper STILL fails, retrying sync MUST preserve `Error::Host`
    //    (not misclassify as `Error::Remote`) and MUST NOT resend PUT /snapshot.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);
    assert!(deleted_blobs.lock().unwrap().is_empty());

    // 3. Keeper recovers -> next sync flushes `record_snapshot_written` WITHOUT
    //    resending PUT /snapshot, records snapshot seq, and sweeps the obsolete blob.
    keeper.fail_snapshot.store(false, Ordering::SeqCst);
    log_sync.sync().await.unwrap();
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1, "committed snapshot must not be resent");
    let saved_json = keeper.saved.lock().unwrap().clone();
    let parsed: Value = serde_json::from_str(&saved_json).unwrap();
    assert!(snapshot_signed(&parsed));
    assert_eq!(*deleted_blobs.lock().unwrap(), vec!["op-old-dead.age".to_string()]);

    server.abort();
}

#[tokio::test]
async fn snapshot_recovery_defers_sweep_when_new_batches_follow_pending_seq() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct SnapshotTestKeeper {
        saved: Mutex<String>,
        fail_snapshot: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for SnapshotTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            let has_snap = serde_json::from_str::<Value>(&json).ok().is_some_and(|v| snapshot_signed(&v));
            if self.fail_snapshot.load(Ordering::SeqCst) && has_snap {
                return Box::pin(async { Err("snapshot watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    let auth_for_sign = Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key.clone(),
        fl_lkc::personal::PersonalVersions::default(),
        Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(false) }),
    ));

    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Prepare a remote batch seq 2 from another device referencing a >64 KiB
    // blob (named with Keyed naming so Device A's fresh snapshot at seq 2 keeps
    // referencing the exact same blob name) that was NOT in seq-1's snapshot.
    let mut b_clock = fl_sync::Clock::new(2);
    let b_hlc = b_clock.tick(now_ms() as u64);
    let live_blob_name = format!("op-{}.age", key.name_of(b_hlc.to_string().as_bytes()));
    let b_val = json!({ "big": "z".repeat(70 << 10) });
    let b_op = Op { c: "servers".into(), id: "from_b".into(), h: b_hlc, d: Some(json!({ "$blob": live_blob_name })) };
    let b_body = key.seal(&crate::engine::encode(&[b_op], serde_json::Map::new()).unwrap()).unwrap();
    let b_blob_plain = {
        use std::io::Write;
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(serde_json::to_vec(&b_val).unwrap().as_slice()).unwrap();
        enc.finish().unwrap()
    };
    let b_blob_sealed = key.seal(&b_blob_plain).unwrap();
    let b_blob_sig = auth_for_sign.sign_file("serverbox", &live_blob_name, 1, &b_blob_sealed).await;
    let b_idem = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let b_sig = auth_for_sign.sign_batch("serverbox", b_idem, &b_body).await;
    let b_digest = blake3::hash(&b_body).to_hex().to_string();
    let b_body_b64 = {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for c in b_body.chunks(3) {
            let n = ((c[0] as u32) << 16) | ((*c.get(1).unwrap_or(&0) as u32) << 8) | (*c.get(2).unwrap_or(&0) as u32);
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push(if c.len() > 1 { T[((n >> 6) & 63) as usize] as char } else { '=' });
            out.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
        }
        out
    };

    let snapshot_puts = Arc::new(AtomicU64::new(0));
    let snapshot_seqs = Arc::new(Mutex::new(Vec::<i64>::new()));
    let last_snap_seq = Arc::new(std::sync::atomic::AtomicI64::new(0));
    let deleted_blobs = Arc::new(Mutex::new(Vec::<String>::new()));
    let head = Arc::new(AtomicU64::new(0));
    let serve_seq2 = Arc::new(AtomicBool::new(false));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let snap_puts_srv = snapshot_puts.clone();
    let snap_seqs_srv = snapshot_seqs.clone();
    let last_snap_srv = last_snap_seq.clone();
    let deleted_srv = deleted_blobs.clone();
    let head_srv = head.clone();
    let serve_seq2_srv = serve_seq2.clone();
    let pub_key_srv = pub_key.clone();
    let rec_srv = recipient.clone();
    let b_sig_str = b_sig.signature.clone();
    let b_blob_sig_str = b_blob_sig.signature.clone();
    let live_blob_srv = live_blob_name.clone();
    let live_blob_path = format!("/v2/sync/serverbox/{live_blob_name}");
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let header_end = loop {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(pos + 4);
                }
            };
            let Some(header_end) = header_end else { continue };
            let head_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let first_line = head_str.lines().next().unwrap_or("");
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("");
            let full_path = parts.next().unwrap_or("");
            let (path, query) = full_path.split_once('?').unwrap_or((full_path, ""));
            let content_len: usize = head_str
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok()).flatten()
                })
                .unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }

            let after: i64 = query.split('&').find_map(|kv| kv.strip_prefix("after=")?.parse().ok()).unwrap_or(0);
            let (status, extra_headers, body_bytes): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pub_key_srv, "next_seq": 2, "prev_signing_key": pub_key_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/log") => {
                    let batches = if serve_seq2_srv.load(Ordering::SeqCst) && after < 2 {
                        vec![json!({
                            "seq": 2,
                            "body": b_body_b64,
                            "digest": b_digest,
                            "idempotency_key": b_idem,
                            "signer": "u1",
                            "signing_key": pub_key_srv,
                            "signature": b_sig_str,
                        })]
                    } else {
                        vec![]
                    };
                    let cur_head = if serve_seq2_srv.load(Ordering::SeqCst) { 2 } else { head_srv.load(Ordering::SeqCst) };
                    let snap_seq = last_snap_srv.load(Ordering::SeqCst);
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "batches": batches, "head": cur_head, "snapshot_seq": snap_seq, "more": false } })
                            .to_string()
                            .into_bytes(),
                    )
                }
                ("POST", "/v2/sync/serverbox/log") => {
                    let seq = head_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "seq": seq, "live": { "batches": seq, "bytes": 4 }, "compact": true } })
                            .to_string()
                            .into_bytes(),
                    )
                }
                ("PUT", "/v2/sync/serverbox/snapshot") => {
                    let req_seq = query
                        .split('&')
                        .find_map(|kv| kv.strip_prefix("seq=")?.parse::<i64>().ok())
                        .unwrap_or(0);
                    let cur_head = if serve_seq2_srv.load(Ordering::SeqCst) {
                        2i64
                    } else {
                        head_srv.load(Ordering::SeqCst) as i64
                    };
                    let prev_snap = last_snap_srv.load(Ordering::SeqCst);
                    if req_seq <= prev_snap {
                        (
                            "409 Conflict",
                            "Content-Type: application/json\r\n".into(),
                            json!({ "code": 4, "reason": "sync_snapshot_stale", "data": "" }).to_string().into_bytes(),
                        )
                    } else if req_seq <= 0 || req_seq > cur_head {
                        (
                            "422 Unprocessable Entity",
                            "Content-Type: application/json\r\n".into(),
                            json!({ "code": 4, "reason": "sync_seq_invalid", "data": "" }).to_string().into_bytes(),
                        )
                    } else {
                        last_snap_srv.store(req_seq, Ordering::SeqCst);
                        snap_seqs_srv.lock().unwrap().push(req_seq);
                        let n = snap_puts_srv.fetch_add(1, Ordering::SeqCst) + 1;
                        ("204 No Content", format!("ETag: \"snap-e{n}\"\r\nSync-Log: 6f1c\r\n"), Vec::new())
                    }
                }
                ("GET", "/v2/sync/serverbox") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": [
                        {
                            "name": live_blob_srv,
                            "etag": "b-live",
                            "size": b_blob_sealed.len(),
                            "updated_at": "2020-01-01T00:00:00Z",
                            "signer": "u1",
                            "signing_key": pub_key_srv,
                            "signature": b_blob_sig_str,
                            "version": 1
                        },
                        { "name": "op-truly-dead.age", "etag": "b-dead", "size": 10, "updated_at": "2020-01-01T00:00:00Z" }
                    ] })
                    .to_string()
                    .into_bytes(),
                ),
                ("GET", p) if p == live_blob_path => (
                    "200 OK",
                    format!(
                        "ETag: \"b-live\"\r\nX-Signer: u1\r\nX-Signing-Key: {pub_key_srv}\r\nX-Signature: {b_blob_sig_str}\r\nX-Sync-Version: 1\r\n"
                    ),
                    b_blob_sealed.clone(),
                ),
                ("PUT", p) if p == live_blob_path => {
                    ("412 Precondition Failed", String::new(), Vec::new())
                }
                ("DELETE", p) if p.starts_with("/v2/sync/serverbox/") => {
                    deleted_srv.lock().unwrap().push(p.trim_start_matches("/v2/sync/serverbox/").to_string());
                    ("204 No Content", String::new(), Vec::new())
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body_bytes.len()
            );
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&body_bytes).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(SnapshotTestKeeper { saved: Mutex::new(String::new()), fail_snapshot: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));
    let transport = Arc::new(crate::lkc::LkcLog { client: sync_client, account: "u1".into() });
    let log_sync = LogSync::new(d.host.clone(), transport, key);

    // 1. Snapshot at seq 1 commits remotely, local save fails -> deferred.
    assert!(matches!(log_sync.sync().await, Err(Error::Host(_))));
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 1);

    // 2. Meanwhile batch seq 2 arrives referencing `op-reused-live.age` (even with old timestamp).
    serve_seq2.store(true, Ordering::SeqCst);
    keeper.fail_snapshot.store(false, Ordering::SeqCst);

    // 3. Recovery sync: flushes seq 1 without resending seq-1 snapshot, reads seq 2,
    //    defers stale sweep, writes fresh snapshot at seq 2 (PUT #2), and sweeps ONLY
    //    `op-truly-dead.age` (NEVER deleting `op-reused-live.age`!).
    log_sync.sync().await.unwrap();
    assert_eq!(snapshot_puts.load(Ordering::SeqCst), 2);
    assert_eq!(*snapshot_seqs.lock().unwrap(), vec![1, 2]);
    assert_eq!(d.host.value("servers", "from_b"), Some(b_val));
    let deleted = deleted_blobs.lock().unwrap().clone();
    assert_eq!(deleted, vec!["op-truly-dead.age".to_string()]);

    server.abort();
}

#[tokio::test]
async fn engine_blob_hardening_unbound_legacy_lying_listing_and_local_refresh() {
    use crate::engine::{Core, Naming};

    // Mock signed BlobStore with configurable listing `signed` flag and blob contents.
    type MockBlobEntry = (Vec<u8>, bool, bool); // (bytes, actually_signed, listed_signed)
    #[derive(Default)]
    struct MockSignedBlobs {
        blobs: Mutex<BTreeMap<String, MockBlobEntry>>,
        gets: Mutex<Vec<String>>,
    }
    impl BlobStore for MockSignedBlobs {
        fn signs_blobs(&self) -> bool {
            true
        }
        async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
            self.blobs.lock().unwrap().entry(name).or_insert((body, true, true));
            Ok(())
        }
        async fn put_blob_signed(&self, name: String, body: Vec<u8>) -> Result<bool> {
            let mut map = self.blobs.lock().unwrap();
            if let Some((_, actual, _)) = map.get(&name) {
                return Ok(*actual);
            }
            map.insert(name, (body, true, true));
            Ok(true)
        }
        async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
            Ok(self.blobs.lock().unwrap().get(&name).map(|(b, _, _)| b.clone()))
        }
        async fn get_blob_verified(&self, name: String, retained: Option<crate::RetainedBinding<'_>>) -> Result<Option<(Vec<u8>, bool)>> {
            self.gets.lock().unwrap().push(name.clone());
            let found = self.blobs.lock().unwrap().get(&name).map(|(b, actual, _)| (b.clone(), *actual));
            if let Some((body, false)) = &found
                && retained.is_some_and(|r| !r.holds(body))
            {
                return Err(Error::Untrusted(format!("{name}: {}", crate::RETAINED_MISMATCH)));
            }
            Ok(found)
        }
        async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
            Ok(self
                .blobs
                .lock()
                .unwrap()
                .iter()
                .filter(|(k, _)| k.starts_with(&prefix))
                .map(|(k, (_, _, listed))| Listed { name: k.clone(), at: Some(1), signed: *listed })
                .collect())
        }
        async fn delete_blob(&self, name: String) -> Result<()> {
            self.blobs.lock().unwrap().remove(&name);
            Ok(())
        }
    }

    let d = Device::new("pw");
    let kf = Arc::new(MemKeyFile::default());
    let seal = d.key(&kf).await.unwrap();
    let blobs = Arc::new(MockSignedBlobs::default());
    let core = Core::new(d.host.clone(), blobs.clone(), seal.clone(), "log.", Naming::Keyed);

    // 1. Listing falsely reports `signed: true` on an unsigned blob whose body matches local op:
    //    `Sender` MUST fetch & verify the body, MUST NOT persist `log.signed_blob.<name>`,
    //    and MUST bind its ciphertext digest into `legacy_blobs` instead!
    let big_val = json!({ "payload": "x".repeat(70 << 10) });
    d.host.edit("servers", "r1", Some(big_val.clone()));
    let all = d.host.all().await.unwrap();
    let h1 = all[0].h;
    let blob_name = format!("op-{}.age", seal.name_of(h1.to_string().as_bytes()));
    let sealed_r1 = seal.seal(&crate::engine::gzip(&serde_json::to_vec(&Some(big_val.clone())).unwrap()).unwrap()).unwrap();
    let r1_hex = blake3::hash(&sealed_r1).to_hex().to_string();
    blobs.blobs.lock().unwrap().insert(blob_name.clone(), (sealed_r1.clone(), false, true));

    let (ops, complete, bindings) = core.ops_of_bound(&all).await.unwrap();
    assert!(complete);
    assert_eq!(ops.len(), 1);
    assert!(blobs.gets.lock().unwrap().contains(&blob_name), "must fetch body when listing claims signed");
    assert!(
        !d.host.lock().state.contains_key(&format!("log.signed_blob.{blob_name}")),
        "unsigned body must NOT be persisted as signed"
    );
    assert_eq!(bindings.legacy_blobs.get(&blob_name), Some(&r1_hex));

    // 2. Existing unsigned blob with MISMATCHED content while local `(h, d)` is unchanged MUST fail as Untrusted!
    let wrong_sealed = seal
        .seal(&crate::engine::gzip(&serde_json::to_vec(&Some(json!({ "payload": "y".repeat(70 << 10) }))).unwrap()).unwrap())
        .unwrap();
    blobs.blobs.lock().unwrap().insert(blob_name.clone(), (wrong_sealed.clone(), false, false));
    assert!(matches!(core.ops_of_bound(&all).await, Err(Error::Untrusted(_))));

    // 3. When local value/stamp CHANGED after `all` was snapshotted, `Sender` refreshes `(h, d)`
    //    from host and retries cleanly (uploads new signed blob under new stamp) instead of binding
    //    mismatched bytes, while preserving original `snapshot_h` so push cursors never skip
    //    intermediate edits (`r3` stamped between `h1` and `new_h`)!
    d.host.edit("servers", "r3", Some(json!({ "small": 1 })));
    let h_r3 = d.host.all().await.unwrap().into_iter().find(|r| r.id == "r3").unwrap().h;
    let updated_val = json!({ "payload": "z".repeat(70 << 10) });
    d.host.edit("servers", "r1", Some(updated_val));
    // Pass the STALE `all` (with old `h1` pointing to mismatched `blob_name`) into `ops_of_prepared`!
    let (prepared, complete2, bindings2) = core.ops_of_prepared(&all).await.unwrap();
    assert!(complete2);
    assert_eq!(prepared.len(), 1);
    let new_h = d.host.all().await.unwrap().into_iter().find(|r| r.id == "r1").unwrap().h;
    assert!(new_h > h_r3 && h_r3 > h1);
    assert_eq!(prepared[0].op.h, new_h, "emitted op carries refreshed stamp");
    assert_eq!(prepared[0].snapshot_h, h1, "push cursor stamp stays anchored to original snapshot stamp");
    let new_blob_name = format!("op-{}.age", seal.name_of(new_h.to_string().as_bytes()));
    assert_eq!(crate::engine::blob_of(&prepared[0].op.d), Some(new_blob_name.as_str()));
    assert!(d.host.lock().state.contains_key(&format!("log.signed_blob.{new_blob_name}")));
    assert!(bindings2.legacy_blobs.is_empty());

    // 4. `resolve_bound` MUST reject an unsigned blob with matching `legacy_blobs` digest when `bound_to_op` is false!
    let run = core.run().await.unwrap();
    let unbound_op = Op {
        c: "servers".into(),
        id: "unbound".into(),
        h: new_h, // does NOT match `blob_name` (which was derived from `h1`!)
        d: Some(json!({ "$blob": blob_name })),
    };
    blobs.blobs.lock().unwrap().insert(blob_name.clone(), (sealed_r1, false, false));
    let mut bad_bindings = crate::engine::BlobBindings::default();
    bad_bindings.legacy_blobs.insert(blob_name.clone(), r1_hex);
    let err = core
        .apply_bound(&run, Some((vec![unbound_op], bad_bindings)), true, vec![], false)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Untrusted(_)));
}

// Recovered snapshot: the transport's resolved log binding wins over the one
// captured when the watermark save failed.

struct ResolvingLog {
    inner: Arc<MemLog>,
    /// The `log` the next `put_snapshot` reports in its persist failure,
    /// after committing remotely.
    fail_put: Mutex<Option<Option<String>>>,
    resolved: Option<String>,
    puts: AtomicU64,
}

impl BlobStore for ResolvingLog {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.inner.put_blob(name, body).await
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        self.inner.get_blob(name).await
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        self.inner.blobs(prefix).await
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.inner.delete_blob(name).await
    }
}

impl LogTransport for ResolvingLog {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        self.inner.append(key, body).await
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        self.inner.read(after, log).await
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        self.puts.fetch_add(1, Ordering::SeqCst);
        let written = self.inner.put_snapshot(seq, body).await?;
        match self.fail_put.lock().unwrap().take() {
            Some(log) => Err(Error::SnapshotPersistFailed { log, seq, detail: "watermark save failed".into() }),
            None => Ok(written),
        }
    }

    async fn flush_committed_snapshot(&self, _log: Option<String>, _seq: i64, _body: Vec<u8>) -> Result<(bool, Option<String>)> {
        Ok((true, self.resolved.clone()))
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        self.inner.snapshot().await
    }
}

/// Snapshot puts after recovery, and whether the stale blob was swept by the
/// recovered snapshot (without writing a fresh one).
async fn recover_snapshot(captured: Option<&str>, resolved: Option<&str>) -> (u64, bool) {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let inner = MemLog::new();
    inner.lock().compact_after = 1;
    let transport = Arc::new(ResolvingLog {
        inner: inner.clone(),
        fail_put: Mutex::new(Some(captured.map(str::to_string))),
        resolved: resolved.map(str::to_string),
        puts: AtomicU64::new(0),
    });
    let sync = LogSync::new(d.host.clone(), transport.clone(), d.key(&file).await.unwrap());
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(transport.puts.load(Ordering::SeqCst), 1);
    inner.lock().blobs.insert("op-dead.age".into(), (b"x".to_vec(), 0));
    sync.sync().await.unwrap();
    (transport.puts.load(Ordering::SeqCst), !inner.lock().blobs.contains_key("op-dead.age"))
}

#[tokio::test]
async fn recovered_snapshot_prefers_resolved_log_over_captured() {
    // Captured binding stale, resolved one matches the local cursor's log:
    // the recovered snapshot covers it, so it sweeps without a fresh write.
    assert_eq!(recover_snapshot(Some("log-stale"), Some("log-1")).await, (1, true));
    // Captured binding matches, resolved one is another log: no sweep on the
    // recovered binding; a fresh snapshot is attempted instead.
    assert_eq!(recover_snapshot(Some("log-1"), Some("log-recreated")).await, (2, false));
    // No resolved binding: the captured one is kept.
    assert_eq!(recover_snapshot(Some("log-1"), None).await, (1, true));
}

struct BlobLockedLog {
    inner: Arc<MemLog>,
    /// Whether the snapshot there reads as verified signed.
    snapshot_signed: bool,
}

impl BlobStore for BlobLockedLog {
    fn signs_blobs(&self) -> bool {
        true
    }

    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.inner.put_blob(name, body).await
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        self.inner.get_blob(name).await
    }

    async fn get_blob_verified(&self, name: String, retained: Option<crate::RetainedBinding<'_>>) -> Result<Option<(Vec<u8>, bool)>> {
        let Some(body) = self.inner.get_blob(name.clone()).await? else {
            return Ok(None);
        };
        match retained {
            None => Err(Error::Untrusted(format!("{name}: server stripped signature"))),
            Some(binding) if !binding.holds(&body) => Err(Error::Untrusted(format!("{name}: {}", crate::RETAINED_MISMATCH))),
            Some(_) => Ok(Some((body, false))),
        }
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        self.inner.blobs(prefix).await
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.inner.delete_blob(name).await
    }
}

impl LogTransport for BlobLockedLog {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        self.inner.append(key, body).await
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        self.inner.read(after, log).await
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        self.inner.put_snapshot(seq, body).await
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        Ok(self.inner.snapshot().await?.map(|s| SnapshotBody { signed: self.snapshot_signed, ..s }))
    }
}

#[tokio::test]
async fn pre_signing_batch_blob_is_bound_by_its_digest_or_a_covering_signed_snapshot() {
    let file = Arc::new(MemKeyFile::default());
    let big = json!({ "payload": "p".repeat(70 << 10) });
    // A pre-signing device writes batch 1 naming an unsigned blob, no digest beside it.
    let writer = Device::new("pw");
    let key = writer.key(&file).await.unwrap();
    let inner = MemLog::new();
    writer.host.edit("servers", "pre", Some(big.clone()));
    writer.log(&inner, &file).await.sync().await.unwrap();
    let (blob_name, original) = inner.lock().blobs.iter().map(|(n, (b, _))| (n.clone(), b.clone())).next().unwrap();
    let original_batch = inner.lock().batches[0].2.clone();
    let (ops, doc) = crate::engine::parse(&key.open(&original_batch).unwrap()).unwrap();
    assert!(!doc.contains_key("legacy_blobs"));
    let digest_extra = |hex: String| {
        let mut extra = serde_json::Map::new();
        extra.insert("legacy_blobs".into(), json!({ blob_name.clone(): hex }));
        extra
    };
    let reseal = |b: &[u8]| key.seal(&key.open(b).unwrap()).unwrap();

    let read = |snapshot_signed: bool| {
        let inner = inner.clone();
        let file = file.clone();
        async move {
            let dev = Device::new("pw");
            let transport = Arc::new(BlobLockedLog { inner, snapshot_signed });
            let res = LogSync::new(dev.host.clone(), transport, dev.key(&file).await.unwrap()).pull().await;
            (res, dev.host.value("servers", "pre"))
        }
    };
    let set_blob = |b: Vec<u8>| inner.lock().blobs.get_mut(&blob_name).unwrap().0 = b;
    let mismatch = format!("{blob_name}: {}", crate::RETAINED_MISMATCH);

    // No binding anywhere: refused, never read unbound.
    let (res, value) = read(true).await;
    assert!(matches!(res, Err(Error::Untrusted(d)) if d.ends_with("server stripped signature")));
    assert_eq!(value, None);

    // A signed snapshot covering batch 1 binds the blob: readable, and other bytes are refused.
    let covering = key.seal(&crate::engine::encode(&ops, digest_extra(blake3::hash(&original).to_hex().to_string())).unwrap()).unwrap();
    inner.lock().snapshot = Some((1, covering.clone()));
    let (res, value) = read(true).await;
    res.unwrap();
    assert_eq!(value, Some(big.clone()));
    set_blob(reseal(&original));
    assert!(matches!(read(true).await.0, Err(Error::Untrusted(d)) if d == mismatch));
    set_blob(original.clone());
    // Unsigned, the snapshot binds nothing.
    assert!(matches!(read(false).await.0, Err(Error::Untrusted(d)) if d.ends_with("server stripped signature")));

    // A covering signed snapshot that does not name the blob: a later op replaced it.
    let replaced = vec![Op { d: Some(json!({ "small": 1 })), ..ops[0].clone() }];
    inner.lock().snapshot = Some((1, key.seal(&crate::engine::encode(&replaced, serde_json::Map::new()).unwrap()).unwrap()));
    let (res, value) = read(true).await;
    res.unwrap();
    assert_eq!(value, None);

    // The unsigned batch's own digest binds it as far as the batch is trusted.
    inner.lock().snapshot = None;
    inner.lock().batches[0].2 = key.seal(&crate::engine::encode(&ops, digest_extra(blake3::hash(&original).to_hex().to_string())).unwrap()).unwrap();
    let (res, value) = read(true).await;
    res.unwrap();
    assert_eq!(value, Some(big));
    set_blob(reseal(&original));
    assert!(matches!(read(true).await.0, Err(Error::Untrusted(d)) if d == mismatch));
}

/// A store that signs nothing, whose snapshot cannot be read.
struct SnapshotDownLog(Arc<MemLog>);

impl BlobStore for SnapshotDownLog {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.0.put_blob(name, body).await
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        self.0.get_blob(name).await
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        self.0.blobs(prefix).await
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.0.delete_blob(name).await
    }
}

impl LogTransport for SnapshotDownLog {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        self.0.append(key, body).await
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        self.0.read(after, log).await
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        self.0.put_snapshot(seq, body).await
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        Err(Error::Remote("snapshot unavailable".into()))
    }
}

#[tokio::test]
async fn an_unsigned_batch_blob_on_a_store_that_signs_nothing_needs_no_snapshot() {
    let file = Arc::new(MemKeyFile::default());
    let big = json!({ "payload": "p".repeat(70 << 10) });
    let writer = Device::new("pw");
    let inner = MemLog::new();
    writer.host.edit("servers", "pre", Some(big.clone()));
    writer.log(&inner, &file).await.sync().await.unwrap();
    assert!(!inner.lock().blobs.is_empty());

    let reader = Device::new("pw");
    let log = LogSync::new(reader.host.clone(), Arc::new(SnapshotDownLog(inner)), reader.key(&file).await.unwrap());
    log.pull().await.unwrap();
    assert_eq!(reader.host.value("servers", "pre"), Some(big));
}
