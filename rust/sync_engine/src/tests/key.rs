//! The key file: opening, password changes, rotation and probes.

use super::*;
use tokio::sync::Notify;

#[tokio::test]
async fn the_key_opens_on_another_device_with_the_password() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let ka = a.key(&file).await.unwrap();
    let kb = b.key(&file).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"hi").unwrap()).unwrap(), b"hi");
    let (sealed, _) = file.file.lock().unwrap().clone().unwrap();
    assert!(String::from_utf8_lossy(&sealed).starts_with("-----BEGIN AGE ENCRYPTED FILE-----"));
    // Bare password alone must not open the two-factor sealed key file.
    assert!(crate::key::open_with_password(&sealed, "pw").unwrap().is_none());
    let sk = fl_lkc::secret_key::SecretKey::parse(a.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let plain = crate::key::open_with_password(&sealed, &sk.combine_passphrase("pw")).unwrap().unwrap();
    assert!(String::from_utf8(plain.to_vec()).unwrap().starts_with("# Test sync key, epoch 0\nAGE-SECRET-KEY-1"));
}

#[tokio::test]
async fn another_password_syncs_nothing() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("other"));
    a.key(&file).await.unwrap();
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));
    assert!(b.ring.mismatch().borrow().contains("account"));
}

#[tokio::test]
async fn a_changed_password_seals_the_file_again() {
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("old"), Device::new("old"));
    let ka = a.key(&file).await.unwrap();
    b.key(&file).await.unwrap();
    a.ring.password_changed(Some("old".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("new".into());
    ka.check(true, true).await.unwrap();
    let (sealed, _) = file.file.lock().unwrap().clone().unwrap();
    assert!(crate::key::open_with_password(&sealed, "new").unwrap().is_none());
    let sk = fl_lkc::secret_key::SecretKey::parse(a.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let plain = String::from_utf8(crate::key::open_with_password(&sealed, &sk.combine_passphrase("new")).unwrap().unwrap().to_vec()).unwrap();
    assert!(plain.starts_with("# Test sync key, epoch 1\n"));
    // b, still on the old one, is told; with the new one it opens the same key.
    let kb = b.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), true).await.unwrap();
    assert!(matches!(kb.check(true, true).await, Err(Error::PasswordMismatch(_))));
    *b.secrets.password.lock().unwrap() = Some("new".into());
    kb.check(true, true).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"x").unwrap()).unwrap(), b"x");
}

#[tokio::test]
async fn keys_made_at_once_on_an_unordered_store_are_merged() {
    // Two folders as two devices saw one before the other's write arrived.
    let file = Arc::new(MemKeyFile::default());
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let ka = a.key(&file).await.unwrap();
    let sealed_by_a = ka.seal(b"from a").unwrap();
    // b made its own elsewhere first.
    let other = Arc::new(MemKeyFile::default());
    let kb = b.ring.of(Arc::new(KeyFileOf(other, "account".into())), true).await.unwrap();
    let sealed_by_b = kb.seal(b"from b").unwrap();
    // Then b meets a's file: it puts its key in beside a's.
    let kb = b.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), true).await.unwrap();
    kb.check(true, true).await.unwrap();
    assert_eq!(kb.open(&sealed_by_a).unwrap(), b"from a");
    assert!(ka.refresh().await.unwrap());
    assert_eq!(ka.open(&sealed_by_b).unwrap(), b"from b");
}

#[tokio::test]
async fn none_is_made_where_one_may_only_not_have_arrived() {
    let file = Arc::new(MemKeyFile { unordered: true, ..Default::default() });
    let a = Device::new("pw");
    assert!(matches!(a.key(&file).await, Err(Error::KeyNotHere(_))));
}

#[test]
fn a_key_sealed_file_is_told_from_a_password_sealed_one() {
    assert!(crate::key::sealed_to_key(b"age-encryption.org/v1\n-> X25519 abc"));
    assert!(!crate::key::sealed_to_key(b"age-encryption.org/v1\n-> scrypt abc"));
}

#[tokio::test]
async fn opened_at_does_not_cache_when_epoch_persistence_fails() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    d.secrets.fail_set_epochs.store(true, Ordering::SeqCst);
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert!(d.secrets.epochs.lock().unwrap().is_empty());

    // Once epoch persistence succeeds, retrying MUST persist the 2FA marker and epoch.
    d.secrets.fail_set_epochs.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert_eq!(d.secrets.epochs.lock().unwrap().get("2fa:account"), Some(&1));
    assert_eq!(k.open(&k.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn concurrent_epoch_updates_and_secret_key_init_across_remotes_are_serialized() {
    let file_a = Arc::new(MemKeyFile::default());
    let file_b = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.epochs_delay_ms.store(25, Ordering::SeqCst);

    let (ka, kb) = tokio::join!(
        d.ring.of(Arc::new(KeyFileOf(file_a.clone(), "remote-a".into())), true),
        d.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true),
    );
    let (ka, kb) = (ka.unwrap(), kb.unwrap());
    let stored = d.secrets.secret_key.lock().unwrap().clone().expect("secret key stored");
    let sk = fl_lkc::secret_key::SecretKey::parse(&stored).unwrap();

    // Both remotes must be openable with the ONE stored secret key.
    let raw_a = file_a.file.lock().unwrap().clone().unwrap().0;
    let raw_b = file_b.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_a, &sk.combine_passphrase("pw")).unwrap().is_some());
    assert!(crate::key::open_with_password(&raw_b, &sk.combine_passphrase("pw")).unwrap().is_some());

    // Both remotes' epochs & 2fa markers must be preserved (no lost update).
    let epochs = d.secrets.epochs.lock().unwrap();
    assert_eq!(epochs.get("remote-a"), Some(&0));
    assert_eq!(epochs.get("2fa:remote-a"), Some(&1));
    assert_eq!(epochs.get("remote-b"), Some(&0));
    assert_eq!(epochs.get("2fa:remote-b"), Some(&1));
    assert_eq!(ka.open(&ka.seal(b"a").unwrap()).unwrap(), b"a");
    assert_eq!(kb.open(&kb.seal(b"b").unwrap()).unwrap(), b"b");
}

#[tokio::test]
async fn concurrent_password_change_during_key_write_is_not_clobbered() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // Wrap key file so during write("pw2"), a concurrent password change
    // "pw2" -> "pw3" occurs before write returns.
    struct RaceWriteKeyFile {
        inner: Arc<MemKeyFile>,
        secrets: Arc<MemSecrets>,
        ring: KeyRing,
        fired: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for RaceWriteKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                let next = {
                    let mut f = self.inner.file.lock().unwrap();
                    if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                        return Ok(None);
                    }
                    let next = format!("vr{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                    *f = Some((body, next.clone()));
                    next
                };
                if !self.fired.swap(true, Ordering::SeqCst) {
                    *self.secrets.password.lock().unwrap() = Some("pw3".into());
                    self.ring.password_changed(Some("pw2".into())).await?;
                }
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    // First password change: pw1 -> pw2, triggering concurrent pw2 -> pw3 mid-write.
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    let raced = Arc::new(RaceWriteKeyFile {
        inner: file.clone(),
        secrets: d.secrets.clone(),
        ring: d.ring.clone(),
        fired: AtomicBool::new(false),
        next: AtomicU64::new(0),
    });
    let kb = d.ring.of(raced, true).await.unwrap();
    kb.check(true, true).await.unwrap();

    // Remote file MUST end up sealed under "pw3" without PasswordMismatch.
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());
    assert_eq!(kb.open(&ka.seal(b"concurrent-ok").unwrap()).unwrap(), b"concurrent-ok");
}

#[tokio::test]
async fn password_changed_notification_before_password_update_during_key_write() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let ka = d.key(&file).await.unwrap();
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();

    // During write("pw2"), caller notifies `password_changed(Some("pw2"))` BEFORE
    // updating `secrets.password` from "pw2" to "pw3" (the documented order).
    struct NotifyBeforeUpdateKeyFile {
        inner: Arc<MemKeyFile>,
        ring: KeyRing,
        fired: AtomicBool,
        next: AtomicU64,
    }
    impl KeyFile for NotifyBeforeUpdateKeyFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async move {
                let next = {
                    let mut f = self.inner.file.lock().unwrap();
                    if f.as_ref().map(|(_, v)| v) != if_version.as_ref() {
                        return Ok(None);
                    }
                    let next = format!("vn{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
                    *f = Some((body, next.clone()));
                    next
                };
                if !self.fired.swap(true, Ordering::SeqCst) {
                    // Notice: `secrets.password` is STILL "pw2" here!
                    self.ring.password_changed(Some("pw2".into())).await?;
                }
                Ok(Some(next))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    // Start pw1 -> pw2 reseal; mid-write `password_changed("pw2")` fires while
    // `secrets.password` is still "pw2".
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    let raced = Arc::new(NotifyBeforeUpdateKeyFile {
        inner: file.clone(),
        ring: d.ring.clone(),
        fired: AtomicBool::new(false),
        next: AtomicU64::new(0),
    });
    let kb = d.ring.of(raced, true).await.unwrap();
    kb.check(true, true).await.unwrap();
    // "pw2" MUST still be retained in `pending` because its notification is outstanding!
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("pw2"));

    // Now the caller finishes updating stored password to "pw3" and rechecks.
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    kb.check(true, true).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &sk.combine_passphrase("pw3")).unwrap().is_some());
    assert_eq!(kb.open(&ka.seal(b"notify-before-update").unwrap()).unwrap(), b"notify-before-update");
}

#[tokio::test]
async fn two_factor_key_file_rejects_epoch_rollback_and_allows_equal_or_newer() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw1");
    let sk = a.secrets.secret_key.lock().unwrap().clone().unwrap();
    let ka = a.key(&file).await.unwrap();

    // Advance epoch from 0 -> 1 via password change, then save epoch 0 snapshot.
    let epoch0_body = file.file.lock().unwrap().clone().unwrap().0;
    a.ring.password_changed(Some("pw1".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("pw2".into());
    ka.check(true, true).await.unwrap();
    assert_eq!(a.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // Change back to pw1 (epoch 2) so epoch0_body opens with current (pw1, sk)
    // but carries stale epoch 0 < recorded floor 2.
    a.ring.password_changed(Some("pw2".into())).await.unwrap();
    *a.secrets.password.lock().unwrap() = Some("pw1".into());
    ka.check(true, true).await.unwrap();
    assert_eq!(a.secrets.epochs.lock().unwrap().get("account"), Some(&2));
    let epoch2_body = file.file.lock().unwrap().clone().unwrap().0;

    // Server replays epoch 0 file -> MUST be rejected as Untrusted.
    *file.file.lock().unwrap() = Some((epoch0_body, "v-rollback".into()));
    let err = ka.check(true, true).await.unwrap_err();
    assert!(matches!(err, Error::Untrusted(_)), "expected Untrusted, got {err:?}");

    // Equal epoch (epoch 2) from another device merges cleanly.
    let b = Device::new("pw1");
    *b.secrets.secret_key.lock().unwrap() = Some(sk);
    *file.file.lock().unwrap() = Some((epoch2_body, "v-equal".into()));
    b.key(&file).await.unwrap();
    ka.check(true, true).await.unwrap();
}

#[tokio::test]
async fn stale_probe_cannot_mark_missing_after_successful_open() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    let sk = a.secrets.secret_key.lock().unwrap().clone().unwrap();
    a.key(&file).await.unwrap();

    // Device starts without secret key; probe starts reading while another task
    // imports the secret key and opens the key file before the probe returns.
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = None;

    let read_started = Arc::new(Notify::new());
    let release_read = Arc::new(Notify::new());
    struct SlowProbeFile {
        inner: Arc<MemKeyFile>,
        started: Arc<Notify>,
        release: Arc<Notify>,
    }
    impl KeyFile for SlowProbeFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(false) })
        }
    }

    let probe_ring = b.ring.clone();
    let probe_file = Arc::new(SlowProbeFile {
        inner: file.clone(),
        started: read_started.clone(),
        release: release_read.clone(),
    });
    let probe = tokio::spawn(async move { probe_ring.sealed_with_secret_key(probe_file).await.unwrap() });
    read_started.notified().await;

    // Import secret key and open successfully while probe is in flight.
    b.ring.store_secret_key(&sk).await.unwrap();
    b.key(&file).await.unwrap();
    assert!(b.ring.secret_key_missing().borrow().is_empty());

    release_read.notify_one();
    assert!(probe.await.unwrap());
    // Stale probe must NOT mark the opened key missing again.
    assert!(b.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn rotate_uses_verified_credential_across_concurrent_password_change() {
    let inner = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let key = d.key(&inner).await.unwrap();

    // Mutate the stored password immediately after `check_locked` validates the
    // remote version under `pw1` and BEFORE `rotate` seals the rotated file.
    let ring = d.ring.clone();
    let secrets = d.secrets.clone();
    key.rotate_after_check(move || {
        Box::pin(async move {
            ring.password_changed(Some("pw1".into())).await?;
            *secrets.password.lock().unwrap() = Some("pw2".into());
            Ok(())
        })
    })
    .await
    .unwrap();

    // Rotate sealed with pw1 (matching epoch 0 and pending["account"] = "pw1").
    let raw_after_rotate = inner.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_after_rotate, &sk.combine_passphrase("pw1")).unwrap().is_some());

    // Subsequent check migrates cleanly from pw1 -> pw2 at epoch 1, preserving the rotated key.
    let sealed_with_rotated = key.seal(b"after-rotate").unwrap();
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw_after_migrate = inner.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw_after_migrate, &sk.combine_passphrase("pw2")).unwrap().is_some());
    assert_eq!(key.open(&sealed_with_rotated).unwrap(), b"after-rotate");
}

#[tokio::test]
async fn detached_handle_failures_return_errors_without_mutating_replacement_status() {
    let file_old = Arc::new(MemKeyFile::default());
    let file_new = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw-good");
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    writer.ring.of(Arc::new(KeyFileOf(file_new.clone(), "remote".into())), true).await.unwrap();

    // Seed file_old with another password/secret key so old_handle fails even while
    // device credentials remain healthy for replacement (`file_new`).
    let other_writer = Device::new("pw-other");
    let other_sk = other_writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    other_writer.ring.of(Arc::new(KeyFileOf(file_old.clone(), "remote".into())), true).await.unwrap();

    let d = Device::new("pw-other");
    *d.secrets.secret_key.lock().unwrap() = Some(other_sk);
    let old_handle = d.ring.of(Arc::new(KeyFileOf(file_old.clone(), "remote".into())), true).await.unwrap();

    // Switch credentials/remote to `file_new`: release old_handle and open healthy replacement.
    d.ring.release("remote");
    *d.secrets.password.lock().unwrap() = Some("pw-good".into());
    *d.secrets.secret_key.lock().unwrap() = Some(sk);
    let _replacement = d.ring.of(Arc::new(KeyFileOf(file_new.clone(), "remote".into())), true).await.unwrap();
    assert!(d.ring.mismatch().borrow().is_empty());
    assert!(d.ring.secret_key_missing().borrow().is_empty());

    // Detached old_handle against `file_old` fails with PasswordMismatch while replacement stays healthy.
    assert!(matches!(old_handle.check(true, true).await, Err(Error::PasswordMismatch(ref id)) if id == "remote"));
    assert!(d.ring.mismatch().borrow().is_empty(), "detached handle must not mark replacement mismatched");

    // Detached old_handle with missing secret key fails with SecretKeyMissing without mutating ring status.
    *d.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(old_handle.check(true, true).await, Err(Error::SecretKeyMissing)));
    assert!(d.ring.secret_key_missing().borrow().is_empty(), "detached handle must not mark replacement missing");
}

#[tokio::test]
async fn set_epoch_2fa_enforces_epoch_floor_under_lock_and_forget_clears_it() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw1");
    let key = d.key(&file).await.unwrap();

    // Advance remote and stored floor to epoch 1 via password change.
    d.ring.password_changed(Some("pw1".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw2".into());
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // Equal epoch (1) remains valid during rotate.
    key.rotate().await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&1));

    // If stored floor advances to 2 while rotate is in flight at epoch 1,
    // persisting epoch 1 under `epochs_lock` must be rejected with Untrusted
    // and must NOT rewind the stored floor.
    let secrets = d.secrets.clone();
    let err = key
        .rotate_after_check(move || {
            Box::pin(async move {
                secrets.epochs.lock().unwrap().insert("account".into(), 2);
                Ok(())
            })
        })
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Untrusted(_)), "expected Untrusted on epoch floor rollback, got {err:?}");
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&2));

    // Higher epoch (3) remains valid when sealed above the floor.
    d.ring.password_changed(Some("pw2".into())).await.unwrap();
    *d.secrets.password.lock().unwrap() = Some("pw3".into());
    let sk = fl_lkc::secret_key::SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let new_id = {
        use age::secrecy::ExposeSecret;
        age::x25519::Identity::generate().to_string().expose_secret().to_string()
    };
    let epoch3_body = crate::key::seal_with_password(format!("# test, epoch 3\n{new_id}").as_bytes(), &sk.combine_passphrase("pw3")).unwrap();
    *file.file.lock().unwrap() = Some((epoch3_body, "v-epoch3".into()));
    key.check(true, true).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&3));

    // `forget` clears the stored floor, allowing a fresh epoch-0 file.
    d.ring.forget("account").await.unwrap();
    assert!(!d.secrets.epochs.lock().unwrap().contains_key("account"));
    *file.file.lock().unwrap() = None;
    let fresh = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.epochs.lock().unwrap().get("account"), Some(&0));
    assert_eq!(fresh.open(&fresh.seal(b"fresh").unwrap()).unwrap(), b"fresh");
}

#[tokio::test]
async fn probe_invalidation_is_scoped_per_remote_and_stale_handle_cannot_clear_missing() {
    let file_a = Arc::new(MemKeyFile::default());
    let file_b = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw");
    writer.ring.of(Arc::new(KeyFileOf(file_a.clone(), "remote-a".into())), true).await.unwrap();
    writer.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true).await.unwrap();

    // Device has no secret key: probe remote-a while remote-b is released.
    let reader = Device::new("pw");
    *reader.secrets.secret_key.lock().unwrap() = None;

    let read_started = Arc::new(Notify::new());
    let release_read = Arc::new(Notify::new());
    struct SlowProbe {
        id: String,
        inner: Arc<MemKeyFile>,
        started: Arc<Notify>,
        release: Arc<Notify>,
    }
    impl KeyFile for SlowProbe {
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
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(false) })
        }
    }

    let r_probe = reader.ring.clone();
    let probe_file_a = Arc::new(SlowProbe {
        id: "remote-a".into(),
        inner: file_a.clone(),
        started: read_started.clone(),
        release: release_read.clone(),
    });
    let probe_a = tokio::spawn(async move { r_probe.sealed_with_secret_key(probe_file_a).await.unwrap() });
    read_started.notified().await;

    // Activity on unrelated remote-b MUST NOT suppress remote-a's said_missing.
    reader.ring.release("remote-b");
    release_read.notify_one();
    assert!(probe_a.await.unwrap());
    assert!(reader.ring.secret_key_missing().borrow().contains("remote-a"));

    // A stale handle opened after release must not clear missing status for the same id.
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();
    let owner = Device::new("pw");
    *owner.secrets.secret_key.lock().unwrap() = Some(sk);
    let old_handle = owner.ring.of(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into())), true).await.unwrap();
    owner.ring.release("remote-b");
    // Probe remote-b without SK to mark it missing under the new state.
    *owner.secrets.secret_key.lock().unwrap() = None;
    assert!(owner.ring.sealed_with_secret_key(Arc::new(KeyFileOf(file_b.clone(), "remote-b".into()))).await.unwrap());
    assert!(owner.ring.secret_key_missing().borrow().contains("remote-b"));
    // Restore SK and reopen the detached old handle: it is no longer registered,
    // so it must not clear the ring's missing status.
    *owner.secrets.secret_key.lock().unwrap() = writer.secrets.secret_key.lock().unwrap().clone();
    old_handle.check(true, true).await.unwrap();
    assert!(owner.ring.secret_key_missing().borrow().contains("remote-b"));
}

#[tokio::test]
async fn rotate_and_merge_coordinate_with_secret_key_import_and_reject_reserved_ids() {
    let d = Device::new("pw");
    let inner = Arc::new(MemKeyFile::default());
    let handle = d.key(&inner).await.unwrap();
    let before = inner.file.lock().unwrap().clone();

    // 1. Concurrent `store_secret_key` after `rotate` verified old key MUST reject the stale rotation PUT!
    let new_sk = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    let ring_c = d.ring.clone();
    let sk_c = new_sk.clone();
    let err = handle
        .rotate_after_check(move || {
            Box::pin(async move {
                ring_c.store_secret_key(&sk_c).await?;
                Ok(())
            })
        })
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Host(_)));
    assert_eq!(*inner.file.lock().unwrap(), before, "rotation under stale secret key must not overwrite remote");

    // 2. Reserved `2fa:` and `intent:` remote IDs are rejected at entry so they can never collide with epoch/pending keys.
    struct BadIdKeyFile(&'static str);
    impl KeyFile for BadIdKeyFile {
        fn id(&self) -> String {
            self.0.into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(None) })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(Some("v1".into())) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }
    let epochs_before = d.secrets.epochs.lock().unwrap().clone();
    assert!(d.ring.of(Arc::new(BadIdKeyFile("2fa:account")), true).await.is_err());
    assert!(d.ring.of(Arc::new(BadIdKeyFile("intent:account")), true).await.is_err());
    assert!(d.ring.of(Arc::new(BadIdKeyFile("ext-intent:account")), true).await.is_err());
    assert!(d.ring.forget("2fa:account").await.is_err());
    assert!(d.ring.forget("ext-intent:account").await.is_err());
    assert_eq!(*d.secrets.epochs.lock().unwrap(), epochs_before);
}

#[tokio::test]
async fn merge_coordinates_with_secret_key_import_via_take() {
    use fl_lkc::secret_key::SecretKey;

    let d = Device::new("pw");
    let sk_old = SecretKey::parse(d.secrets.secret_key.lock().unwrap().as_deref().unwrap()).unwrap();
    let sk_new = SecretKey::generate();
    let sk_new_str = sk_new.format().to_string();

    let writes: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
    let inner = Arc::new(MemKeyFile::default());
    struct RecordingKeyFile {
        inner: Arc<MemKeyFile>,
        writes: Arc<Mutex<Vec<Vec<u8>>>>,
    }
    impl KeyFile for RecordingKeyFile {
        fn id(&self) -> String {
            "merge-remote".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async { Ok(self.inner.file.lock().unwrap().clone()) })
        }
        fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            self.writes.lock().unwrap().push(body.clone());
            Box::pin(async move {
                let mut cur = self.inner.file.lock().unwrap();
                let current_ver = cur.as_ref().map(|(_, v)| v.clone());
                if current_ver != if_version {
                    return Ok(None);
                }
                let next_ver = format!("v{}", self.writes.lock().unwrap().len());
                *cur = Some((body, next_ver.clone()));
                Ok(Some(next_ver))
            })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }

    let kf = Arc::new(RecordingKeyFile { inner: inner.clone(), writes: writes.clone() });
    let handle = d.ring.of(kf, true).await.unwrap();
    writes.lock().unwrap().clear();

    // Another device overwrites the remote key file with a DIFFERENT identity, still sealed under `sk_old`.
    let other_dev = Device::new("pw");
    *other_dev.secrets.secret_key.lock().unwrap() = Some(sk_old.format().to_string());
    let other_kf = Arc::new(MemKeyFile::default());
    let _ = other_dev.key(&other_kf).await.unwrap();
    let (other_body, _) = other_kf.file.lock().unwrap().clone().unwrap();
    *inner.file.lock().unwrap() = Some((other_body, "v-other".into()));

    // Pause inside `SyncKey::take` after reading the file with the different identity,
    // import `sk_new`, and replace the remote file with one sealed under `sk_new` so
    // `take`'s active-key check rejects the stale `sk_old` merge PUT and retries cleanly under `sk_new`!
    let paused = Arc::new(Notify::new());
    let resume = Arc::new(Notify::new());
    let paused_c = paused.clone();
    let resume_c = resume.clone();
    handle.set_before_take_merge(move || {
        let p = paused_c.clone();
        let r = resume_c.clone();
        Box::pin(async move {
            p.notify_one();
            r.notified().await;
        })
    });

    let check_handle = handle.clone();
    let check_task = tokio::spawn(async move { check_handle.check(true, true).await });
    paused.notified().await;

    // Import `sk_new` while `take` is paused, and update remote file to another identity sealed under `sk_new`.
    d.ring.store_secret_key(&sk_new_str).await.unwrap();
    let other_new_dev = Device::new("pw");
    *other_new_dev.secrets.secret_key.lock().unwrap() = Some(sk_new_str.clone());
    let other_new_kf = Arc::new(MemKeyFile::default());
    let _ = other_new_dev.key(&other_new_kf).await.unwrap();
    let (other_new_body, _) = other_new_kf.file.lock().unwrap().clone().unwrap();
    *inner.file.lock().unwrap() = Some((other_new_body, "v-new-other".into()));

    resume.notify_one();
    check_task.await.unwrap().unwrap();

    // Every merge PUT performed MUST open with `sk_new` and NEVER with `sk_old`!
    let recorded = writes.lock().unwrap();
    assert_eq!(recorded.len(), 1, "expected exactly one retried merge PUT under new secret key");
    assert!(crate::key::open_with_password(&recorded[0], &sk_old.combine_passphrase("pw")).unwrap().is_none());
    assert!(crate::key::open_with_password(&recorded[0], &sk_new.combine_passphrase("pw")).unwrap().is_some());
}

#[tokio::test]
async fn identities_whose_save_failed_are_saved_by_the_next_check() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    let rotating = a.key(&file).await.unwrap();
    let b = Device::new("pw");
    *b.secrets.secret_key.lock().unwrap() = a.secrets.secret_key.lock().unwrap().clone();
    let key = b.key(&file).await.unwrap();
    rotating.rotate().await.unwrap();
    let newest = |d: &Device| d.secrets.kept.lock().unwrap().get("account").and_then(|k| k.lines().next().map(str::to_string));

    b.secrets.fail_set_kept.store(true, Ordering::SeqCst);
    assert!(key.check(true, true).await.is_err());
    b.secrets.fail_set_kept.store(false, Ordering::SeqCst);
    key.check(true, true).await.unwrap();
    assert_eq!(newest(&b), newest(&a), "the rotated key is kept here once saving works again");
}

#[tokio::test]
async fn a_failed_restore_keeps_the_handle_a_concurrent_lookup_took() {
    struct GatedFile {
        inner: Arc<MemKeyFile>,
        started: Arc<Notify>,
        release: Arc<Notify>,
    }
    impl KeyFile for GatedFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let (started, release) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
    let gated = Arc::new(GatedFile { inner: file.clone(), started: started.clone(), release: release.clone() });
    let ring = d.ring.clone();
    let restore = tokio::spawn(async move { ring.of(gated, false).await });
    started.notified().await;
    // A creating lookup takes the same handle while the restore reads.
    let ring = d.ring.clone();
    let creating = tokio::spawn({
        let file = file.clone();
        async move { ring.of(Arc::new(KeyFileOf(file, "account".into())), true).await }
    });
    tokio::task::yield_now().await;
    release.notify_one();
    assert!(matches!(restore.await.unwrap(), Err(Error::KeyNotHere(_))));
    let made = creating.await.unwrap().unwrap();
    let again = d.ring.of(Arc::new(KeyFileOf(file, "account".into())), false).await.unwrap();
    assert!(Arc::ptr_eq(&made, &again), "the handle the creating lookup returned stays registered");
}

#[tokio::test]
async fn a_failed_restore_leaves_no_handle_even_while_a_recheck_runs() {
    struct GatedFile {
        inner: Arc<MemKeyFile>,
        started: Arc<Notify>,
        release: Arc<Notify>,
    }
    impl KeyFile for GatedFile {
        fn id(&self) -> String {
            "account".into()
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
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let (started, release) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
    let gated = Arc::new(GatedFile { inner: file.clone(), started: started.clone(), release: release.clone() });
    let ring = d.ring.clone();
    let restore = tokio::spawn(async move { ring.of(gated, false).await });
    started.notified().await;
    let ring = d.ring.clone();
    let recheck = tokio::spawn(async move { ring.recheck().await });
    tokio::task::yield_now().await;
    release.notify_one();
    assert!(matches!(restore.await.unwrap(), Err(Error::KeyNotHere(_))));
    recheck.await.unwrap();
    assert!(file.file.lock().unwrap().is_none(), "nothing is put where only a restore looked");
    assert!(d.ring.mismatch().borrow().is_empty());
}

#[tokio::test]
async fn the_last_of_two_failed_restores_leaves_no_handle() {
    struct GatedFile {
        inner: Arc<MemKeyFile>,
        started: Arc<Notify>,
        release: Arc<Notify>,
    }
    impl KeyFile for GatedFile {
        fn id(&self) -> String {
            "account".into()
        }
        fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
            Box::pin(async {
                self.started.notify_one();
                self.release.notified().await;
                Ok(self.inner.file.lock().unwrap().clone())
            })
        }
        fn write(&self, _: Vec<u8>, _: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
            Box::pin(async { Ok(true) })
        }
    }
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let (started, release) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
    let gated = || Arc::new(GatedFile { inner: file.clone(), started: started.clone(), release: release.clone() });
    let (ring, first) = (d.ring.clone(), gated());
    let first = tokio::spawn(async move { ring.of(first, false).await });
    started.notified().await;
    let (ring, second) = (d.ring.clone(), gated());
    let second = tokio::spawn(async move { ring.of(second, false).await });
    tokio::task::yield_now().await;
    release.notify_one();
    assert!(matches!(first.await.unwrap(), Err(Error::KeyNotHere(_))));
    started.notified().await;
    release.notify_one();
    assert!(matches!(second.await.unwrap(), Err(Error::KeyNotHere(_))));
    // Only a registered handle's remote takes a password change.
    d.ring.password_changed(Some("old".into())).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("account"), "no handle stays registered");
}

#[tokio::test]
async fn a_handle_a_failed_restore_unregisters_says_nothing_more() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    a.key(&file).await.unwrap();
    let b = Device::new("other");
    *b.secrets.secret_key.lock().unwrap() = a.secrets.secret_key.lock().unwrap().clone();
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));
    assert!(b.ring.mismatch().borrow().contains("account"));
    assert!(matches!(b.ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), false).await, Err(Error::PasswordMismatch(_))));
    assert!(b.ring.mismatch().borrow().is_empty(), "no handle is left to say it of");
}
