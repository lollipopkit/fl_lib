//! The key file and the log on LK Cloud.

use super::*;

#[tokio::test]
async fn lkc_key_file_persist_failure_reconciles_and_retries_without_resending_put() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    struct KeyFileTestKeeper {
        saved: Mutex<String>,
        fail: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for KeyFileTestKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            if self.fail.load(Ordering::SeqCst) {
                return Box::pin(async { Err("key file watermark save failed".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    type StoredKeyFile = (Vec<u8>, String, String, String);
    let stored_file: Arc<Mutex<Option<StoredKeyFile>>> = Arc::new(Mutex::new(None));
    let puts = Arc::new(AtomicU64::new(0));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let file_srv = stored_file.clone();
    let puts_srv = puts.clone();
    let pub_srv = pub_key.clone();
    let rec_srv = recipient.clone();
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
            let path = parts.next().unwrap_or("").split('?').next().unwrap_or("");
            let hdr = |name: &str| {
                head_str.lines().find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
                })
            };
            let content_len: usize = hdr("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }
            let body = buf[header_end..header_end + content_len].to_vec();

            let (status, extra_headers, resp_body): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pub_srv, "next_seq": 2, "prev_signing_key": pub_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/identity.age") => {
                    let guard = file_srv.lock().unwrap();
                    match guard.as_ref() {
                        Some((bytes, etag, ver, sig)) => (
                            "200 OK",
                            format!(
                                "ETag: \"{etag}\"\r\nX-Signer: u1\r\nX-Signing-Key: {pub_srv}\r\nX-Signature: {sig}\r\nX-Sync-Version: {ver}\r\n"
                            ),
                            bytes.clone(),
                        ),
                        None => ("404 Not Found", String::new(), Vec::new()),
                    }
                }
                ("PUT", "/v2/sync/serverbox/identity.age") => {
                    let n = puts_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    let mut guard = file_srv.lock().unwrap();
                    let ok = if hdr("if-none-match").as_deref() == Some("*") {
                        guard.is_none()
                    } else if let Some(im) = hdr("if-match") {
                        guard.as_ref().is_some_and(|(_, e, _, _)| format!("\"{e}\"") == im)
                    } else {
                        // A key-file write is always conditional.
                        false
                    };
                    if !ok {
                        ("412 Precondition Failed", String::new(), Vec::new())
                    } else {
                        let etag = format!("kf-e{n}");
                        let ver = hdr("x-sync-version").unwrap_or_else(|| "1".into());
                        let sig = hdr("x-signature").unwrap_or_default();
                        *guard = Some((body, etag.clone(), ver, sig));
                        ("204 No Content", format!("ETag: \"{etag}\"\r\n"), Vec::new())
                    }
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!(
                "HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                resp_body.len()
            );
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&resp_body).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper = Arc::new(KeyFileTestKeeper { saved: Mutex::new(String::new()), fail: AtomicBool::new(true) });
    let auth = Arc::new(fl_lkc::personal::PersonalAuth::new(account_key, fl_lkc::personal::PersonalVersions::default(), keeper.clone()));
    sync_client.set_personal(Some(auth));

    let kf = Arc::new(crate::lkc::LkcKeyFile { client: sync_client, account: "u1".into() });
    let d = Device::new("pw1");

    // 1. Create identity.age: remote PUT commits, local signing watermark fails ->
    //    surfaces Host error, reconciles local epoch=0 + 2fa marker immediately.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 1);
    assert_eq!(d.secrets.epochs.lock().unwrap().get("u1"), Some(&0));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("2fa:u1"), Some(&1));
    assert!(keeper.saved.lock().unwrap().is_empty());

    // 2. Retrying while keeper still fails MUST NOT resend PUT.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 1);

    // 3. Keeper recovers -> retry flushes local watermark WITHOUT resending PUT
    //    and opens the key cleanly.
    keeper.fail.store(false, Ordering::SeqCst);
    let key = d.ring.of(kf.clone(), true).await.unwrap();
    assert_eq!(puts.load(Ordering::SeqCst), 1, "committed key-file PUT must not be resent");
    let saved: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(saved["files"]["serverbox/identity.age"], json!(1));
    assert_eq!(key.open(&key.seal(b"kf-ok").unwrap()).unwrap(), b"kf-ok");

    // 4. `rotate()` hitting `KeyFilePersistFailed` clears `opened`/`checked_at` so an
    //    immediate non-forced `check(false, true)` flushes the watermark WITHOUT
    //    being bypassed by the 60s cache and WITHOUT resending PUT.
    keeper.fail.store(true, Ordering::SeqCst);
    assert!(matches!(key.rotate().await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 2);
    assert!(matches!(key.check(false, true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 2);
    keeper.fail.store(false, Ordering::SeqCst);
    key.check(false, true).await.unwrap();
    assert_eq!(puts.load(Ordering::SeqCst), 2, "rotate retry must not resend PUT");
    let saved2: Value = serde_json::from_str(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(saved2["files"]["serverbox/identity.age"], json!(2));

    server.abort();
}

#[tokio::test]
async fn active_key_pending_write_blocks_conflicting_import_and_flushes_across_auth_rebind() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _state: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }
    struct ToggleKeeper {
        saved: Mutex<String>,
        fail: AtomicBool,
    }
    impl fl_lkc::personal::VersionKeeper for ToggleKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            if self.fail.load(Ordering::SeqCst) {
                return Box::pin(async { Err("keeper unavailable".into()) });
            }
            *self.saved.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();
    type StoredKeyFile = (Vec<u8>, String, String, String);
    let stored_file: Arc<Mutex<Option<StoredKeyFile>>> = Arc::new(Mutex::new(None));
    let puts = Arc::new(AtomicU64::new(0));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let file_srv = stored_file.clone();
    let puts_srv = puts.clone();
    let pub_srv = pub_key.clone();
    let rec_srv = recipient.clone();
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
            let mut parts = head_str.lines().next().unwrap_or("").split_whitespace();
            let method = parts.next().unwrap_or("");
            let path = parts.next().unwrap_or("").split('?').next().unwrap_or("");
            let hdr = |name: &str| {
                head_str.lines().find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
                })
            };
            let content_len: usize = hdr("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }
            let body = buf[header_end..header_end + content_len].to_vec();

            let (status, extra_headers, resp_body): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pub_srv, "next_seq": 2, "prev_signing_key": pub_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox/identity.age") => {
                    let guard = file_srv.lock().unwrap();
                    match guard.as_ref() {
                        Some((bytes, etag, ver, sig)) => (
                            "200 OK",
                            format!("ETag: \"{etag}\"\r\nX-Signer: u1\r\nX-Signing-Key: {pub_srv}\r\nX-Signature: {sig}\r\nX-Sync-Version: {ver}\r\n"),
                            bytes.clone(),
                        ),
                        None => ("404 Not Found", String::new(), Vec::new()),
                    }
                }
                ("PUT", "/v2/sync/serverbox/identity.age") => {
                    let n = puts_srv.fetch_add(1, Ordering::SeqCst) + 1;
                    let mut guard = file_srv.lock().unwrap();
                    let ok = if hdr("if-none-match").as_deref() == Some("*") {
                        guard.is_none()
                    } else if let Some(im) = hdr("if-match") {
                        guard.as_ref().is_some_and(|(_, e, _, _)| format!("\"{e}\"") == im)
                    } else {
                        false
                    };
                    if !ok {
                        ("412 Precondition Failed", String::new(), Vec::new())
                    } else {
                        let etag = format!("kf-e{n}");
                        let ver = hdr("x-sync-version").unwrap_or_else(|| "1".into());
                        let sig = hdr("x-signature").unwrap_or_default();
                        *guard = Some((body, etag.clone(), ver, sig));
                        ("204 No Content", format!("ETag: \"{etag}\"\r\n"), Vec::new())
                    }
                }
                _ => ("404 Not Found", String::new(), Vec::new()),
            };
            let head_out = format!("HTTP/1.1 {status}\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n", resp_body.len());
            let _ = stream.write_all(head_out.as_bytes()).await;
            let _ = stream.write_all(&resp_body).await;
        }
    });

    let base = format!("http://{addr}");
    let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
    let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
    let sync_client = Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"));
    let keeper1 = Arc::new(ToggleKeeper { saved: Mutex::new(String::new()), fail: AtomicBool::new(true) });
    let auth1 = Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key.clone(),
        fl_lkc::personal::PersonalVersions::default(),
        keeper1,
    ));
    sync_client.set_personal(Some(auth1));

    let kf = Arc::new(crate::lkc::LkcKeyFile { client: sync_client.clone(), account: "u1".into() });
    let d = Device::new("pw1");
    let active_a = d.secrets.secret_key.lock().unwrap().clone().unwrap();
    let other_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // 1. PUT commits under active key A (no staged key), local watermark save fails -> retains `pending_write`.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert_eq!(puts.load(Ordering::SeqCst), 1);
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());

    // 2. Replacing active key A with B while `pending_write` is outstanding MUST be rejected,
    //    while same-key import A succeeds.
    assert!(d.ring.store_secret_key(&other_b).await.is_err());
    d.ring.store_secret_key(&active_a).await.unwrap();

    // 3. Detaching personal auth AND releasing `"u1"` clears `SyncClient::pending_commits`
    //    and drops the registered `SyncKey` handle, yet `KeyTable::pending_writes` MUST retain
    //    the unpersisted watermark and keep blocking conflicting secret-key replacement.
    d.ring.release("u1");
    assert!(d.ring.store_secret_key(&other_b).await.is_err());
    sync_client.set_personal(None);
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::SignedOut)));
    assert_eq!(puts.load(Ordering::SeqCst), 1);
    assert!(d.ring.store_secret_key(&other_b).await.is_err());

    // 4. Rebinding a fresh `PersonalAuth` for the same user `u1` flushes the committed
    //    watermark directly without resending PUT, then clears `pending_write`.
    let keeper2 = Arc::new(ToggleKeeper { saved: Mutex::new(String::new()), fail: AtomicBool::new(false) });
    let auth2 = Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key,
        fl_lkc::personal::PersonalVersions::default(),
        keeper2.clone(),
    ));
    sync_client.set_personal(Some(auth2));
    let opened = d.ring.of(kf, true).await.unwrap();
    assert_eq!(puts.load(Ordering::SeqCst), 1, "watermark flush after auth rebind must not resend PUT");
    let saved: Value = serde_json::from_str(&keeper2.saved.lock().unwrap()).unwrap();
    assert_eq!(saved["files"]["serverbox/identity.age"], json!(1));
    assert_eq!(opened.open(&opened.seal(b"ok").unwrap()).unwrap(), b"ok");

    // Once `pending_write` has settled, replacing active key A with B is allowed.
    d.ring.store_secret_key(&other_b).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(other_b.as_str()));

    server.abort();
}

#[tokio::test]
async fn lkc_retained_pre_signing_blob_remains_readable_while_stripped_signed_blob_is_rejected() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let account_key = fl_lkc::team::identity::AccountKey::generate("u1");
    let pub_key = account_key.signing_public();
    let recipient = account_key.recipient();

    type SigTriple = Option<(String, String, String)>;
    type StoredBlob = (Vec<u8>, SigTriple);
    type StoredBatch = (i64, String, Vec<u8>, SigTriple);
    type StoredSnapshot = (i64, Vec<u8>, SigTriple);
    let blobs: Arc<Mutex<BTreeMap<String, StoredBlob>>> = Arc::new(Mutex::new(BTreeMap::new()));
    let batches: Arc<Mutex<Vec<StoredBatch>>> = Arc::new(Mutex::new(Vec::new()));
    let snapshot: Arc<Mutex<Option<StoredSnapshot>>> = Arc::new(Mutex::new(None));
    let strip_blob: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    let blobs_srv = blobs.clone();
    let batches_srv = batches.clone();
    let snap_srv = snapshot.clone();
    let strip_srv = strip_blob.clone();
    let pk_srv = pub_key.clone();
    let rec_srv = recipient.clone();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
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
            let find_hdr = |name: &str| -> Option<String> {
                head_str.lines().find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
                })
            };
            let content_len: usize = find_hdr("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            while buf.len() < header_end + content_len {
                let n = match stream.read(&mut tmp).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                buf.extend_from_slice(&tmp[..n]);
            }
            let req_body = buf[header_end..header_end + content_len].to_vec();
            let sig_tuple = find_hdr("x-signature").map(|sig| {
                let ver = find_hdr("x-sync-version").unwrap_or_default();
                ("u1".to_string(), pk_srv.clone(), format!("{sig}|{ver}"))
            });

            let (status, extra_headers, body_bytes): (&str, String, Vec<u8>) = match (method, path) {
                ("GET", "/v2/keys") => (
                    "200 OK",
                    "Content-Type: application/json\r\n".into(),
                    json!({ "data": { "recipient": rec_srv, "signing_key": pk_srv, "next_seq": 2, "prev_signing_key": pk_srv } })
                        .to_string()
                        .into_bytes(),
                ),
                ("GET", "/v2/sync/serverbox") => {
                    let list: Vec<Value> = blobs_srv
                        .lock()
                        .unwrap()
                        .iter()
                        .map(|(name, (b, sig))| {
                            let mut obj = json!({
                                "name": name,
                                "etag": "e1",
                                "size": b.len(),
                                "updated_at": "2025-01-01T00:00:00Z",
                            });
                            if let Some((signer, pk, sig_ver)) = sig {
                                let (s, v) = sig_ver.split_once('|').unwrap_or((sig_ver, ""));
                                obj["signer"] = json!(signer);
                                obj["signing_key"] = json!(pk);
                                obj["signature"] = json!(s);
                                if let Ok(vn) = v.parse::<i64>() {
                                    obj["version"] = json!(vn);
                                }
                            }
                            obj
                        })
                        .collect();
                    ("200 OK", "Content-Type: application/json\r\n".into(), json!({ "data": list }).to_string().into_bytes())
                }
                ("PUT", "/v2/sync/serverbox/snapshot") => {
                    let seq: i64 = query.split('&').find_map(|kv| kv.strip_prefix("seq=")?.parse().ok()).unwrap_or(1);
                    *snap_srv.lock().unwrap() = Some((seq, req_body, sig_tuple));
                    ("204 No Content", "ETag: \"snap-1\"\r\nSync-Log: 6f1c\r\n".into(), Vec::new())
                }
                ("GET", "/v2/sync/serverbox/snapshot") => match snap_srv.lock().unwrap().clone() {
                    None => ("404 Not Found", String::new(), Vec::new()),
                    Some((seq, b, sig)) => {
                        let mut hdrs = format!("ETag: \"snap-1\"\r\nSync-Log: 6f1c\r\nSync-Seq: {seq}\r\n");
                        if let Some((signer, pk, sig_ver)) = sig {
                            let (s, _) = sig_ver.split_once('|').unwrap_or((&sig_ver, ""));
                            hdrs.push_str(&format!("X-Signer: {signer}\r\nX-Signing-Key: {pk}\r\nX-Signature: {s}\r\n"));
                        }
                        ("200 OK", hdrs, b)
                    }
                },
                ("POST", "/v2/sync/serverbox/log") => {
                    let idem = find_hdr("idempotency-key").unwrap_or_default();
                    let mut bs = batches_srv.lock().unwrap();
                    let seq = bs.len() as i64 + 1;
                    let compact = seq >= 2;
                    bs.push((seq, idem, req_body, sig_tuple));
                    (
                        "200 OK",
                        "Content-Type: application/json\r\n".into(),
                        json!({ "code": 0, "data": { "log": "6f1c", "seq": seq, "live": { "batches": seq, "bytes": 4 }, "compact": compact } })
                            .to_string()
                            .into_bytes(),
                    )
                }
                ("GET", "/v2/sync/serverbox/log") => {
                    let after: i64 = query.split('&').find_map(|kv| kv.strip_prefix("after=")?.parse().ok()).unwrap_or(0);
                    let snap_seq = snap_srv.lock().unwrap().as_ref().map_or(0, |(s, _, _)| *s);
                    if after == 0 && snap_seq > 0 {
                        (
                            "410 Gone",
                            "Content-Type: application/json\r\nSync-Log: 6f1c\r\nSync-Snapshot-Seq: 2\r\n".into(),
                            json!({ "code": 4, "reason": "sync_compacted", "data": "" }).to_string().into_bytes(),
                        )
                    } else {
                        let bs = batches_srv.lock().unwrap();
                        let head = bs.len() as i64;
                        let out: Vec<Value> = bs
                            .iter()
                            .filter(|(s, _, _, _)| *s > after)
                            .map(|(s, idem, b, sig)| {
                                const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                                let mut b64 = String::new();
                                for c in b.chunks(3) {
                                    let n = ((c[0] as u32) << 16) | ((*c.get(1).unwrap_or(&0) as u32) << 8) | (*c.get(2).unwrap_or(&0) as u32);
                                    b64.push(T[((n >> 18) & 63) as usize] as char);
                                    b64.push(T[((n >> 12) & 63) as usize] as char);
                                    b64.push(if c.len() > 1 { T[((n >> 6) & 63) as usize] as char } else { '=' });
                                    b64.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
                                }
                                let dig = blake3::hash(b).to_hex().to_string();
                                let mut obj = json!({ "seq": s, "body": b64, "digest": dig, "idempotency_key": idem });
                                if let Some((signer, pk, sig_ver)) = sig {
                                    let (sv, _) = sig_ver.split_once('|').unwrap_or((sig_ver, ""));
                                    obj["signer"] = json!(signer);
                                    obj["signing_key"] = json!(pk);
                                    obj["signature"] = json!(sv);
                                }
                                obj
                            })
                            .collect();
                        (
                            "200 OK",
                            "Content-Type: application/json\r\n".into(),
                            json!({ "code": 0, "data": { "log": "6f1c", "batches": out, "head": head, "snapshot_seq": snap_seq, "more": false } })
                                .to_string()
                                .into_bytes(),
                        )
                    }
                }
                ("PUT", p) if p.starts_with("/v2/sync/serverbox/op-") => {
                    let name = p.trim_start_matches("/v2/sync/serverbox/").to_string();
                    let mut map = blobs_srv.lock().unwrap();
                    if let std::collections::btree_map::Entry::Vacant(e) = map.entry(name) {
                        e.insert((req_body, sig_tuple));
                        ("204 No Content", "ETag: \"b1\"\r\n".into(), Vec::new())
                    } else {
                        ("412 Precondition Failed", String::new(), Vec::new())
                    }
                }
                ("GET", p) if p.starts_with("/v2/sync/serverbox/op-") => {
                    let name = p.trim_start_matches("/v2/sync/serverbox/");
                    let stripped = strip_srv.lock().unwrap().as_deref() == Some(name);
                    match blobs_srv.lock().unwrap().get(name).cloned() {
                        None => ("404 Not Found", String::new(), Vec::new()),
                        Some((b, sig)) => {
                            let mut hdrs = "ETag: \"b1\"\r\n".to_string();
                            if !stripped
                                && let Some((signer, pk, sig_ver)) = sig
                            {
                                let (sv, v) = sig_ver.split_once('|').unwrap_or((&sig_ver, "1"));
                                hdrs.push_str(&format!("X-Signer: {signer}\r\nX-Signing-Key: {pk}\r\nX-Signature: {sv}\r\nX-Sync-Version: {v}\r\n"));
                            }
                            ("200 OK", hdrs, b)
                        }
                    }
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

    struct SimpleKeeper(Mutex<String>);
    impl fl_lkc::personal::VersionKeeper for SimpleKeeper {
        fn save(&self, json: String) -> fl_lkc::personal::BoxFuture<'_, std::result::Result<(), String>> {
            *self.0.lock().unwrap() = json;
            Box::pin(async { Ok(()) })
        }
    }

    struct MemSessionStore;
    impl fl_lkc::Store for MemSessionStore {
        async fn save(&self, _: Option<fl_lkc::Stored>) -> std::result::Result<(), String> {
            Ok(())
        }
    }

    let base = format!("http://{addr}");
    let make_client = || async {
        let client = Arc::new(fl_lkc::Client::with(&format!("{base}/auth/v1/"), "app", &base).unwrap());
        let stored = fl_lkc::Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
        let session = Arc::new(fl_lkc::Session::restore(client, MemSessionStore, Some(stored)).await);
        Arc::new(fl_lkc::sync::SyncClient::new(session, "serverbox"))
    };

    let key_file = Arc::new(MemKeyFile::default());
    let dev_a = Device::new("pw");
    let sk_a = dev_a.secrets.secret_key.lock().unwrap().clone();
    let sync_key_a = dev_a.key(&key_file).await.unwrap();
    let client_a = make_client().await;
    let log_a = LogSync::new(dev_a.host.clone(), Arc::new(crate::lkc::LkcLog { client: client_a.clone(), account: "u1".into() }), sync_key_a);

    // 1. Pre-signing: Device A uploads large record `pre` (>64 KiB) UNSIGNED at seq 1.
    let pre_val = json!({ "a": 1, "payload": "p".repeat(70 << 10) });
    dev_a.host.edit("servers", "pre", Some(pre_val.clone()));
    log_a.sync().await.unwrap();
    assert_eq!(blobs.lock().unwrap().len(), 1);
    let pre_blob_name = blobs.lock().unwrap().keys().next().unwrap().clone();

    // Simulate host model re-serialization changing JSON key order (semantically equal value)
    // without bumping HLC, plus clear `log.legacy_blobs` cache so `Sender` exercises remote
    // ciphertext binding on compaction!
    dev_a.host.lock().state.remove("log.legacy_blobs");
    if let Some((_, val)) = dev_a.host.lock().records.get_mut(&("servers".into(), "pre".into())) {
        *val = Some(json!({ "payload": "p".repeat(70 << 10), "a": 1 }));
    }

    // 2. Post-signing: attach PersonalAuth, upload large record `post` SIGNED at seq 2 (triggers signed snapshot covering `pre` + `post`!).
    let auth_a = Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key.clone(),
        fl_lkc::personal::PersonalVersions::default(),
        Arc::new(SimpleKeeper(Mutex::new(String::new()))),
    ));
    client_a.set_personal(Some(auth_a));
    let post_val = json!({ "payload": "s".repeat(70 << 10) });
    dev_a.host.edit("servers", "post", Some(post_val.clone()));
    log_a.sync().await.unwrap();
    let post_blob_name = blobs.lock().unwrap().keys().find(|k| *k != &pre_blob_name).unwrap().clone();
    assert!(dev_a.host.lock().state.contains_key(&format!("log.signed_blob.{post_blob_name}")));
    assert!(!dev_a.host.lock().state.contains_key("log.signed_blobs"));

    // Seed an unbound unsigned `op-def.age` on the server as well.
    blobs.lock().unwrap().insert("op-def.age".into(), (b"age-encryption.org/v1\n---\nx\n".to_vec(), None));

    // 3. Device B (with `signed_blobs` active, ordinary files not locked to signed-only) reads
    //    the compacted signed snapshot: `pre_blob_name` (unsigned pre-signing blob retained by
    //    snapshot) MUST remain readable with its original remote ciphertext content, while direct
    //    unbound `download_blob_bytes("op-def.age")` MUST remain `Kind::Untrusted`!
    let dev_b = Device::new("pw");
    *dev_b.secrets.secret_key.lock().unwrap() = sk_a.clone();
    let sync_key_b = dev_b.key(&key_file).await.unwrap();
    let client_b = make_client().await;
    let keeper_b = Arc::new(SimpleKeeper(Mutex::new(String::new())));
    let init_b = fl_lkc::personal::PersonalVersions::from_json(r#"{"v":2,"signed_blobs":["serverbox"]}"#).unwrap();
    client_b.set_personal(Some(Arc::new(fl_lkc::personal::PersonalAuth::new(account_key.clone(), init_b.clone(), keeper_b))));
    assert_eq!(client_b.download_blob_bytes("op-def.age").await.unwrap_err().kind, fl_lkc::sync::Kind::Untrusted);
    let log_b = LogSync::new(dev_b.host.clone(), Arc::new(crate::lkc::LkcLog { client: client_b, account: "u1".into() }), sync_key_b);
    log_b.sync().await.unwrap();
    assert_eq!(dev_b.host.value("servers", "pre"), Some(pre_val.clone()));
    assert_eq!(dev_b.host.value("servers", "post"), Some(post_val));

    // 3b. Device B2 with `signed_apps` active (ordinary files locked to signed-only) still reads
    //     the retained pre-signing blob the signed snapshot binds by digest, and its own join
    //     re-binds (migrates) it into the batches and snapshot it writes.
    let dev_b2 = Device::new("pw");
    *dev_b2.secrets.secret_key.lock().unwrap() = sk_a.clone();
    let sync_key_b2 = dev_b2.key(&key_file).await.unwrap();
    let seal_b2 = sync_key_b2.clone();
    let signed_apps_auth = || {
        let init = fl_lkc::personal::PersonalVersions::from_json(r#"{"v":2,"signed_apps":["serverbox"],"signed_blobs":["serverbox"]}"#).unwrap();
        Arc::new(fl_lkc::personal::PersonalAuth::new(account_key.clone(), init, Arc::new(SimpleKeeper(Mutex::new(String::new())))))
    };
    let client_b2 = make_client().await;
    client_b2.set_personal(Some(signed_apps_auth()));
    let log_b2 = LogSync::new(dev_b2.host.clone(), Arc::new(crate::lkc::LkcLog { client: client_b2, account: "u1".into() }), sync_key_b2);
    let snapshot_before_b2 = snapshot.lock().unwrap().clone();
    log_b2.sync().await.unwrap();
    assert_eq!(dev_b2.host.value("servers", "pre"), Some(pre_val.clone()));
    assert!(dev_b2.host.lock().state.get("log.legacy_blobs").is_some_and(|raw| raw.contains(&pre_blob_name)));

    // B2 wrote the signed snapshot now on the server, binding `pre` to its original ciphertext.
    let original_pre = blobs.lock().unwrap().get(&pre_blob_name).cloned().unwrap();
    let b2_snapshot = snapshot.lock().unwrap().clone().unwrap();
    assert_ne!(Some(&b2_snapshot), snapshot_before_b2.as_ref());
    assert!(b2_snapshot.2.is_some());
    let (_, b2_doc) = crate::engine::parse(&seal_b2.open(&b2_snapshot.1).unwrap()).unwrap();
    assert_eq!(b2_doc["legacy_blobs"][&pre_blob_name], json!(blake3::hash(&original_pre.0).to_hex().to_string()));

    // A fresh `signed_apps` reader pulls B2's snapshot (writing none) with the original ciphertext...
    let fresh_reader = || async {
        let dev = Device::new("pw");
        *dev.secrets.secret_key.lock().unwrap() = sk_a.clone();
        let sync_key = dev.key(&key_file).await.unwrap();
        let client = make_client().await;
        client.set_personal(Some(signed_apps_auth()));
        let log = LogSync::new(dev.host.clone(), Arc::new(crate::lkc::LkcLog { client, account: "u1".into() }), sync_key);
        (dev, log)
    };
    let (dev_b3, log_b3) = fresh_reader().await;
    log_b3.pull().await.unwrap();
    assert_eq!(dev_b3.host.value("servers", "pre"), Some(pre_val));

    // 3c. ...while a validly sealed but different unsigned ciphertext under the retained name
    //     fails exactly the digest binding, not a missing one.
    let resealed = seal_b2.seal(&seal_b2.open(&original_pre.0).unwrap()).unwrap();
    assert_ne!(resealed, original_pre.0);
    blobs.lock().unwrap().insert(pre_blob_name.clone(), (resealed, None));
    let (_dev_b4, log_b4) = fresh_reader().await;
    match log_b4.pull().await {
        Err(Error::Untrusted(detail)) => assert_eq!(detail, format!("serverbox/{pre_blob_name}: {}", crate::RETAINED_MISMATCH)),
        other => panic!("expected digest mismatch, got {other:?}"),
    }
    blobs.lock().unwrap().insert(pre_blob_name.clone(), original_pre);

    // 4. Stripping signature from `post_blob_name` (previously signed!) MUST be rejected as `Untrusted`!
    *strip_blob.lock().unwrap() = Some(post_blob_name);
    let dev_c = Device::new("pw");
    *dev_c.secrets.secret_key.lock().unwrap() = sk_a;
    let sync_key_c = dev_c.key(&key_file).await.unwrap();
    let client_c = make_client().await;
    client_c.set_personal(Some(Arc::new(fl_lkc::personal::PersonalAuth::new(
        account_key,
        init_b,
        Arc::new(SimpleKeeper(Mutex::new(String::new()))),
    ))));
    let log_c = LogSync::new(dev_c.host.clone(), Arc::new(crate::lkc::LkcLog { client: client_c, account: "u1".into() }), sync_key_c);
    assert!(matches!(log_c.sync().await, Err(Error::Untrusted(_))));

    server.abort();
}

#[tokio::test]
async fn lkc_first_account_selection_probe_release_and_pending_legacy_password() {
    // Part 1: First selecting an account preserves in-flight `of_lkc` / probe for that
    // selected account while invalidating stale other accounts; switching away invalidates it.
    let d = Device::new("pw");
    let u1_started = Arc::new(tokio::sync::Notify::new());
    let u1_release = Arc::new(tokio::sync::Notify::new());
    let u2_started = Arc::new(tokio::sync::Notify::new());
    let u2_release = Arc::new(tokio::sync::Notify::new());

    struct SlowKeyFile {
        id: String,
        inner: Arc<MemKeyFile>,
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowKeyFile {
        fn id(&self) -> String {
            self.id.clone()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, body: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                *self.inner.file.lock().unwrap() = Some((body, "v1".into()));
                Ok(Some("v1".into()))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let kf1 = Arc::new(SlowKeyFile {
        id: "u1".into(),
        inner: Arc::new(MemKeyFile::default()),
        started: u1_started.clone(),
        release: u1_release.clone(),
    });
    let kf2 = Arc::new(SlowKeyFile {
        id: "u2".into(),
        inner: Arc::new(MemKeyFile::default()),
        started: u2_started.clone(),
        release: u2_release.clone(),
    });
    let kf1_inner = kf1.inner.clone();
    let kf2_inner = kf2.inner.clone();
    let ring1 = d.ring.clone();
    let ring2 = d.ring.clone();
    let t1 = tokio::spawn(async move { ring1.of_lkc(kf1, true).await });
    let t2 = tokio::spawn(async move { ring2.of_lkc(kf2, true).await });
    u1_started.notified().await;
    u2_started.notified().await;

    // First selection (`was_unset == true`): selecting `u1` preserves `u1` and invalidates `u2`!
    d.ring.sync_lkc_account(Some("u1"));
    u1_release.notify_one();
    u2_release.notify_one();
    assert!(t1.await.unwrap().is_ok(), "selected account u1 must be preserved on first selection");
    assert!(matches!(t2.await.unwrap(), Err(Error::SignedOut)), "stale account u2 must be invalidated on first selection");
    assert!(kf1_inner.file.lock().unwrap().is_some(), "u1 must still create its key file");
    assert!(kf2_inner.file.lock().unwrap().is_none(), "invalidated u2 must not write its key file");
    assert!(
        !d.secrets.pending.lock().unwrap().contains_key("intent:u2"),
        "invalidated u2 must not stage a write intent"
    );

    // Part 2: `register_lkc_probe` captures per-ID gen so `release` before polling invalidates
    // the probe while a probe registered AFTER `release` remains eligible.
    let d_probe = Device::new("pw");
    let sk = d_probe.secrets.secret_key.lock().unwrap().clone().unwrap();
    let sealed_kf = Arc::new(MemKeyFile::default());
    d_probe.ring.of(Arc::new(KeyFileOf(sealed_kf.clone(), "u1".into())), true).await.unwrap();
    d_probe.ring.release("u1");
    *d_probe.secrets.secret_key.lock().unwrap() = None;

    let (sw1, id1) = d_probe.ring.register_lkc_probe("u1").unwrap();
    // Release AFTER registration, BEFORE polling `lkc_sealed_with_secret_key`!
    d_probe.ring.release("u1");
    assert!(
        d_probe
            .ring
            .lkc_sealed_with_secret_key(Arc::new(KeyFileOf(sealed_kf.clone(), "u1".into())), sw1, id1)
            .await
            .unwrap()
    );
    assert!(
        !d_probe.ring.secret_key_missing().borrow().contains("u1"),
        "release after probe registration must prevent said_missing"
    );

    // Probe registered AFTER release remains eligible and publishes `secret_key_missing`.
    let (sw2, id2) = d_probe.ring.register_lkc_probe("u1").unwrap();
    assert!(
        d_probe
            .ring
            .lkc_sealed_with_secret_key(Arc::new(KeyFileOf(sealed_kf.clone(), "u1".into())), sw2, id2)
            .await
            .unwrap()
    );
    assert!(d_probe.ring.secret_key_missing().borrow().contains("u1"));
    let _ = sk;

    // Part 3: Legacy probe checks saved pending password + epoch check when legacy is allowed,
    // and preserves secret-key requirement when already marked 2FA.
    let d_leg = Device::new("new-pw");
    *d_leg.secrets.secret_key.lock().unwrap() = None;
    let legacy_body = crate::key::seal_with_password(
        b"# test, epoch 3\nAGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ",
        "old-pw",
    )
    .unwrap();
    let leg_kf = Arc::new(MemKeyFile::default());
    *leg_kf.file.lock().unwrap() = Some((legacy_body, "v1".into()));

    d_leg.secrets.pending.lock().unwrap().insert("leg".into(), "old-pw".into());
    d_leg.secrets.epochs.lock().unwrap().insert("leg".into(), 3);
    assert!(
        !d_leg
            .ring
            .sealed_with_secret_key(Arc::new(KeyFileOf(leg_kf.clone(), "leg".into())))
            .await
            .unwrap(),
        "matching pending password + epoch must permit legacy migration"
    );

    // Mismatched epoch (another device bumped it) -> must NOT permit legacy migration.
    d_leg.secrets.epochs.lock().unwrap().insert("leg".into(), 2);
    assert!(
        d_leg
            .ring
            .sealed_with_secret_key(Arc::new(KeyFileOf(leg_kf.clone(), "leg".into())))
            .await
            .unwrap(),
        "mismatched epoch on pending password must require secret key"
    );

    // Already marked 2FA -> must require secret key even if pending/current password opens it.
    d_leg.secrets.epochs.lock().unwrap().insert("leg".into(), 3);
    d_leg.secrets.epochs.lock().unwrap().insert("2fa:leg".into(), 1);
    assert!(
        d_leg
            .ring
            .sealed_with_secret_key(Arc::new(KeyFileOf(leg_kf, "leg".into())))
            .await
            .unwrap(),
        "remote already marked 2fa must require secret key"
    );
}
