use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct MemKeeper {
    saved: Mutex<String>,
    fail: AtomicBool,
}

impl MemKeeper {
    fn new() -> Arc<Self> {
        Arc::new(Self { saved: Mutex::new(String::new()), fail: AtomicBool::new(false) })
    }
}

impl VersionKeeper for MemKeeper {
    fn save(&self, json: String) -> BoxFuture<'_, Result<(), String>> {
        if self.fail.load(Ordering::SeqCst) {
            return Box::pin(async { Err("disk full".into()) });
        }
        *self.saved.lock().unwrap() = json;
        Box::pin(async { Ok(()) })
    }
}

struct MemSource {
    key: Mutex<Option<AccountKey>>,
    reads: AtomicUsize,
}

impl KeySource for MemSource {
    fn fetch(&self) -> BoxFuture<'_, Option<AccountKey>> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        let key = self.key.lock().unwrap().clone();
        Box::pin(async move { key })
    }
}

fn auth_for(key: AccountKey) -> (PersonalAuth, Arc<MemKeeper>) {
    let keeper = MemKeeper::new();
    let auth = PersonalAuth::new(key, PersonalVersions::from_json("").unwrap(), keeper.clone());
    (auth, keeper)
}

fn signed(key: &AccountKey, signature: String, version: Option<i64>) -> Signed {
    Signed { signer: key.user_id().into(), signing_key: key.signing_public(), signature, version }
}

async fn signed_batch(auth: &PersonalAuth, key: &AccountKey, seq: i64, idem: &str, body: &[u8]) -> Batch {
    let sig = auth.sign_batch("serverbox", idem, body).await;
    Batch { seq, body: body.to_vec(), epoch: None, idempotency_key: Some(idem.into()), signed: Some(signed(key, sig.signature, None)) }
}

async fn signed_snapshot(auth: &PersonalAuth, key: &AccountKey, log: &str, seq: i64, body: &[u8]) -> Snapshot {
    let sig = auth.sign_snapshot("serverbox", seq, body).await;
    Snapshot { log: log.into(), seq, signed: Some(signed(key, sig.signature, None)) }
}

/// Accepts or refuses every log, remembering what was persisted when asked.
struct TestObserver {
    accept: bool,
    keeper: Arc<MemKeeper>,
    observed: Mutex<Option<String>>,
    saved_at_commit: Mutex<Option<String>>,
}

impl TestObserver {
    fn new(accept: bool, keeper: &Arc<MemKeeper>) -> Self {
        Self { accept, keeper: keeper.clone(), observed: Mutex::new(None), saved_at_commit: Mutex::new(None) }
    }
}

impl LogObserver for TestObserver {
    fn commit(&self, log: &str) -> Result<bool, Error> {
        *self.saved_at_commit.lock().unwrap() = Some(self.keeper.saved.lock().unwrap().clone());
        if self.accept {
            *self.observed.lock().unwrap() = Some(log.into());
        }
        Ok(self.accept)
    }

    fn confirm(&self, log: &str) -> Result<bool, Error> {
        Ok(self.observed.lock().unwrap().as_deref() == Some(log))
    }
}

#[tokio::test]
async fn detached_snapshot_binding_is_persisted_only_once_accepted() {
    let key = AccountKey::generate("u1");
    let saved = |keeper: &MemKeeper| PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();

    // Refused: only the marker is persisted, never the binding.
    let (auth, keeper) = auth_for(key.clone());
    let snap = signed_snapshot(&auth, &key, "log-a", 5, b"snap").await;
    let observer = TestObserver::new(false, &keeper);
    assert!(!auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap());
    let v = saved(&keeper);
    assert!(v.signed_snapshots.contains("serverbox"));
    assert!(v.signed_log_ids.is_empty() && v.signed_log_from.is_empty(), "{v:?}");
    assert_eq!(auth.signed_log_id("serverbox").await, None);

    // A failed marker save stays dirty and is retried by `flush_pending_versions`.
    let (auth, keeper) = auth_for(key.clone());
    let observer = TestObserver::new(true, &keeper);
    keeper.fail.store(true, Ordering::SeqCst);
    assert_eq!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap_err().kind, Kind::Invalid);
    assert!(observer.saved_at_commit.lock().unwrap().is_none(), "observer asked before the marker was saved");
    keeper.fail.store(false, Ordering::SeqCst);
    auth.flush_pending_versions().await.unwrap();
    assert!(saved(&keeper).signed_snapshots.contains("serverbox"));

    // Accepted: nothing bound to the log is on disk when the observer
    // decides; a failed binding save neither succeeds nor leaves the
    // binding for a generic flush.
    keeper.fail.store(true, Ordering::SeqCst);
    assert_eq!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap_err().kind, Kind::Invalid);
    let at_commit = observer.saved_at_commit.lock().unwrap().clone().unwrap();
    assert!(!at_commit.contains("log-a"), "{at_commit}");
    assert_eq!(auth.signed_log_id("serverbox").await, None);
    keeper.fail.store(false, Ordering::SeqCst);
    auth.flush_pending_versions().await.unwrap();
    assert!(!keeper.saved.lock().unwrap().contains("log-a"));

    // Retried while still observed: the binding is persisted.
    assert!(auth.verify_snapshot_digest_for_detached("serverbox", &snap, &digest(b"snap"), &observer).await.unwrap());
    let v = saved(&keeper);
    assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
    assert_eq!(v.log_signed_from("serverbox"), Some(5));
}

#[tokio::test]
async fn an_observed_snapshot_on_another_log_than_the_recorded_one_binds_nothing() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());
    let on_a = signed_snapshot(&auth, &key, "log-a", 5, b"a").await;
    auth.verify_snapshot_digest("serverbox", &on_a, &digest(b"a")).await.unwrap();
    let on_b = signed_snapshot(&auth, &key, "log-b", 9, b"b").await;
    let observer = TestObserver::new(true, &keeper);
    assert!(!auth.verify_snapshot_digest_observed("serverbox", &on_b, &digest(b"b"), &observer).await.unwrap());
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("log-a"));
    assert!(observer.observed.lock().unwrap().is_none(), "the observation is untouched");
    assert!(PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap().signed_snapshots.contains("serverbox"), "its marker is kept");

    // Once log B is observed live, it takes the recorded one's place.
    *observer.observed.lock().unwrap() = Some("log-b".into());
    assert!(auth.verify_snapshot_digest_observed("serverbox", &on_b, &digest(b"b"), &observer).await.unwrap());
    assert_eq!(auth.signed_log_id("serverbox").await.as_deref(), Some("log-b"));
}

#[tokio::test]
async fn failed_binding_save_is_retried_against_the_observed_log() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key);
    auth.record_snapshot_seen("serverbox").await.unwrap();
    keeper.fail.store(true, Ordering::SeqCst);
    let accept = TestObserver::new(true, &keeper);
    assert_eq!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &accept).await.unwrap_err().kind, Kind::Invalid);
    keeper.fail.store(false, Ordering::SeqCst);
    auth.flush_pending_versions().await.unwrap();
    assert_eq!(auth.signed_log_id("serverbox").await, None);

    // Log B superseded A before the retry: the marker stays, A is never persisted.
    let refuse = TestObserver::new(false, &keeper);
    assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &refuse).await.unwrap());
    let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert!(v.signed_snapshots.contains("serverbox"));
    assert!(v.signed_log_ids.is_empty() && v.signed_log_from.is_empty(), "{v:?}");

    // A still observed: the retry persists its binding.
    assert!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &accept).await.unwrap());
    let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
    assert_eq!(v.log_signed_from("serverbox"), Some(5));
}

#[tokio::test]
async fn snapshot_binding_yields_to_a_log_observed_while_saved() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key);
    // Observed something else by the time the binding is saved.
    struct Moved;
    impl LogObserver for Moved {
        fn commit(&self, _: &str) -> Result<bool, Error> {
            Ok(true)
        }
        fn confirm(&self, _: &str) -> Result<bool, Error> {
            Ok(false)
        }
    }
    assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &Moved).await.unwrap());
    let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert!(v.signed_snapshots.contains("serverbox"));
    assert_eq!(v.signed_log_ids.get("serverbox"), None, "nothing stays bound to a log superseded while saved");
    assert!(auth.record_snapshot_if_log_compatible("serverbox", Some("log-a"), 5, &TestObserver::new(true, &keeper)).await.unwrap());
    // A known different log records only the marker, leaving its floor.
    assert!(!auth.record_snapshot_if_log_compatible("serverbox", Some("log-b"), 1, &TestObserver::new(true, &keeper)).await.unwrap());
    let v = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(v.signed_log_ids.get("serverbox").map(String::as_str), Some("log-a"));
    assert_eq!(v.log_signed_from("serverbox"), Some(5));
}

#[tokio::test]
async fn file_sign_verify_and_rollback_detection() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());

    let body1 = b"age-cipher-1";
    let signed1 = signed(&key, auth.sign_file("serverbox", "bak", 1, body1).await.signature, Some(1));
    auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap();
    assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 2);

    // Tampered body fails signature check.
    assert_eq!(auth.verify_file("serverbox", "bak", b"tampered", Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

    // Advance to version 2, then server attempts rollback to version 1.
    let body2 = b"age-cipher-2";
    let signed2 = signed(&key, auth.sign_file("serverbox", "bak", 2, body2).await.signature, Some(2));
    auth.verify_file("serverbox", "bak", body2, Some(&signed2), true).await.unwrap();
    assert_eq!(auth.verify_file("serverbox", "bak", body1, Some(&signed1), true).await.unwrap_err().kind, Kind::Untrusted);

    // Explicit historical version fetch verifies signature without rollback error.
    auth.verify_file("serverbox", "bak", body1, Some(&signed1), false).await.unwrap();

    // Stripping signature after seeing signed version is rejected — even for a new blob name!
    assert_eq!(auth.verify_file("serverbox", "bak", body2, None, true).await.unwrap_err().kind, Kind::Untrusted);
    assert_eq!(auth.verify_file("serverbox", "blob-new.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);

    // Persisted JSON restores the highest version.
    let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(reloaded.file_version("serverbox", "bak"), 2);
}

#[tokio::test]
async fn forged_key_and_stripped_batches_are_rejected() {
    let key = AccountKey::generate("u1");
    let attacker = AccountKey::generate("u1");
    let (auth, _) = auth_for(key.clone());

    // Attacker signs with a key not in u1's AccountKey history.
    let body = b"evil-batch";
    let msg = crypto::sync_batch_message("u1", "serverbox", 0, &digest(body), "idem-123456789012");
    let forged = Batch {
        seq: 1,
        body: body.to_vec(),
        epoch: None,
        idempotency_key: Some("idem-123456789012".into()),
        signed: Some(signed(&attacker, BASE64.encode(crypto::sign(attacker.signing(), &msg)), None)),
    };
    assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[forged]).await.unwrap_err().kind, Kind::Untrusted);

    let good = signed_batch(&auth, &key, 1, "idem-123456789012", body).await;
    auth.verify_batches("serverbox", Some("log1"), std::slice::from_ref(&good)).await.unwrap();

    // Stripped signature on a later batch rejected.
    let unsigned = Batch { seq: 3, signed: None, ..good };
    assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[unsigned]).await.unwrap_err().kind, Kind::Untrusted);
}

#[tokio::test]
async fn log_made_anew_reads_on() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());

    let batch = signed_batch(&auth, &key, 500, "idem-123456789012", b"op").await;
    auth.verify_batches("serverbox", Some("log-1"), std::slice::from_ref(&batch)).await.unwrap();
    auth.verify_snapshot("serverbox", &signed_snapshot(&auth, &key, "log-1", 500, b"snap-500").await, b"snap-500").await.unwrap();

    // Homebase made the log anew: seqs start at 1 again, a batch sent
    // again under its key lands at another seq, after a restart too.
    let restarted = PersonalAuth::new(key.clone(), PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap(), MemKeeper::new());
    restarted.verify_snapshot("serverbox", &signed_snapshot(&auth, &key, "log-2", 20, b"snap-20").await, b"snap-20").await.unwrap();
    restarted.verify_batches("serverbox", Some("log-2"), &[Batch { seq: 21, ..batch }]).await.unwrap();

    // Stripping a snapshot's signature stays refused at any seq, and the
    // new log holds no legacy batch below the old log's first signed one.
    let stripped = Snapshot { log: "log-2".into(), seq: 1, signed: None };
    assert_eq!(restarted.verify_snapshot("serverbox", &stripped, b"evil").await.unwrap_err().kind, Kind::Untrusted);
    let unsigned = Batch { seq: 3, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
    assert_eq!(restarted.verify_batches("serverbox", Some("log-2"), &[unsigned]).await.unwrap_err().kind, Kind::Untrusted);
}

#[tokio::test]
async fn versions_stay_small() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());
    for i in 0..50 {
        let name = format!("op-{i:04}.age");
        let s = signed(&key, auth.sign_file("serverbox", &name, 1, b"blob").await.signature, Some(1));
        auth.verify_blob("serverbox", &name, b"blob", Some(&s)).await.unwrap();
        auth.record_blob_written("serverbox").await.unwrap();
        let batch = signed_batch(&auth, &key, i + 1, &format!("idem-{i:012}"), b"op").await;
        auth.verify_batches("serverbox", Some("log1"), &[batch]).await.unwrap();
        auth.record_batch_written("serverbox", "log1", i + 100).await.unwrap();
    }
    let saved = keeper.saved.lock().unwrap().clone();
    assert!(saved.len() < 200, "{saved}");
    // An unsigned log blob is still refused.
    assert_eq!(auth.verify_blob("serverbox", "op-evil.age", b"evil", None).await.unwrap_err().kind, Kind::Untrusted);
}

#[tokio::test]
async fn mutable_file_named_with_op_prefix_keeps_version_watermark() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());

    let v1 = signed(&key, auth.sign_file("serverbox", "op-notes.age", 1, b"v1").await.signature, Some(1));
    auth.verify_file("serverbox", "op-notes.age", b"v1", Some(&v1), true).await.unwrap();
    assert_eq!(auth.next_file_version("serverbox", "op-notes.age").await.unwrap(), 2);

    // Persisting and reloading keeps the op-notes.age watermark intact.
    let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    assert_eq!(reloaded.file_version("serverbox", "op-notes.age"), 1);
    assert!(reloaded.requires_signature("serverbox", Some("op-notes.age")));

    let v2 = signed(&key, auth.sign_file("serverbox", "op-notes.age", 2, b"v2").await.signature, Some(2));
    auth.verify_file("serverbox", "op-notes.age", b"v2", Some(&v2), true).await.unwrap();
    assert_eq!(auth.next_file_version("serverbox", "op-notes.age").await.unwrap(), 3);

    // Rolling op-notes.age back to v1 is rejected.
    assert_eq!(auth.verify_file("serverbox", "op-notes.age", b"v1", Some(&v1), true).await.unwrap_err().kind, Kind::Untrusted);
}

#[test]
fn earlier_versions_are_read() {
    let json = r#"{"v":1,"files":{"serverbox/bak":3,"serverbox/op-1.age":1},"signed_files":["serverbox/identity.age","gptbox/op-2.age"],
        "signed_apps":["serverbox"],"signed_logs":["serverbox"],"signed_log_from":{"gptbox":7},"snapshots":{"gptbox":9},
        "taken":{"serverbox":{"idem-123456789012":4}}}"#;
    let v = PersonalVersions::from_json(json).unwrap();
    assert_eq!(v.file_version("serverbox", "bak"), 3);
    assert!(v.requires_signature("serverbox", Some("identity.age")));
    assert!(v.blob_requires_signature("serverbox"));
    assert!(v.blob_requires_signature("gptbox"));
    assert!(!v.requires_signature("gptbox", Some("bak")));
    assert_eq!(v.log_signed_from("serverbox"), Some(1));
    assert!(v.snapshot_requires_signature("gptbox", "log1", 1));
    let json = v.to_json();
    assert!(!json.contains("op-") && !json.contains("taken"), "{json}");
    assert_eq!(PersonalVersions::from_json(&json).unwrap(), v);
}

#[test]
fn v1_migration_preserves_mutable_op_prefixed_watermarks_and_migrates_blobs() {
    let json = r#"{
        "v": 1,
        "files": {
            "serverbox/op-notes.age": 1,
            "serverbox/op-deadbeef.age": 3,
            "serverbox/op-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.age": 1,
            "gptbox/op-0123456789abcdef-fedcba9876543210.age": 1
        },
        "signed_files": ["serverbox/op-deadbeef.age"]
    }"#;
    let v = PersonalVersions::from_json(json).unwrap();
    assert_eq!(v.file_version("serverbox", "op-notes.age"), 1);
    assert_eq!(v.file_version("serverbox", "op-deadbeef.age"), 3);
    assert_eq!(v.file_version("serverbox", "op-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.age"), 0);
    assert!(v.blob_requires_signature("serverbox"));
    assert!(v.blob_requires_signature("gptbox"));
    // Round-tripping v2 preserves all mutable op-* entries.
    let reloaded = PersonalVersions::from_json(&v.to_json()).unwrap();
    assert_eq!(reloaded.file_version("serverbox", "op-notes.age"), 1);
    assert_eq!(reloaded.file_version("serverbox", "op-deadbeef.age"), 3);
}

#[tokio::test]
async fn update_key_rejects_other_user_and_keeper_failure_does_not_advance() {
    let key = AccountKey::generate("u1");
    let other = AccountKey::generate("u2");
    let (auth, keeper) = auth_for(key.clone());

    assert_eq!(auth.update_key(other).await.unwrap_err().kind, Kind::Untrusted);

    // When keeper fails to persist, the version must not advance in memory.
    keeper.fail.store(true, Ordering::SeqCst);
    let body = b"cipher";
    let s = signed(&key, auth.sign_file("serverbox", "bak", 1, body).await.signature, Some(1));
    assert_eq!(auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap_err().kind, Kind::Invalid);
    assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
}

#[tokio::test]
async fn rotated_account_key_still_verifies_previous_signatures() {
    let old = AccountKey::generate("u1");
    let rotated = old.rotated();
    let (auth, _) = auth_for(rotated);
    let body = b"older-cipher";
    let msg = crypto::sync_file_message("u1", "serverbox", "bak", 0, 1, &digest(body));
    let s = signed(&old, BASE64.encode(crypto::sign(old.signing(), &msg)), Some(1));
    auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap();
}

#[tokio::test]
async fn key_rotated_elsewhere_is_read_again() {
    let old = AccountKey::generate("u1");
    let rotated = old.rotated();
    let source = Arc::new(MemSource { key: Mutex::new(Some(rotated.clone())), reads: AtomicUsize::new(0) });
    let auth = PersonalAuth::new(old.clone(), PersonalVersions::default(), MemKeeper::new()).with_key_source(source.clone());

    // Another device signed with the rotated key: read once, then known.
    let (writer, _) = auth_for(rotated.clone());
    let body = b"newer-cipher";
    let s = signed(&rotated, writer.sign_file("serverbox", "bak", 1, body).await.signature, Some(1));
    auth.verify_file("serverbox", "bak", body, Some(&s), true).await.unwrap();
    assert_eq!(source.reads.load(Ordering::SeqCst), 1);
    assert_eq!(auth.sign_file("serverbox", "bak", 2, body).await.signature, writer.sign_file("serverbox", "bak", 2, body).await.signature);

    // A key nobody of the account has: the file is read at most once per
    // interval, and meanwhile the write waits instead of being refused.
    let stranger = AccountKey::generate("u1");
    let (forger, _) = auth_for(stranger.clone());
    let f = signed(&stranger, forger.sign_file("serverbox", "bak", 3, body).await.signature, Some(3));
    for _ in 0..3 {
        assert_eq!(auth.verify_file("serverbox", "bak", body, Some(&f), true).await.unwrap_err().kind, Kind::Unreachable);
    }
    assert_eq!(source.reads.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_older_account_key_is_not_taken_back() {
    let old = AccountKey::generate("u1");
    let rotated = old.rotated();
    let source = Arc::new(MemSource { key: Mutex::new(Some(old)), reads: AtomicUsize::new(0) });
    let auth = PersonalAuth::new(rotated.clone(), PersonalVersions::default(), MemKeeper::new()).with_key_source(source.clone());

    let stranger = AccountKey::generate("u1");
    let (forger, _) = auth_for(stranger.clone());
    let f = signed(&stranger, forger.sign_file("serverbox", "bak", 1, b"x").await.signature, Some(1));
    assert_eq!(auth.verify_file("serverbox", "bak", b"x", Some(&f), true).await.unwrap_err().kind, Kind::Untrusted);
    assert_eq!(source.reads.load(Ordering::SeqCst), 1);
    let (holder, _) = auth_for(rotated);
    assert_eq!(auth.sign_file("serverbox", "bak", 1, b"x").await.signature, holder.sign_file("serverbox", "bak", 1, b"x").await.signature);
}

#[test]
fn default_personal_versions_round_trips_json() {
    let def = PersonalVersions::default();
    assert_eq!(PersonalVersions::from_json(&def.to_json()).unwrap(), def);
    assert_eq!(PersonalVersions::from_json("").unwrap(), def);
}

#[tokio::test]
async fn historical_file_marks_app_signed_without_advancing() {
    let key = AccountKey::generate("u1");
    let (auth, keeper) = auth_for(key.clone());

    let body = b"historical-v3";
    let s = signed(&key, auth.sign_file("serverbox", "bak", 3, body).await.signature, Some(3));
    auth.verify_file("serverbox", "bak", body, Some(&s), false).await.unwrap();

    assert_eq!(auth.next_file_version("serverbox", "bak").await.unwrap(), 1);
    assert!(auth.requires_signature("serverbox", None).await);

    // Subsequent unsigned response for the app is rejected (even after restart).
    let reloaded = PersonalVersions::from_json(&keeper.saved.lock().unwrap()).unwrap();
    let restarted = PersonalAuth::new(key, reloaded, MemKeeper::new());
    assert_eq!(restarted.verify_file("serverbox", "bak", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
    assert_eq!(restarted.verify_file("serverbox", "other.age", b"evil", None, true).await.unwrap_err().kind, Kind::Untrusted);
}

#[tokio::test]
async fn first_signed_log_write_preserves_legacy_backups_and_earlier_batches() {
    let key = AccountKey::generate("u1");
    let (auth, _) = auth_for(key.clone());

    // First signed log batch lands at seq 10.
    auth.record_batch_written("serverbox", "log1", 10).await.unwrap();
    // Pre-existing unsigned backup file remains readable until files migrate.
    auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
    // Unconsumed legacy unsigned batch from before seq 10 remains readable.
    let legacy_batch = Batch { seq: 9, body: b"legacy-op".to_vec(), epoch: None, idempotency_key: None, signed: None };
    auth.verify_batches("serverbox", Some("log1"), &[legacy_batch]).await.unwrap();
    // Unsigned batch at or past seq 10 is rejected.
    for seq in [10, 11] {
        let stripped = Batch { seq, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
        assert_eq!(auth.verify_batches("serverbox", Some("log1"), &[stripped]).await.unwrap_err().kind, Kind::Untrusted);
    }

    // Signing the sync key file and log blobs keeps the legacy backup
    // readable, here and for what asks whether it needs a signature,
    // while their own stripping is refused.
    auth.record_file_version("serverbox", "identity.age", 1).await.unwrap();
    auth.record_blob_written("serverbox").await.unwrap();
    assert!(!auth.requires_signature("serverbox", Some("srvbox_bak_v4.age")).await);
    assert!(!auth.requires_signature("serverbox", None).await);
    auth.verify_file("serverbox", "srvbox_bak_v4.age", b"legacy-backup", None, true).await.unwrap();
    assert_eq!(auth.verify_file("serverbox", "identity.age", b"stripped", None, true).await.unwrap_err().kind, Kind::Untrusted);
    assert_eq!(auth.verify_blob("serverbox", "op-def.age", b"stripped", None).await.unwrap_err().kind, Kind::Untrusted);

    // Upgrading from the legacy `signed_logs` marker keeps the threshold
    // at 1 even after observing a higher signed seq.
    let legacy_versions = PersonalVersions::from_json(r#"{"v":1,"signed_logs":["serverbox"]}"#).unwrap();
    let legacy_auth = PersonalAuth::new(key, legacy_versions, MemKeeper::new());
    legacy_auth.record_batch_written("serverbox", "log1", 50).await.unwrap();
    let low_unsigned = Batch { seq: 2, body: b"forged".to_vec(), epoch: None, idempotency_key: None, signed: None };
    assert_eq!(legacy_auth.verify_batches("serverbox", Some("log1"), &[low_unsigned]).await.unwrap_err().kind, Kind::Untrusted);
}

#[tokio::test]
async fn retained_blob_needs_its_binding_and_survives_signed_apps_but_not_a_name_seen_signed() {
    let key = AccountKey::generate("u1");
    let digest_of = |b: &[u8]| RetainedBinding::Digest(digest(b));
    let is_legacy = |b: &[u8]| b == b"legacy";
    let mismatch = |e: Error| e.kind == Kind::Untrusted && e.detail.ends_with(RETAINED_MISMATCH);

    // When only `signed_blobs` is set (ordinary files not locked to signed-only),
    // a retained pre-signing blob bound by digest or content remains readable while
    // strict blob reads reject unsigned.
    let blobs_only = PersonalVersions::from_json(r#"{"v":2,"signed_blobs":["serverbox"]}"#).unwrap();
    let auth_blobs = PersonalAuth::new(key.clone(), blobs_only, MemKeeper::new());
    auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, digest_of(b"legacy")).await.unwrap();
    auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, RetainedBinding::Content(&is_legacy)).await.unwrap();
    assert_eq!(
        auth_blobs.verify_blob("serverbox", "op-legacy.age", b"legacy", None).await.unwrap_err().kind,
        Kind::Untrusted
    );

    // Bytes that do not hold their binding are never accepted.
    assert!(mismatch(auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"swapped", None, digest_of(b"legacy")).await.unwrap_err()));
    assert!(mismatch(
        auth_blobs.verify_retained_blob("serverbox", "op-legacy.age", b"swapped", None, RetainedBinding::Content(&is_legacy)).await.unwrap_err()
    ));

    // `signed_apps` locks ordinary files and strict blob reads, but a bound retained
    // pre-signing blob stays readable so it can still be migrated.
    let apps_locked = PersonalVersions::from_json(r#"{"v":2,"signed_apps":["serverbox"],"signed_blobs":["serverbox"]}"#).unwrap();
    let auth_locked = PersonalAuth::new(key, apps_locked, MemKeeper::new());
    auth_locked.verify_retained_blob("serverbox", "op-legacy.age", b"legacy", None, digest_of(b"legacy")).await.unwrap();
    assert_eq!(
        auth_locked.verify_blob("serverbox", "op-legacy.age", b"legacy", None).await.unwrap_err().kind,
        Kind::Untrusted
    );

    // A name seen signed refuses an unsigned answer on the retained path, even one
    // holding its binding, and says so before the binding is looked at.
    auth_locked.record_named_blob_written("serverbox", "op-signed.age").await.unwrap();
    let err = auth_locked.verify_retained_blob("serverbox", "op-signed.age", b"stripped", None, digest_of(b"stripped")).await.unwrap_err();
    assert!(err.kind == Kind::Untrusted && err.detail.ends_with("server stripped signature"));
}
