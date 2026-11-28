//! Files: conditional writes, the store, downloads and listings.

use super::*;

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

#[tokio::test]
async fn failed_download_cleans_up_staged_part_file() {
    let key = AccountKey::generate("u1");
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
    let auth = Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()));
    sync.set_personal(Some(auth));

    let dir = tempdir::Dir::new();
    let to = dir.path().join("bak.age");
    assert_eq!(sync.download(NAME, &to, None).await.unwrap_err().kind, Kind::Untrusted);
    let leftover: Vec<_> = std::fs::read_dir(dir.path()).unwrap().collect();
    assert!(leftover.is_empty(), "expected no leftover .part files");
}

#[tokio::test]
async fn concurrent_downloads_do_not_overwrite_newer_version_with_older() {
    let key = AccountKey::generate("u1");
    let auth = Arc::new(PersonalAuth::new(key.clone(), PersonalVersions::default(), TestKeeper::new()));
    let sig1 = auth.sign_file("serverbox", NAME, 1, b"v1-body").await;
    let sig2 = auth.sign_file("serverbox", NAME, 2, b"v2-body").await;
    let pk = key.signing_public();
    let req_n = Arc::new(AtomicUsize::new(0));
    let seen = req_n.clone();
    let (_fake, sync) = homebase(move |_| {
        let n = seen.fetch_add(1, Ordering::SeqCst);
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

    let v1_verified = Arc::new(Notify::new());
    let release_v1 = Arc::new(Notify::new());
    let hook_fired = Arc::new(AtomicBool::new(false));
    {
        let v1_ver_c = v1_verified.clone();
        let rel_v1_c = release_v1.clone();
        let fired_c = hook_fired.clone();
        *sync.after_verify_before_rename.lock().unwrap() = Some(Arc::new(move || {
            let v1_ver = v1_ver_c.clone();
            let rel_v1 = rel_v1_c.clone();
            let first = !fired_c.swap(true, Ordering::SeqCst);
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
    assert_eq!(req_n.load(Ordering::SeqCst), 1, "v2 must not even fetch before acquiring dest_lock");

    release_v1.notify_one();
    assert_eq!(t1.await.unwrap().unwrap(), Fetched::Saved("e1".into()));
    assert_eq!(t2.await.unwrap().unwrap(), Fetched::Saved("e2".into()));
    assert_eq!(std::fs::read(&to).unwrap(), b"v2-body");
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
    let key = AccountKey::generate("u1");
    let pub_key = key.signing_public();
    let recipient = key.recipient();
    let (_fake2, sync2) = homebase(move |r| match (r.method.as_str(), r.path()) {
        ("GET", "/v2/keys") => Response::json(200, json!({ "data": { "recipient": recipient, "signing_key": pub_key, "next_seq": 2, "prev_signing_key": pub_key } })),
        ("PUT", _) => written("e1"),
        ("DELETE", _) => Response::status(404),
        _ => Response::status(404),
    })
    .await;
    let auth = Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()));
    sync2.set_personal(Some(auth));

    assert_eq!(sync2.upload_bytes("tracked.age", b"body".to_vec(), Condition::Absent).await.unwrap(), "e1");
    assert!(sync2.pending_commits.lock().unwrap().file_mutations.is_empty());
    assert!(!sync2.delete("untracked.age", None).await.unwrap());
    assert!(sync2.pending_commits.lock().unwrap().file_mutations.is_empty());
}

#[tokio::test]
async fn download_404_leaves_existing_destination_and_unrelated_part_file_untouched() {
    let key = AccountKey::generate("u1");
    let (_fake, sync) = homebase(|_| Response::status(404)).await;
    let auth = Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()));
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
async fn a_held_version_below_the_watermark_is_read_again_not_taken_as_unchanged() {
    let key = AccountKey::generate("u1");
    let auth = Arc::new(PersonalAuth::new(key.clone(), PersonalVersions::default(), TestKeeper::new()));
    let sig1 = auth.sign_file("serverbox", NAME, 1, b"v1-body").await;
    let pk = key.signing_public();
    let (fake, sync) = homebase(move |r| {
        if r.header("if-none-match") == Some("\"e1\"") {
            return Response::status(304);
        }
        Response::status(200)
            .header("ETag", "\"e1\"")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pk)
            .header("X-Signature", &sig1.signature)
            .header("X-Sync-Version", "1")
            .body("v1-body")
    })
    .await;
    sync.set_personal(Some(auth.clone()));
    let dir = tempdir::Dir::new();
    let to = dir.path().join("bak.age");
    assert_eq!(sync.download(NAME, &to, None).await.unwrap(), Fetched::Saved("e1".into()));
    // Held and verified at 1: a 304 for it stands.
    assert_eq!(sync.download(NAME, &to, Some("e1")).await.unwrap(), Fetched::Unchanged);
    // Another read raised the watermark to 2: version 1 is no longer enough.
    auth.record_file_version("serverbox", NAME, 2).await.unwrap();
    assert_eq!(sync.download(NAME, &to, Some("e1")).await.unwrap_err().kind, Kind::Untrusted);
    let gets = fake.requests(&format!("/v2/sync/serverbox/{NAME}"));
    assert_eq!(gets.last().unwrap().header("if-none-match"), None, "read again without the condition");
}

#[tokio::test]
async fn a_download_verified_under_an_auth_replaced_before_it_is_published_is_not() {
    let key = AccountKey::generate("u1");
    let auth = Arc::new(PersonalAuth::new(key.clone(), PersonalVersions::default(), TestKeeper::new()));
    let sig = auth.sign_file("serverbox", NAME, 1, b"v1-body").await;
    let pk = key.signing_public();
    let (_fake, sync) = homebase(move |_| {
        Response::status(200)
            .header("ETag", "\"e1\"")
            .header("X-Signer", "u1")
            .header("X-Signing-Key", &pk)
            .header("X-Signature", &sig.signature)
            .header("X-Sync-Version", "1")
            .body("v1-body")
    })
    .await;
    sync.set_personal(Some(auth));
    let weak = Arc::downgrade(&sync);
    *sync.after_verify_before_rename.lock().unwrap() = Some(Arc::new(move || {
        let sync = weak.upgrade().unwrap();
        Box::pin(async move { sync.set_personal(None) })
    }));
    let dir = tempdir::Dir::new();
    let to = file(&dir, "bak.age", b"held");
    assert_eq!(sync.download(NAME, &to, None).await.unwrap_err().kind, Kind::SignedOut);
    assert_eq!(std::fs::read(&to).unwrap(), b"held", "what was there stays");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1, "no staged part is left behind");
}

#[tokio::test]
async fn a_held_version_of_a_file_never_seen_signed_is_still_asked_for_unchanged() {
    let key = AccountKey::generate("u1");
    let (fake, sync) = homebase(|r| match r.header("if-none-match") {
        Some("\"e1\"") => Response::status(304),
        _ => Response::status(200).header("ETag", "\"e1\"").body("legacy"),
    })
    .await;
    sync.set_personal(Some(Arc::new(PersonalAuth::new(key, PersonalVersions::default(), TestKeeper::new()))));
    let dir = tempdir::Dir::new();
    let to = dir.path().join("bak.age");
    assert_eq!(sync.download(NAME, &to, Some("e1")).await.unwrap(), Fetched::Unchanged);
    assert_eq!(fake.requests(&format!("/v2/sync/serverbox/{NAME}"))[0].header("if-none-match"), Some("\"e1\""));
}
