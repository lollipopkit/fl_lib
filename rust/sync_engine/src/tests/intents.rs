//! Key-file write intents and committed writes still to settle.

use super::*;
use crate::key::SETTLE_WINDOW;
use tokio::time::Instant;

#[tokio::test]
async fn write_intent_recovers_committed_reseal_when_set_epochs_fails_and_ignores_lost_cas() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // 1. Start pw1 -> pw2 reseal while `set_epochs` fails: remote commits "pw2"
    //    at epoch 1, then `set_epoch_2fa` fails -> write intent MUST stay durable.
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    d.secrets.fail_set_epochs.store(true, Ordering::SeqCst);
    assert!(matches!(ka.check(true, true).await, Err(Error::Host(_))));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert!(d.secrets.pending.lock().unwrap().contains_key("intent:account"));

    // 2. Second password change pw2 -> pw3 while epochs still at 0 and pending still "pw1",
    //    then prefs recover. Inject a transient network failure on the first write
    //    attempt during WriteIntent recovery: the confirmed `(epoch=1, "pw2")` MUST
    //    already be persisted so retrying still succeeds without PasswordMismatch.
    struct FailOnceKeyFile {
        inner: Arc<MemKeyFile>,
        fail_next: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for FailOnceKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if self.fail_next.swap(false, Ordering::SeqCst) {
                    return Err(Error::Remote("transient drop before server".into()));
                }
                let mut f = self.inner.file.lock().unwrap();
                if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                    return Ok(None);
                }
                let next = format!("vw{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                *f = Some((body, next.clone()));
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    d.ring.password_changed(Some("pw2".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    d.secrets.fail_set_epochs.store(false, Ordering::SeqCst);
    let flaky = Arc::new(FailOnceKeyFile {
        inner: file.clone(),
        fail_next: AtomicBool::new(true),
        next: AtomicU64::new(0),
    });
    assert!(matches!(d.ring.of(flaky.clone(), true).await, Err(Error::Remote(_))));
    // Confirmed `(epoch=1, "pw2")` was already persisted before the failed new write.
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("pw2"));

    d.ring.of(flaky, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2));
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());

    // 3. Real lost CAS (`Ok(None)`) MUST clear the write intent and NOT treat the lost
    //    attempt as a committed reseal (another device's write winning the CAS triggers mismatch).
    let other = Device::new("pw3");
    let k_other = other.key(&file).await.unwrap();
    struct LostCasKeyFile {
        inner: Arc<MemKeyFile>,
        other_secrets: Arc<MemSecrets>,
        other_ring: KeyRing,
        other_key: Arc<crate::key::SyncKey>,
        raced: AtomicBool,
    }
    impl KeyFile for LostCasKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, _body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if !self.raced.swap(true, Ordering::SeqCst) {
                    // Right as `d` attempts its CAS write (after staging `intent:account`),
                    // `other` wins the race by resealing `file` to "other-pw" at epoch 3.
                    self.other_ring.password_changed(Some("pw3".into())).await?;
                    *self.other_secrets.password.lock().unwrap() = Some("other-pw".into());
                    self.other_key.check(true, true).await?;
                }
                Ok(None)
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let lost_cas = Arc::new(LostCasKeyFile {
        inner: file.clone(),
        other_secrets: other.secrets.clone(),
        other_ring: other.ring.clone(),
        other_key: k_other,
        raced: AtomicBool::new(false),
    });
    // Attach `lost_cas` to the existing key slot, then force a check for pw3 -> pw4.
    let ka = d.ring.of(lost_cas.clone(), true).await.unwrap();
    d.ring.password_changed(Some("pw3".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw4".into());
    assert!(matches!(ka.check(true, true).await, Err(Error::PasswordMismatch(_))));
    assert!(lost_cas.raced.load(Ordering::SeqCst), "must have entered KeyFile::write and lost CAS");
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2), "lost CAS must not advance epoch");
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:account"));
    assert!(ka.open(&ka.seal(b"still-valid").unwrap()).unwrap() == b"still-valid");
}

#[tokio::test]
async fn restore_retains_pending_write_after_legacy_upgrade_persist_failure() {
    let inner = Arc::new(MemKeyFile::default());
    // Seed a legacy passphrase-only key file (epoch 0).
    let legacy_id = {
        use age::secrecy::ExposeSecret;
        age::x25519::Identity::generate().to_string().expose_secret().to_string()
    };
    let legacy_body = crate::key::seal_with_password(format!("# test, epoch 0\n{legacy_id}").as_bytes(), "pw").unwrap();
    *inner.file.lock().unwrap() = Some((legacy_body, "v1".into()));

    struct FailFirstPersistKeyFile {
        inner: Arc<MemKeyFile>,
        writes: AtomicUsize,
        fail_persist: AtomicBool,
        flushed: Mutex<Vec<(String, Option<i64>)>>,
    }
    impl KeyFile for FailFirstPersistKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                self.writes.fetch_add(1, Ordering::SeqCst);
                let mut f = self.inner.file.lock().unwrap();
                if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                    return Ok(None);
                }
                let ver = "v2".to_string();
                *f = Some((body, ver.clone()));
                if self.fail_persist.load(Ordering::SeqCst) {
                    return Err(Error::KeyFilePersistFailed {
                        version: ver,
                        sync_version: None,
                        detail: "watermark save failed".into(),
                    });
                }
                Ok(Some(ver))
            })
        }
        fn flush_committed_write(&self, version: String, sync_version: Option<i64>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async move {
                if self.fail_persist.load(Ordering::SeqCst) {
                    return Err(Error::Host("still failing".into()));
                }
                self.flushed.lock().unwrap().push((version, sync_version));
                Ok(())
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let kf = Arc::new(FailFirstPersistKeyFile {
        inner: inner.clone(),
        writes: AtomicUsize::new(0),
        fail_persist: AtomicBool::new(true),
        flushed: Mutex::default(),
    });
    let d = Device::new("pw");

    // Restore (`create = false`) upgrades legacy file; PUT commits, local save fails.
    assert!(matches!(d.ring.of(kf.clone(), false).await, Err(Error::Host(_))));
    assert_eq!(kf.writes.load(Ordering::SeqCst), 1);

    // Local save recovers; next restore retries flush without resending PUT.
    kf.fail_persist.store(false, Ordering::SeqCst);
    let key = d.ring.of(kf.clone(), false).await.unwrap();
    assert_eq!(kf.writes.load(Ordering::SeqCst), 1);
    assert_eq!(*kf.flushed.lock().unwrap(), vec![("v2".to_string(), None)], "the committed write's watermark is flushed");
    assert_eq!(key.open(&key.seal(b"restored").unwrap()).unwrap(), b"restored");
}

#[tokio::test]
async fn a_committed_key_write_s_watermark_is_flushed_without_writing_again() {
    struct LocalWatermarkKeyFile {
        inner: Arc<MemKeyFile>,
        writes: AtomicUsize,
        flush_fails: AtomicBool,
        flushed: Mutex<Option<(String, Option<i64>)>>,
    }
    impl KeyFile for LocalWatermarkKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                self.writes.fetch_add(1, Ordering::SeqCst);
                let mut file = self.inner.file.lock().unwrap();
                if file.as_ref().map(|(_, v)| v.clone()) != if_version {
                    return Ok(None);
                }
                *file = Some((body, "v1".into()));
                Err(Error::KeyFilePersistFailed { version: "v1".into(), sync_version: Some(1), detail: "save failed".into() })
            })
        }
        fn flush_committed_write(&self, version: String, sync_version: Option<i64>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async move {
                if self.flush_fails.load(Ordering::SeqCst) {
                    return Err(Error::Host("save failed again".into()));
                }
                *self.flushed.lock().unwrap() = Some((version, sync_version));
                Ok(())
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let kf = Arc::new(LocalWatermarkKeyFile {
        inner: Arc::new(MemKeyFile::default()),
        writes: AtomicUsize::new(0),
        flush_fails: AtomicBool::new(true),
        flushed: Mutex::new(None),
    });
    let d = Device::new("pw");
    let other = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    // A local flush that fails keeps the pending write.
    assert!(matches!(d.ring.of(kf.clone(), true).await, Err(Error::Host(_))));
    assert!(d.ring.store_secret_key(&other).await.is_err(), "the pending write stays");

    kf.flush_fails.store(false, Ordering::SeqCst);
    d.ring.of(kf.clone(), true).await.unwrap();
    assert_eq!(*kf.flushed.lock().unwrap(), Some(("v1".into(), Some(1))));
    assert_eq!(kf.writes.load(Ordering::SeqCst), 1, "the committed write is never sent again");
    d.ring.store_secret_key(&other).await.unwrap();
}

#[tokio::test]
async fn released_handle_late_ok_preserves_replacement_pending_write_and_forget_blocks_reinsert() {
    let d = Device::new("pw");
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let other_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    let slow_started = Arc::new(tokio::sync::Notify::new());
    let release_slow = Arc::new(tokio::sync::Notify::new());
    struct SlowRotateKeyFile {
        inner: Arc<MemKeyFile>,
        block_write: AtomicBool,
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowRotateKeyFile {
        fn id(&self) -> String {
            "remote-1".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if self.block_write.load(Ordering::SeqCst) {
                    self.started.notify_one();
                    self.release.notified().await;
                    return Ok(Some("v-old".into()));
                }
                *self.inner.file.lock().unwrap() = Some((body, "v0".into()));
                Ok(Some("v0".into()))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    struct PersistFailThenOkKeyFile {
        inner: Arc<MemKeyFile>,
        fail: AtomicBool,
    }
    impl KeyFile for PersistFailThenOkKeyFile {
        fn id(&self) -> String {
            "remote-1".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                *self.inner.file.lock().unwrap() = Some((body, "v-new".into()));
                if self.fail.load(Ordering::SeqCst) {
                    return Err(Error::KeyFilePersistFailed {
                        version: "v-new".into(),
                        sync_version: Some(2),
                        detail: "watermark save failed".into(),
                    });
                }
                Ok(Some("v-new".into()))
            })
        }
        fn flush_committed_write(&self, _: String, _: Option<i64>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async {
                if self.fail.load(Ordering::SeqCst) {
                    return Err(Error::Host("watermark save failed".into()));
                }
                Ok(())
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    // Part A: Released handle H1 finishes `Ok(Some)` AFTER replacement handle H2 recorded a pending write.
    let slow_kf = Arc::new(SlowRotateKeyFile {
        inner: Arc::new(MemKeyFile::default()),
        block_write: AtomicBool::new(false),
        started: slow_started.clone(),
        release: release_slow.clone(),
    });
    let h1 = d.ring.of(slow_kf.clone(), true).await.unwrap();
    let h1_at_hook = Arc::new(tokio::sync::Notify::new());
    let h1_resume_hook = Arc::new(tokio::sync::Notify::new());
    let h1_at_c = h1_at_hook.clone();
    let h1_res_c = h1_resume_hook.clone();
    let h1_task = tokio::spawn(async move {
        h1.rotate_after_check(move || {
            Box::pin(async move {
                h1_at_c.notify_one();
                h1_res_c.notified().await;
                Ok(())
            })
        })
        .await
    });
    h1_at_hook.notified().await;

    d.ring.release("remote-1");
    let mem = Arc::new(MemKeyFile::default());
    let replacement_kf = Arc::new(PersistFailThenOkKeyFile { inner: mem, fail: AtomicBool::new(true) });
    assert!(matches!(d.ring.of(replacement_kf.clone(), true).await, Err(Error::Host(_))));
    assert!(d.ring.store_secret_key(&other_b).await.is_err());

    // Now let released H1 complete `Ok(Some("v0"))`: H2's pending write MUST remain intact!
    h1_resume_hook.notify_one();
    h1_task.await.unwrap().unwrap();
    assert!(d.ring.store_secret_key(&other_b).await.is_err(), "released handle's late Ok must not clear replacement pending_write");

    replacement_kf.fail.store(false, Ordering::SeqCst);
    d.ring.of(replacement_kf, true).await.unwrap();

    // Part B: `forget(id)` during an in-flight write that later fails watermark persistence MUST NOT
    // re-insert into `pending_writes` or block importing `other_b`.
    let fail_started = Arc::new(tokio::sync::Notify::new());
    let release_fail = Arc::new(tokio::sync::Notify::new());
    struct SlowPersistFailKeyFile {
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowPersistFailKeyFile {
        fn id(&self) -> String {
            "remote-forgotten".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(None) })
        }
        fn write(&self, _body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                self.started.notify_one();
                self.release.notified().await;
                Err(Error::KeyFilePersistFailed {
                    version: "v1".into(),
                    sync_version: Some(1),
                    detail: "late fail after forget".into(),
                })
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let ring2 = d.ring.clone();
    let slow_fail_kf = Arc::new(SlowPersistFailKeyFile { started: fail_started.clone(), release: release_fail.clone() });
    let forgotten_task = tokio::spawn(async move { ring2.of(slow_fail_kf, true).await });
    fail_started.notified().await;

    d.ring.forget("remote-forgotten").await.unwrap();
    release_fail.notify_one();
    assert!(matches!(forgotten_task.await.unwrap(), Err(Error::SignedOut)));

    // Forgotten handle MUST NOT resurrect `epochs` (`2fa:`), `pending` (`intent:`), or `pending_writes`.
    assert!(!d.secrets.epochs.lock().unwrap().contains_key("remote-forgotten"));
    assert!(!d.secrets.epochs.lock().unwrap().contains_key("2fa:remote-forgotten"));
    assert!(!d.secrets.pending.lock().unwrap().contains_key("intent:remote-forgotten"));
    let _ = sk;
    d.ring.store_secret_key(&other_b).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(other_b.as_str()));

    // Part C: Released handle H_old finishing `Err(KeyFilePersistFailed)` late AFTER replacement
    // handle H_new already succeeded (`Ok(Some)`) MUST NOT re-insert a stale `pending_writes` entry.
    let late_fail_started = Arc::new(tokio::sync::Notify::new());
    let release_late_fail = Arc::new(tokio::sync::Notify::new());
    struct SlowRotatePersistFailKeyFile {
        inner: Arc<MemKeyFile>,
        block_write: AtomicBool,
        started: Arc<tokio::sync::Notify>,
        release: Arc<tokio::sync::Notify>,
    }
    impl KeyFile for SlowRotatePersistFailKeyFile {
        fn id(&self) -> String {
            "remote-2".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, _if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                if self.block_write.load(Ordering::SeqCst) {
                    self.started.notify_one();
                    self.release.notified().await;
                    return Err(Error::KeyFilePersistFailed {
                        version: "v-stale".into(),
                        sync_version: Some(1),
                        detail: "late stale persist failure".into(),
                    });
                }
                *self.inner.file.lock().unwrap() = Some((body, "v0".into()));
                Ok(Some("v0".into()))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let h_old_kf = Arc::new(SlowRotatePersistFailKeyFile {
        inner: Arc::new(MemKeyFile::default()),
        block_write: AtomicBool::new(false),
        started: late_fail_started.clone(),
        release: release_late_fail.clone(),
    });
    let h_old = d.ring.of(h_old_kf.clone(), true).await.unwrap();
    let hold_at_hook = Arc::new(tokio::sync::Notify::new());
    let hold_resume_hook = Arc::new(tokio::sync::Notify::new());
    let hold_at_c = hold_at_hook.clone();
    let hold_res_c = hold_resume_hook.clone();
    let h_old_task = tokio::spawn(async move {
        h_old
            .rotate_after_check(move || {
                Box::pin(async move {
                    hold_at_c.notify_one();
                    hold_res_c.notified().await;
                    Ok(())
                })
            })
            .await
    });
    hold_at_hook.notified().await;
    h_old_kf.block_write.store(true, Ordering::SeqCst);

    d.ring.release("remote-2");
    let h_new_kf = Arc::new(PersistFailThenOkKeyFile {
        inner: Arc::new(MemKeyFile::default()),
        fail: AtomicBool::new(false),
    });
    struct RenamedKeyFile(Arc<PersistFailThenOkKeyFile>);
    impl KeyFile for RenamedKeyFile {
        fn id(&self) -> String {
            "remote-2".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            self.0.read()
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            self.0.write(body, if_version)
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            self.0.can_create()
        }
    }
    d.ring.of(Arc::new(RenamedKeyFile(h_new_kf)), true).await.unwrap();

    // Let H_old proceed and fail watermark persistence late: MUST NOT insert stale `PendingKeyWrite` over H_new!
    hold_resume_hook.notify_one();
    late_fail_started.notified().await;
    release_late_fail.notify_one();
    assert!(h_old_task.await.unwrap().is_err());
    let other_c = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    d.ring.store_secret_key(&other_c).await.unwrap();
}

#[tokio::test]
async fn key_write_refused_before_dispatch_rolls_back_only_its_own_intent() {
    let d = Device::new("pw");
    let file = Arc::new(MemKeyFile::default());
    // A write intent this write did not create.
    let prior = serde_json::json!([{ "epoch": 9, "pwd": "older" }]).to_string();
    d.secrets.pending.lock().unwrap().insert("intent:u1".into(), prior.clone());
    // The account switches right after the write intent is staged, before
    // the PUT is dispatched.
    let ring = d.ring.clone();
    let switched = Arc::new(AtomicBool::new(false));
    let flag = switched.clone();
    *d.secrets.on_set_pending.lock().unwrap() = Some(Box::new(move |p| {
        if p.get("intent:u1").is_some_and(|raw| raw.matches("epoch").count() == 2) && !flag.swap(true, Ordering::SeqCst) {
            ring.sync_lkc_account(Some("u2"));
        }
    }));
    let res = d.ring.of_lkc(Arc::new(KeyFileOf(file.clone(), "u1".into())), true).await;
    assert!(matches!(res, Err(Error::SignedOut)), "{:?}", res.err());
    assert!(switched.load(Ordering::SeqCst));
    assert!(file.file.lock().unwrap().is_none(), "no PUT after the refusal");
    assert_eq!(d.secrets.pending.lock().unwrap().get("intent:u1"), Some(&prior), "only the refused write's own intent goes");
}

#[tokio::test(start_paused = true)]
async fn key_write_intent_goes_after_a_lost_cas_and_stays_beside_earlier_ones_after_a_transport_error() {
    struct FlakyKeyFile {
        writes: AtomicU64,
    }
    impl KeyFile for FlakyKeyFile {
        fn id(&self) -> String {
            "remote-1".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(None) })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async {
                // A lost CAS first; then a PUT that may have reached the backend.
                match self.writes.fetch_add(1, Ordering::SeqCst) {
                    0 => Ok(None),
                    _ => Err(Error::Host("connection reset".into())),
                }
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }
    let d = Device::new("pw");
    let older = serde_json::json!({ "epoch": 9, "pwd": "older" });
    let prior = serde_json::json!([older]).to_string();
    d.secrets.pending.lock().unwrap().insert("intent:remote-1".into(), prior.clone());
    let history = Arc::new(Mutex::new(Vec::new()));
    let seen = history.clone();
    *d.secrets.on_set_pending.lock().unwrap() = Some(Box::new(move |p| {
        seen.lock().unwrap().push(p.get("intent:remote-1").cloned());
    }));
    let flaky = Arc::new(FlakyKeyFile { writes: AtomicU64::new(0) });
    let res = d.ring.of(flaky.clone(), true).await;
    assert!(matches!(res, Err(Error::Host(_))), "{:?}", res.err());
    let first = d.ring.intent_since("remote-1", 0, "pw").await.expect("its dispatch is timed");
    // The same attempt failing again adds no second copy of its intent, and
    // its window starts at the retry's dispatch.
    tokio::time::advance(Duration::from_secs(60)).await;
    let before = Instant::now();
    let res = d.ring.of(flaky, true).await;
    let after = Instant::now();
    assert!(matches!(res, Err(Error::Host(_))), "{:?}", res.err());
    let retried = d.ring.intent_since("remote-1", 0, "pw").await.expect("its dispatch is timed");
    assert!(first < before && before <= retried && retried <= after, "{first:?} {before:?} {retried:?} {after:?}");
    let history = history.lock().unwrap().clone();
    let staged = history[0].clone().expect("the first write stages its intent");
    let staged: Vec<serde_json::Value> = serde_json::from_str(&staged).unwrap();
    assert_eq!(staged.len(), 2);
    assert_eq!(staged[0], older, "an earlier attempt that may have committed stays");
    assert_eq!(history[1].as_ref(), Some(&prior), "a lost CAS removes only its own intent");
    let kept: Vec<serde_json::Value> = serde_json::from_str(d.secrets.pending.lock().unwrap().get("intent:remote-1").unwrap()).unwrap();
    assert_eq!(kept, staged, "a PUT that may have landed keeps its intent beside the earlier one");
    assert_eq!(history.len(), 3, "the retry reuses its intent, saving nothing");
}

#[tokio::test]
async fn an_open_settles_only_its_own_write_intent_and_the_other_password_stays_recoverable() {
    let made = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    a.key(&made).await.unwrap();
    // Read from a store that does not order writes: a lost attempt may still land.
    let file = Arc::new(MemKeyFile { unordered: true, file: Mutex::new(made.file.lock().unwrap().clone()), ..Default::default() });
    let sk = a.secrets.secret_key.lock().unwrap().clone();
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = sk.clone();
    let intents_of = |d: &Device| -> Vec<Value> { serde_json::from_str(d.secrets.pending.lock().unwrap().get("intent:account").expect("intents")).unwrap() };
    // Attempts at epoch 0 under `pw` and under `lost` (the latter may still
    // land, on a store that does not order writes), and one at epoch 1.
    let lost = json!({ "epoch": 0, "pwd": "lost" });
    let later = json!({ "epoch": 1, "pwd": "later" });
    let intents = json!([{ "epoch": 0, "pwd": "pw" }, lost, later]).to_string();
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), intents);

    // Opening at epoch 0 under `pw` settles only that write.
    let key = b.key(&file).await.unwrap();
    assert_eq!(intents_of(&b), vec![lost, later.clone()]);

    // The `lost` write lands after all, and the password here changes: it is
    // recovered from its intent and sealed again under the new one.
    let other = Arc::new(MemKeyFile::default());
    let c = Device::new("lost");
    *c.secrets.secret_key.lock().unwrap() = sk.clone();
    c.key(&other).await.unwrap();
    let landed = other.file.lock().unwrap().clone().unwrap().0;
    *file.file.lock().unwrap() = Some((landed, "landed".into()));
    *b.secrets.password.lock().unwrap() = Some("new".into());
    key.check(true, true).await.unwrap();
    assert_eq!(intents_of(&b), vec![later]);

    let reader = Device::new("new");
    *reader.secrets.secret_key.lock().unwrap() = sk;
    reader.key(&file).await.expect("sealed again under the new password");
}

#[tokio::test]
async fn on_a_store_that_orders_writes_an_open_settles_every_attempt_at_its_epoch() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    a.key(&file).await.unwrap();
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = a.secrets.secret_key.lock().unwrap().clone();
    let later = json!({ "epoch": 1, "pwd": "later" });
    let intents = json!([{ "epoch": 0, "pwd": "pw" }, { "epoch": 0, "pwd": "lost" }, later]).to_string();
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), intents);
    b.key(&file).await.unwrap();
    let kept: Vec<Value> = serde_json::from_str(b.secrets.pending.lock().unwrap().get("intent:account").expect("a later attempt stays")).unwrap();
    assert_eq!(kept, vec![later], "the other attempt at epoch 0 lost its condition");
}

fn intents_of(d: &Device, id: &str) -> Option<Vec<Value>> {
    d.secrets.pending.lock().unwrap().get(&format!("intent:{id}")).map(|raw| serde_json::from_str(raw).unwrap())
}

/// Past the settle window on this process's clock, whatever the wall clock says.
async fn past_the_window() {
    tokio::time::advance(SETTLE_WINDOW + Duration::from_secs(1)).await;
}

#[tokio::test(start_paused = true)]
async fn on_a_store_that_does_not_order_writes_an_attempt_past_its_window_is_over() {
    let made = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    a.key(&made).await.unwrap();
    let file = Arc::new(MemKeyFile { unordered: true, file: Mutex::new(made.file.lock().unwrap().clone()), ..Default::default() });
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = a.secrets.secret_key.lock().unwrap().clone();
    let lost = |epoch: i64| json!({ "epoch": epoch, "pwd": "lost" });
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([lost(0), lost(1)]).to_string());
    // Left by an earlier process: how long ago it was sent is not known here.
    let key = b.key(&file).await.unwrap();
    assert_eq!(intents_of(&b, "account"), Some(vec![lost(0), lost(1)]), "a window counts from when this process meets it");

    past_the_window().await;
    let recent = json!({ "epoch": 0, "pwd": "recent" });
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([lost(0), lost(1), recent]).to_string());
    key.check(true, true).await.unwrap();
    assert_eq!(intents_of(&b, "account"), Some(vec![recent]), "an attempt the file does not hold, past its window, is over");
}

#[tokio::test(start_paused = true)]
async fn a_refused_password_keeps_only_the_write_intents_within_their_window() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    a.key(&file).await.unwrap();
    let b = Device::new("other");
    *b.secrets.secret_key.lock().unwrap() = a.secrets.secret_key.lock().unwrap().clone();
    let stale = json!({ "epoch": 1, "pwd": "never-landed" });
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([stale]).to_string());
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));
    assert_eq!(intents_of(&b, "account"), Some(vec![stale.clone()]), "not yet a window since this process met it");

    past_the_window().await;
    let recent = json!({ "epoch": 1, "pwd": "unsettled" });
    b.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([stale, recent]).to_string());
    b.secrets.pending.lock().unwrap().insert("account".into(), "older".into());
    // Read again now, past the check kept for a minute.
    b.ring.recheck().await;
    assert_eq!(intents_of(&b, "account"), Some(vec![recent]), "one past its window that the file does not hold is over");
    assert!(!b.secrets.pending.lock().unwrap().contains_key("account"));
}

#[tokio::test(start_paused = true)]
async fn no_file_on_a_store_that_orders_writes_settles_only_the_attempts_past_their_window() {
    let stale = json!({ "epoch": 0, "pwd": "never-landed" });
    let recent = json!({ "epoch": 0, "pwd": "recent" });
    for unordered in [false, true] {
        let file = Arc::new(MemKeyFile { unordered, ..Default::default() });
        let d = Device::new("pw");
        d.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([stale]).to_string());
        let restore = || d.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), false);
        assert!(matches!(restore().await, Err(Error::KeyNotHere(_))));
        assert_eq!(intents_of(&d, "account"), Some(vec![stale.clone()]), "unordered: {unordered}");

        past_the_window().await;
        d.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([stale, recent]).to_string());
        d.secrets.pending.lock().unwrap().insert("account".into(), "older".into());
        assert!(matches!(restore().await, Err(Error::KeyNotHere(_))));
        assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("older"), "a password change still to seal stays");
        // Where none may only not have arrived yet, an attempt past its window
        // never landed; elsewhere it may still arrive.
        let kept = if unordered { vec![stale.clone(), recent.clone()] } else { vec![recent.clone()] };
        assert_eq!(intents_of(&d, "account"), Some(kept), "unordered: {unordered}");
    }
}

// Pre-signing batches below the signing floor: accepted unsigned, while the
// account's blob policy refuses an unsigned blob read strictly.

#[tokio::test]
async fn a_released_handle_settles_nothing() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let old = d.key(&file).await.unwrap();
    d.ring.release("account");
    let _replacement = d.key(&file).await.unwrap();
    let own = json!({ "epoch": 0, "pwd": "pw" });
    d.secrets.pending.lock().unwrap().insert("intent:account".into(), json!([own]).to_string());
    d.secrets.pending.lock().unwrap().insert("account".into(), "older".into());
    old.check(true, true).await.unwrap();
    assert_eq!(intents_of(&d, "account"), Some(vec![own]), "its own write's intent is the replacement's to settle");
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("older"));
}
