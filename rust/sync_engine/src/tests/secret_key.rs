//! The client-side secret key and external commits.

use super::*;

#[tokio::test]
async fn secret_key_protects_key_file_and_migrates_legacy() {
    let file = Arc::new(MemKeyFile::default());
    // Device A starts without a secret key: one is generated and saved.
    let a = Device::new("weak123");
    *a.secrets.secret_key.lock().unwrap() = None;
    let ka = a.key(&file).await.unwrap();
    let generated = a.secrets.secret_key.lock().unwrap().clone().expect("secret key generated");
    assert!(generated.starts_with("S1-"));
    // The uploaded identity.age cannot be opened with the bare password alone.
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, "weak123").unwrap().is_none());

    // Device B has the password but no secret key: gets SecretKeyMissing.
    let b = Device::new("weak123");
    *b.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));

    // Device B imports the wrong secret key: gets PasswordMismatch.
    *b.secrets.secret_key.lock().unwrap() = Some(fl_lkc::secret_key::SecretKey::generate().format().to_string());
    b.ring.recheck().await;
    assert!(matches!(b.key(&file).await, Err(Error::PasswordMismatch(_))));

    // Device B imports Device A's secret key: opens the key and decrypts A's data.
    *b.secrets.secret_key.lock().unwrap() = Some(generated);
    b.ring.recheck().await;
    let kb = b.key(&file).await.unwrap();
    let sealed = ka.seal(b"ssh private key").unwrap();
    assert_eq!(kb.open(&sealed).unwrap(), b"ssh private key");

    // Legacy single-factor identity.age is opened and transparently upgraded.
    let legacy_file = Arc::new(MemKeyFile::default());
    let old_id = age::x25519::Identity::generate();
    let old_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 0\n{}", old_id.to_string().expose_secret())
    };
    *legacy_file.file.lock().unwrap() = Some((crate::key::seal_with_password(old_text.as_bytes(), "legacy-pw").unwrap(), "v1".into()));

    let c = Device::new("legacy-pw");
    *c.secrets.secret_key.lock().unwrap() = None;
    let kc = c.key(&legacy_file).await.unwrap();
    assert!(c.secrets.secret_key.lock().unwrap().is_some());
    // The remote key file is now re-sealed under two-factor (bare password fails).
    let upgraded = legacy_file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&upgraded, "legacy-pw").unwrap().is_none());
    let cipher = kc.seal(b"after upgrade").unwrap();
    assert_eq!(kc.open(&cipher).unwrap(), b"after upgrade");
}

#[tokio::test]
async fn secret_key_missing_stays_distinct_across_cache_and_recheck_and_blocks_bare_takeover() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("weak123");
    let ka = a.key(&file).await.unwrap();
    let sk_a = a.secrets.secret_key.lock().unwrap().clone().unwrap();

    // Device B has no secret key: first check AND cached second check both
    // report SecretKeyMissing (never PasswordMismatch), and recheck keeps it.
    let b = Device::new("weak123");
    *b.secrets.secret_key.lock().unwrap() = None;
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));
    assert!(b.ring.mismatch().borrow().is_empty());
    assert!(b.ring.secret_key_missing().borrow().contains("account"));
    // Second check within 60s cache window must STILL be SecretKeyMissing.
    assert!(matches!(b.key(&file).await, Err(Error::SecretKeyMissing)));
    b.ring.recheck().await;
    assert!(b.ring.mismatch().borrow().is_empty());
    assert!(b.ring.secret_key_missing().borrow().contains("account"));

    // Attacker guesses weak123 and injects a bare-password identity.age
    // containing an attacker X25519 key onto a remote that Device A already
    // opened with 2FA: Device A must refuse the bare-password downgrade!
    let attacker_id = age::x25519::Identity::generate();
    let attacker_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 99\n{}", attacker_id.to_string().expose_secret())
    };
    *file.file.lock().unwrap() = Some((crate::key::seal_with_password(attacker_text.as_bytes(), "weak123").unwrap(), "v-evil".into()));
    assert!(matches!(ka.check(true, true).await, Err(Error::PasswordMismatch(_))));
    // Remote file must NOT be re-sealed with attacker's key.
    let still = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&still, &fl_lkc::secret_key::SecretKey::parse(&sk_a).unwrap().combine_passphrase("weak123")).unwrap().is_none());

    // Pending password is preserved while secret key is missing, and completes
    // once the secret key is supplied.
    let file2 = Arc::new(MemKeyFile::default());
    let c = Device::new("old-pw");
    let _kc = c.key(&file2).await.unwrap();
    let sk_c = c.secrets.secret_key.lock().unwrap().clone().unwrap();
    c.ring.password_changed(Some("old-pw".into())).await.unwrap();
    *c.secrets.password.lock().unwrap() = Some("new-pw".into());
    *c.secrets.secret_key.lock().unwrap() = None;
    c.ring.recheck().await;
    assert_eq!(c.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("old-pw"));
    *c.secrets.secret_key.lock().unwrap() = Some(sk_c);
    c.ring.recheck().await;
    assert!(c.secrets.pending.lock().unwrap().is_empty());
    assert!(c.ring.mismatch().borrow().is_empty());
    assert!(c.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn disabling_auto_generate_pauses_legacy_upgrade_without_flagging_2fa_missing() {
    // 1. Empty remote with auto-generate disabled: no file created, no key generated.
    let empty_file = Arc::new(MemKeyFile::default());
    let d1 = Device::new("pw");
    *d1.secrets.secret_key.lock().unwrap() = None;
    d1.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(d1.key(&empty_file).await, Err(Error::SecretKeyMissing)));
    assert!(empty_file.file.lock().unwrap().is_none());
    assert!(d1.secrets.secret_key.lock().unwrap().is_none());
    assert!(d1.ring.secret_key_missing().borrow().is_empty());

    // 2. Legacy 1FA remote with auto-generate disabled: remote stays untouched,
    // secret_key_missing stays empty (not yet 2FA).
    let legacy_file = Arc::new(MemKeyFile::default());
    let old_id = age::x25519::Identity::generate();
    let old_text = {
        use age::secrecy::ExposeSecret;
        format!("# Test sync key, epoch 0\n{}", old_id.to_string().expose_secret())
    };
    let legacy_bytes = crate::key::seal_with_password(old_text.as_bytes(), "legacy-pw").unwrap();
    *legacy_file.file.lock().unwrap() = Some((legacy_bytes.clone(), "v1".into()));

    let a = Device::new("legacy-pw");
    *a.secrets.secret_key.lock().unwrap() = None;
    a.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(a.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert_eq!(legacy_file.file.lock().unwrap().as_ref().unwrap().0, legacy_bytes);
    assert!(a.secrets.secret_key.lock().unwrap().is_none());
    assert!(a.ring.secret_key_missing().borrow().is_empty());
    // Checks meanwhile wait for one instead of reading the file again.
    let reads = legacy_file.reads.load(Ordering::SeqCst);
    assert!(matches!(a.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert_eq!(legacy_file.reads.load(Ordering::SeqCst), reads);

    // Once user explicitly stores a key, Device A upgrades the legacy remote cleanly.
    let chosen = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    *a.secrets.secret_key.lock().unwrap() = Some(chosen.clone());
    let ka = a.key(&legacy_file).await.unwrap();
    let upgraded = legacy_file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&upgraded, "legacy-pw").unwrap().is_none());

    // 3. Device B with auto-generate disabled probes the already-2FA remote:
    // MUST mark secret_key_missing so UI switches to import-only.
    let b = Device::new("legacy-pw");
    *b.secrets.secret_key.lock().unwrap() = None;
    b.secrets.allow_auto_gen.store(false, Ordering::SeqCst);
    assert!(matches!(b.key(&legacy_file).await, Err(Error::SecretKeyMissing)));
    assert!(b.ring.secret_key_missing().borrow().contains("account"));

    // Importing Device A's key unlocks immediately.
    *b.secrets.secret_key.lock().unwrap() = Some(chosen);
    b.ring.recheck().await;
    let kb = b.key(&legacy_file).await.unwrap();
    assert_eq!(kb.open(&ka.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn candidate_secret_key_is_recovered_after_set_secret_key_failure() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);

    // Remote write commits, then `set_secret_key` fails: candidate key must stay staged.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert!(file.file.lock().unwrap().is_some());
    assert!(d.secrets.secret_key.lock().unwrap().is_none());
    let staged = d.secrets.pending_secret_key.lock().unwrap().clone().expect("candidate staged");

    // Once keychain recovers, retry opens the remote with the staged candidate,
    // persists it to `secret_key`, and clears the staging slot.
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert_eq!(k.open(&k.seal(b"recovered").unwrap()).unwrap(), b"recovered");
}

#[tokio::test]
async fn default_set_pending_secret_key_rejects_some_and_allows_none() {
    struct BareSecrets;
    impl Secrets for BareSecrets {
        fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn set_secret_key(&self, _: String) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn kept(&self, _: String) -> BoxFuture<'_, Result<Option<String>>> {
            Box::pin(async { Ok(None) })
        }
        fn set_kept(&self, _: String, _: String) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
            Box::pin(async { Ok(HashMap::new()) })
        }
        fn set_epochs(&self, _: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
            Box::pin(async { Ok(HashMap::new()) })
        }
        fn set_pending(&self, _: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
            Box::pin(async { Ok(()) })
        }
    }

    let s = BareSecrets;
    assert!(s.set_pending_secret_key(None).await.is_ok());
    assert!(matches!(s.set_pending_secret_key(Some("SK-123".into())).await, Err(Error::Host(_))));
}

#[tokio::test]
async fn open_rechecks_active_secret_key_before_refusing_as_missing() {
    // A remote already sealed with a secret key; `secret_key()` returns None on
    // the first call and Some(sk) on the recheck before refusal.
    let file = Arc::new(MemKeyFile::default());
    let writer = Device::new("pw");
    let kw = writer.key(&file).await.unwrap();
    let sk = writer.secrets.secret_key.lock().unwrap().clone().unwrap();

    struct LateKeySecrets {
        inner: Arc<MemSecrets>,
        sk: String,
        reads: AtomicU64,
    }
    impl Secrets for LateKeySecrets {
        fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.password()
        }
        fn secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            let n = self.reads.fetch_add(1, Ordering::SeqCst);
            let sk = if n == 0 { None } else { Some(self.sk.clone()) };
            Box::pin(async move { Ok(sk) })
        }
        fn set_secret_key(&self, key: String) -> BoxFuture<'_, Result<()>> {
            self.inner.set_secret_key(key)
        }
        fn pending_secret_key(&self) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.pending_secret_key()
        }
        fn set_pending_secret_key(&self, key: Option<String>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_pending_secret_key(key)
        }
        fn kept(&self, id: String) -> BoxFuture<'_, Result<Option<String>>> {
            self.inner.kept(id)
        }
        fn set_kept(&self, id: String, identities: String) -> BoxFuture<'_, Result<()>> {
            self.inner.set_kept(id, identities)
        }
        fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
            self.inner.epochs()
        }
        fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_epochs(epochs)
        }
        fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
            self.inner.pending()
        }
        fn set_pending(&self, pending: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
            self.inner.set_pending(pending)
        }
    }

    let inner = MemSecrets::with("pw");
    *inner.secret_key.lock().unwrap() = None;
    let ring = KeyRing::new(Arc::new(LateKeySecrets { inner, sk, reads: AtomicU64::new(0) }), "Test sync key");
    let kr = ring.of(Arc::new(KeyFileOf(file.clone(), "account".into())), false).await.unwrap();
    assert!(ring.secret_key_missing().borrow().is_empty());
    assert_eq!(kr.open(&kw.seal(b"late-key").unwrap()).unwrap(), b"late-key");
}

#[tokio::test]
async fn staged_secret_key_recovers_pending_password_change_even_when_upgraded_2fa() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("old-pw");
    *d.secrets.secret_key.lock().unwrap() = None;
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);

    // Remote write commits under ("old-pw", staged), then set_secret_key fails.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    let staged = d.secrets.pending_secret_key.lock().unwrap().clone().expect("candidate staged");
    let staged_sk = fl_lkc::secret_key::SecretKey::parse(&staged).unwrap();

    // Simulate upgraded_2fa already recorded + password changed from "old-pw" to "new-pw".
    d.secrets.epochs.lock().unwrap().insert("2fa:account".into(), 1);
    *d.secrets.password.lock().unwrap() = Some("new-pw".into());
    d.ring.password_changed(Some("old-pw".into())).await.unwrap();

    // While set_secret_key still fails, reseal writes under ("new-pw", staged),
    // clears stale "old-pw" from pending, updates epoch, and retains staged.
    assert!(matches!(d.key(&file).await, Err(Error::Host(_))));
    assert_eq!(d.secrets.pending_secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending.lock().unwrap().get("account").is_none());

    // A second password change ("new-pw" -> "third-pw") while set_secret_key
    // previously failed MUST record "new-pw" (matching the committed file),
    // never retaining stale "old-pw".
    *d.secrets.password.lock().unwrap() = Some("third-pw".into());
    d.ring.password_changed(Some("new-pw".into())).await.unwrap();
    assert_eq!(d.secrets.pending.lock().unwrap().get("account").map(String::as_str), Some("new-pw"));

    // Once keychain recovers, retry opens with ("new-pw", staged), reseals to
    // ("third-pw", staged) using the same staged key (no new key generated).
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let k = d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert!(d.secrets.pending.lock().unwrap().is_empty());
    let raw = file.file.lock().unwrap().clone().unwrap().0;
    assert!(crate::key::open_with_password(&raw, &staged_sk.combine_passphrase("third-pw")).unwrap().is_some());
    assert_eq!(k.open(&k.seal(b"resealed").unwrap()).unwrap(), b"resealed");
}

#[tokio::test]
async fn a_key_file_sealed_with_a_secret_key_is_told_without_writing() {
    let file = Arc::new(MemKeyFile::default());
    let a = Device::new("pw");
    let none = Device::new("pw");
    *none.secrets.secret_key.lock().unwrap() = None;
    let probe = || Arc::new(KeyFileOf(file.clone(), "account".into())) as Arc<dyn KeyFile>;
    assert!(!none.ring.sealed_with_secret_key(probe()).await.unwrap());

    a.key(&file).await.unwrap();
    let before = file.file.lock().unwrap().clone();
    assert!(none.ring.sealed_with_secret_key(probe()).await.unwrap());
    assert!(none.ring.secret_key_missing().borrow().contains("account"));
    assert_eq!(*file.file.lock().unwrap(), before);
    assert!(none.secrets.secret_key.lock().unwrap().is_none());

    // Asked again once a key is stored.
    none.ring.recheck().await;
    assert!(none.ring.secret_key_missing().borrow().is_empty());
}

#[tokio::test]
async fn store_secret_key_rejects_conflicting_import_after_staged_commit() {
    let inner = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    // Simulate a remote write that committed staged key A, then failed
    // `set_secret_key` (leaving A staged + 2fa marker written).
    d.secrets.fail_set_secret_key.store(true, Ordering::SeqCst);
    assert!(d.key(&inner).await.is_err());
    let staged_a = d.secrets.pending_secret_key.lock().unwrap().clone().expect("staged key A must remain");
    assert!(d.secrets.secret_key.lock().unwrap().is_none());

    // Conflicting import B must be rejected and must NOT clear or replace staged key A.
    d.secrets.fail_set_secret_key.store(false, Ordering::SeqCst);
    let key_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    assert!(d.ring.store_secret_key(&key_b).await.is_err());
    assert!(d.secrets.secret_key.lock().unwrap().is_none());
    assert_eq!(d.secrets.pending_secret_key.lock().unwrap().as_deref(), Some(staged_a.as_str()));

    // Recovery still promotes staged key A cleanly.
    let recovered = d.key(&inner).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(staged_a.as_str()));
    assert!(d.secrets.pending_secret_key.lock().unwrap().is_none());
    assert_eq!(recovered.open(&recovered.seal(b"ok").unwrap()).unwrap(), b"ok");
}

#[tokio::test]
async fn external_commit_staging_validates_candidate_and_tracks_concurrent_writes() {
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let stale = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    // No active or staged key yet: staging a stale candidate MUST be rejected.
    assert!(d.ring.stage_external_secret_key_commit(&stale).await.is_err());

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    assert!(d.ring.stage_external_secret_key_commit(&stale).await.is_err());

    // Two unresolved external writes stage the same current candidate and get distinct identities.
    let stage1 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    let stage2 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    assert_ne!(stage1, stage2);

    // Clearing stage1 (even twice) MUST consume only stage1, keeping stage2 protected.
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage1)).await.unwrap();
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage1)).await.unwrap();
    let other = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    assert!(d.ring.store_secret_key(&other).await.is_err());
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

    // An untokened recovery clear must NOT drop active stage2.
    d.ring.clear_external_secret_key_commit(&candidate, None).await.unwrap();
    assert!(d.ring.store_secret_key(&other).await.is_err());
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

    // Clearing stage2 settles all unresolved writes, permitting import.
    d.ring.clear_external_secret_key_commit(&candidate, Some(&stage2)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    d.ring.store_secret_key(&other).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(other.as_str()));

    // Once active key is `other`, staging stale `candidate` is rejected while `other` succeeds.
    assert!(d.ring.stage_external_secret_key_commit(&candidate).await.is_err());
    let stage3 = d.ring.stage_external_secret_key_commit(&other).await.unwrap();
    d.ring.clear_external_secret_key_commit(&other, Some(&stage3)).await.unwrap();
}

#[tokio::test]
async fn external_commit_settlement_decrements_per_write_and_same_key_import_preserves_guard() {
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    let conflicting = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage two concurrent external writes for the same candidate.
    let stage1 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();
    let stage2 = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();

    // Committing stage1 settles only stage1, keeping stage2 protected and the durable intent intact.
    d.ring.commit_secret_key(&candidate, Some(&stage1)).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(candidate.as_str()));
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Duplicate commit of stage1 must NOT consume stage2.
    d.ring.commit_secret_key(&candidate, Some(&stage1)).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // A same-key import while stage2 is still unsettled must preserve the stage and durable intent.
    d.ring.store_secret_key(&candidate).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Settling stage2 clears the durable intent and allows later replacement.
    d.ring.commit_secret_key(&candidate, Some(&stage2)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    d.ring.store_secret_key(&conflicting).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(conflicting.as_str()));
}

#[tokio::test]
async fn durable_external_intent_blocks_conflicting_import_after_restart_even_when_key_active() {
    let d1 = Device::new("pw");
    let active_a = d1.secrets.secret_key.lock().unwrap().clone().unwrap();
    let other_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage an external write for active key A, then simulate process restart with a fresh KeyRing
    // sharing the same durable secrets (in-memory `external_commits` is now empty).
    let _stage = d1.ring.stage_external_secret_key_commit(&active_a).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

    let restarted = KeyRing::new(d1.secrets.clone(), "test");
    // Conflicting import B MUST be rejected even though `active_a` is active and in-memory stages are empty.
    assert!(restarted.store_secret_key(&other_b).await.is_err());
    assert_eq!(d1.secrets.secret_key.lock().unwrap().as_deref(), Some(active_a.as_str()));

    // Same-key import A is allowed and MUST NOT clear the durable external intent.
    restarted.store_secret_key(&active_a).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(restarted.store_secret_key(&other_b).await.is_err());

    // Only settling the protected write clears the durable intent and allows replacement.
    restarted.commit_secret_key(&active_a, None).await.unwrap();
    assert!(!d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    restarted.store_secret_key(&other_b).await.unwrap();
    assert_eq!(d1.secrets.secret_key.lock().unwrap().as_deref(), Some(other_b.as_str()));
}

#[tokio::test]
async fn internal_key_commit_does_not_clear_unsettled_external_write_guard() {
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    *d.secrets.secret_key.lock().unwrap() = None;

    let candidate = d.ring.secret_key_candidate().await.unwrap();
    let conflicting = fl_lkc::secret_key::SecretKey::generate().format().to_string();
    let stage = d.ring.stage_external_secret_key_commit(&candidate).await.unwrap();

    // An internal key-file write promotes the same staged candidate, but must
    // NOT settle the unrelated in-flight external write.
    d.key(&file).await.unwrap();
    assert_eq!(d.secrets.secret_key.lock().unwrap().as_deref(), Some(candidate.as_str()));
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&conflicting).await.is_err());

    // Once the external write settles, the guard and intent clear.
    d.ring.commit_secret_key(&candidate, Some(&stage)).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    d.ring.store_secret_key(&conflicting).await.unwrap();
}

#[tokio::test]
async fn recovered_external_intent_survives_new_stage_settlement_until_recovered_settles() {
    let d1 = Device::new("pw");
    let active_a = d1.secrets.secret_key.lock().unwrap().clone().unwrap();
    let other_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage an external write for active key A before a simulated process restart.
    let _pre_restart = d1.ring.stage_external_secret_key_commit(&active_a).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

    // Fresh KeyRing after restart (`external_commits` starts empty while durable intent remains).
    let restarted = KeyRing::new(d1.secrets.clone(), "test");

    // Stage a new in-process write for the same candidate A, then clear that new stage:
    // the recovered pre-restart durable intent MUST remain protected!
    let new_stage1 = restarted.stage_external_secret_key_commit(&active_a).await.unwrap();
    restarted.clear_external_secret_key_commit(&active_a, Some(&new_stage1)).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(restarted.store_secret_key(&other_b).await.is_err());

    // Even settling a second in-process stage via `commit_secret_key(..., Some)` MUST NOT
    // clear the recovered pre-restart write's durable protection.
    let new_stage2 = restarted.stage_external_secret_key_commit(&active_a).await.unwrap();
    restarted.commit_secret_key(&active_a, Some(&new_stage2)).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(restarted.store_secret_key(&other_b).await.is_err());

    // Only settling the recovered write (`stage_id == None`) removes its durable intent
    // once no in-process stages remain.
    restarted.clear_external_secret_key_commit(&active_a, None).await.unwrap();
    assert!(!d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    restarted.store_secret_key(&other_b).await.unwrap();
    assert_eq!(d1.secrets.secret_key.lock().unwrap().as_deref(), Some(other_b.as_str()));
}

#[tokio::test]
async fn account_scoped_external_intents_isolate_accounts() {
    let d1 = Device::new("pw");
    let key_a = d1.secrets.secret_key.lock().unwrap().clone().unwrap();
    let key_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // 1. Account "u1" stages an external commit before process restart.
    let _s1 = d1.ring.stage_external_secret_key_commit_for(&key_a, Some("u1")).await.unwrap();
    let restarted = KeyRing::new(d1.secrets.clone(), "test");

    // Account "u2" attempting stage-less commit or clear with the same key MUST NOT clear "u1"'s intent!
    restarted.commit_secret_key_for(&key_a, None, Some("u2")).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    restarted.clear_external_secret_key_commit_for(&key_a, None, Some("u2")).await.unwrap();
    assert!(d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(restarted.store_secret_key(&key_b).await.is_err());

    // Account "u1" settling its own recovered intent clears it and unblocks replacement.
    restarted.commit_secret_key_for(&key_a, None, Some("u1")).await.unwrap();
    assert!(!d1.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

}

#[tokio::test]
async fn external_intent_namespace_isolated_from_folder_writes_and_forget() {
    let d = Device::new("pw");
    let key_a = d.secrets.secret_key.lock().unwrap().clone().unwrap();
    let key_b = fl_lkc::secret_key::SecretKey::generate().format().to_string();

    // Stage an external account-key commit (stored under `ext-intent:lkc-account-key`).
    let stage = d.ring.stage_external_secret_key_commit_for(&key_a, Some("u1")).await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));

    // A folder remote literally named `lkc-account-key` writes and is forgotten:
    // MUST NOT remove `ext-intent:lkc-account-key`!
    let folder_kf = Arc::new(KeyFileOf(Arc::new(MemKeyFile::default()), "lkc-account-key".into()));
    d.ring.of(folder_kf, true).await.unwrap();
    d.ring.forget("lkc-account-key").await.unwrap();
    assert!(d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    assert!(d.ring.store_secret_key(&key_b).await.is_err());

    d.ring.clear_external_secret_key_commit_for(&key_a, Some(&stage), Some("u1")).await.unwrap();
    assert!(!d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key"));
    d.ring.store_secret_key(&key_b).await.unwrap();
}

#[tokio::test]
async fn each_unresolved_external_write_of_one_account_settles_on_its_own_after_a_restart() {
    let d = Device::new("pw");
    let key = d.secrets.secret_key.lock().unwrap().clone().unwrap();
    d.ring.stage_external_secret_key_commit_for(&key, Some("u1")).await.unwrap();
    d.ring.stage_external_secret_key_commit_for(&key, Some("u1")).await.unwrap();
    let restarted = KeyRing::new(d.secrets.clone(), "test");
    let protected = || d.secrets.pending.lock().unwrap().contains_key("ext-intent:lkc-account-key");
    restarted.clear_external_secret_key_commit_for(&key, None, Some("u1")).await.unwrap();
    assert!(protected(), "the other write is still unresolved");
    restarted.clear_external_secret_key_commit_for(&key, None, Some("u1")).await.unwrap();
    assert!(!protected());
}
