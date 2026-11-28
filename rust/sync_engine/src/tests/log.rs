//! The log sync: ops, batches, joins and checkpoints.

use super::*;

#[tokio::test]
async fn devices_converge_on_the_log() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    a.host.edit("kv:setting", "theme", Some(json!("dark")));
    a.host.edit("server", "s1", Some(json!({"name": "one"})));
    b.host.edit("kv:setting", "font", Some(json!(14)));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
    assert_eq!(b.host.value("server", "s1"), Some(json!({"name": "one"})));
    assert_eq!(a.host.value("kv:setting", "font"), Some(json!(14)));
}

#[tokio::test]
async fn a_delete_goes_through_and_a_later_edit_wins() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    a.host.edit("server", "s1", Some(json!(1)));
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("server", "s1"), Some(json!(1)));
    a.host.edit("server", "s1", None);
    la.sync().await.unwrap();
    // Made after the delete: it stays, and goes to a.
    b.host.edit("server", "s1", Some(json!(2)));
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.value("server", "s1"), Some(json!(2)));
    assert_eq!(b.host.value("server", "s1"), Some(json!(2)));
}

#[tokio::test]
async fn an_older_op_does_not_overwrite_an_edit_here() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let (la, lb) = (a.log(&log, &file).await, b.log(&log, &file).await);
    a.host.edit("k", "x", Some(json!("a")));
    b.host.edit("k", "x", Some(json!("b")));
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    la.sync().await.unwrap();
    assert_eq!(a.host.value("k", "x"), Some(json!("b")));
    assert_eq!(b.host.value("k", "x"), Some(json!("b")));
}

#[tokio::test]
async fn a_large_record_goes_as_a_blob() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let big = "x".repeat(200 << 10);
    a.host.edit("chat", "c1/u1", Some(json!({"text": big})));
    a.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(log.lock().blobs.len(), 1);
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("chat", "c1/u1"), Some(json!({"text": big})));
}

#[tokio::test]
async fn many_records_split_into_batches_under_the_limit() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    // Random, so gzip leaves them their size: 60 KiB each, inline.
    for i in 0..20 {
        let mut noise = vec![0u8; 30 << 10];
        getrandom::fill(&mut noise).unwrap();
        let text: String = noise.iter().map(|b| format!("{b:02x}")).collect();
        a.host.edit("k", &format!("r{i}"), Some(json!(text)));
    }
    a.log(&log, &file).await.sync().await.unwrap();
    let batches = log.lock().batches.clone();
    assert!(batches.len() > 1);
    assert!(batches.iter().all(|(_, _, b)| b.len() <= crate::engine::BATCH_MAX));
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_device_joins_from_the_snapshot() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    for i in 0..4 {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        la.sync().await.unwrap();
    }
    assert!(log.lock().snapshot.is_some());
    log.drop_covered();
    let b = Device::new("pw");
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_full_log_is_compacted_then_sent() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().full_after = Some(2);
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    for i in 0..5 {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        la.sync().await.unwrap();
    }
    assert!(log.lock().snapshot.is_some());
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn an_unanswered_batch_is_sent_again_once() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    // Joined first (a log known): joining sends every record again.
    a.host.edit("k", "w", Some(json!(0)));
    la.sync().await.unwrap();
    a.host.edit("k", "x", Some(json!(1)));
    log.lose_answer.store(true, Ordering::SeqCst);
    assert!(la.sync().await.is_err());
    la.sync().await.unwrap();
    assert_eq!(log.lock().batches.len(), 2);
}

#[tokio::test]
async fn a_newer_batch_stops_the_read_but_not_the_send() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let key = a.key(&file).await.unwrap();
    let la = a.log(&log, &file).await;
    la.sync().await.unwrap();
    // A build after this one's.
    let newer = crate::engine::gzip(br#"{"v":3,"ops":[]}"#).unwrap();
    log.append("k".repeat(16), key.seal(&newer).unwrap()).await.unwrap();
    let lb = b.log(&log, &file).await;
    b.host.edit("k", "x", Some(json!(1)));
    assert!(matches!(lb.sync().await, Err(Error::TooNew(_))));
    assert!(*lb.too_new().borrow());
    // Sent all the same, after the batch this build does not read.
    assert_eq!(log.lock().batches.len(), 2);
}

#[tokio::test]
async fn an_unreadable_batch_is_passed_over() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    log.append("j".repeat(16), b"not age".to_vec()).await.unwrap();
    a.host.edit("k", "x", Some(json!(1)));
    la.sync().await.unwrap();
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("k", "x"), Some(json!(1)));
    assert!(b.host.lock().warnings.iter().any(|w| w.contains("unreadable batch 1")));
}

#[tokio::test]
async fn what_is_not_carried_here_is_kept_for_the_others() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let (a, b, c) = (Device::new("pw"), Device::new("pw"), Device::new("pw"));
    a.host.edit("kv:setting", "theme", Some(json!("dark")));
    a.log(&log, &file).await.sync().await.unwrap();
    // b does not sync settings, and writes the snapshot.
    b.host.lock().not_carried.insert("kv:setting".into());
    let lb = b.log(&log, &file).await;
    for i in 0..3 {
        b.host.edit("k", &format!("r{i}"), Some(json!(i)));
        lb.sync().await.unwrap();
    }
    assert_eq!(b.host.value("kv:setting", "theme"), None);
    log.drop_covered();
    c.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(c.host.value("kv:setting", "theme"), Some(json!("dark")));
}

#[tokio::test]
async fn what_this_build_does_not_keep_stays_in_the_log() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    log.lock().compact_after = 2;
    let (a, b, c) = (Device::new("pw"), Device::new("pw"), Device::new("pw"));
    a.host.edit("new:kind", "x", Some(json!(1)));
    a.log(&log, &file).await.sync().await.unwrap();
    // b is an older build: it writes the snapshot, and keeps a's record in it.
    b.host.lock().unkept.insert("new:kind".into());
    let lb = b.log(&log, &file).await;
    for i in 0..3 {
        b.host.edit("k", &format!("r{i}"), Some(json!(i)));
        lb.sync().await.unwrap();
    }
    assert_eq!(b.host.value("new:kind", "x"), None);
    log.drop_covered();
    c.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(c.host.value("new:kind", "x"), Some(json!(1)));
}

#[tokio::test]
async fn a_record_that_cannot_be_read_holds_the_send_back() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    let la = a.log(&log, &file).await;
    a.host.edit("k", "1", Some(json!(1)));
    a.host.edit("k", "2", Some(json!(2)));
    a.host.lock().unread.insert(("k".into(), "2".into()));
    la.sync().await.unwrap();
    let lb = b.log(&log, &file).await;
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("k", "1"), Some(json!(1)));
    assert_eq!(b.host.value("k", "2"), None);
    a.host.lock().unread.clear();
    la.sync().await.unwrap();
    lb.sync().await.unwrap();
    assert_eq!(b.host.value("k", "2"), Some(json!(2)));
}

#[tokio::test]
async fn a_rotated_key_reaches_a_device_that_holds_only_it() {
    let (log, file) = (MemLog::new(), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    let la = a.log(&log, &file).await;
    a.host.edit("k", "x", Some(json!(1)));
    la.sync().await.unwrap();
    let key = a.key(&file).await.unwrap();
    la.rotate(async { key.rotate().await }).await.unwrap();
    log.drop_covered();
    // b first meets the key now: only the newest would open the snapshot.
    let b = Device::new("pw");
    b.log(&log, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("k", "x"), Some(json!(1)));
}

#[tokio::test]
async fn another_account_is_read_anew() {
    let host = MemHost::new(99);
    host.set_state(vec![("log.cursor".into(), Some("5".into()))]).await.unwrap();
    LogSync::<MemHost, MemLog, SyncKey>::bind(&host, "a").await.unwrap();
    assert_eq!(host.state(vec!["log.cursor".into()]).await.unwrap(), vec![None]);
    host.set_state(vec![("log.cursor".into(), Some("5".into()))]).await.unwrap();
    LogSync::<MemHost, MemLog, SyncKey>::bind(&host, "a").await.unwrap();
    assert_eq!(host.state(vec!["log.cursor".into()]).await.unwrap(), vec![Some("5".into())]);
}


#[test]
fn rfc3339_reads_as_unix_ms() {
    assert_eq!(crate::lkc::rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(crate::lkc::rfc3339_ms("2026-11-10T08:00:00.5Z"), Some(1_794_297_600_500));
    assert_eq!(crate::lkc::rfc3339_ms("2026-11-10T16:00:00.500+08:00"), Some(1_794_297_600_500));
    assert_eq!(crate::lkc::rfc3339_ms("yesterday"), None);
}

#[test]
fn a_batch_reads_back_and_a_bad_one_is_unreadable() {
    let ops = vec![Op { c: "k".into(), id: "x".into(), h: Hlc { ms: 1, counter: 0, device: 2 }, d: Some(json!({"a": [1, 2]})) }];
    let (back, _) = crate::engine::parse(&crate::engine::encode(&ops, Default::default()).unwrap()).unwrap();
    assert_eq!(back, ops);
    assert!(matches!(crate::engine::parse(&crate::engine::gzip(br#"{"v":0,"ops":[]}"#).unwrap()), Err(Error::Unreadable(_))));
    assert!(matches!(crate::engine::parse(b"plain"), Err(Error::Unreadable(_))));
}

// What the Dart engine wrote reads here: the batch shape as `jsonEncode`
// wrote it, keys in its order.
#[test]
fn a_dart_batch_reads() {
    let json = br#"{"v":2,"ops":[{"c":"kv:setting","id":"theme","h":"0192f3a1b2c30000000000000000002a","d":"dark"},{"c":"server","id":"s1","h":"0192f3a1b2c30001000000000000002a","d":null}]}"#;
    let (ops, _) = crate::engine::parse(&crate::engine::gzip(json).unwrap()).unwrap();
    assert_eq!(ops.len(), 2);
    assert_eq!(ops[0].d, Some(json!("dark")));
    assert_eq!(ops[1].d, None);
    assert_eq!(ops[1].h.device, 42);
}

#[tokio::test]
async fn log_append_persist_failure_advances_checkpoint_without_resending() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Create 20 records with ~40 KiB incompressible hex payloads each (< 64 KiB
    // INLINE_MAX, ~400 KiB compressed > 250 KiB BATCH_MAX) so first join splits
    // into 2 batches.
    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key.clone());
    log.fail_persist_append.store(true, Ordering::SeqCst);
    // First-join batch 1 commits remotely (seq 1), local watermark save fails -> Host error.
    let err = sync.sync().await.unwrap_err();
    assert!(matches!(err, Error::Host(_)));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert_eq!(log.lock().batches.len(), 1);
    assert!(d.host.state(vec!["log.join_sent".into()]).await.unwrap()[0].is_some(), "non-final first-join batch must record join_sent");

    // Next sync MUST NOT resend committed batch 1; it appends only uncommitted batch 2.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    // Subsequent idle sync sends nothing (join complete).
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    // Steady-state append with local watermark save failure also advances checkpoint without resending.
    d.host.edit("servers", "steady", Some(json!({ "name": "box2" })));
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 3);
    assert_eq!(log.lock().batches.len(), 3);

    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 3);
    assert_eq!(log.lock().batches.len(), 3);

    // A second device sees all 21 committed records cleanly.
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    let sync2 = LogSync::new(d2.host.clone(), log.clone(), k2);
    sync2.sync().await.unwrap();
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn same_hlc_first_join_batches_do_not_drop_records_on_partial_failure() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    // Seed 20 adopted/legacy records sharing the exact same Hlc::ZERO so first
    // join splits them across 2 batches with identical HLCs.
    let zero = Hlc::ZERO;
    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.lock().records.insert(("servers".into(), format!("s{i:02}")), (zero, Some(json!({ "blob": payload }))));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);

    // Next sync resumes strictly after `(h, c, id)` of batch 1's last record,
    // sending all remaining Hlc::ZERO records in batch 2 without dropping any.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2);
    assert_eq!(log.lock().batches.len(), 2);

    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values().len(), 20);
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn recreated_log_does_not_mark_joined_from_stale_unanswered_batch() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i:02}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    // Batch 1 commits on log-1; simulate batch 2 failing with a lost answer
    // after batch 1 commits by first failing persist on batch 1, then losing
    // the answer on batch 2.
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.lock().batches.len(), 1);

    log.lose_answer.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Remote(_))));

    // Server recreates the log as "log-2" (empty).
    {
        let mut s = log.lock();
        s.log = "log-2".into();
        s.batches.clear();
        s.dropped = 0;
        s.snapshot = None;
    }

    // Next sync pulls Compacted(log-2), retries unanswered batch 2 on log-2,
    // MUST NOT mark log-2 as JOINED from batch 2 alone, and sends all records
    // (including batch 1's) onto log-2.
    sync.sync().await.unwrap();
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values().len(), 20);
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn join_retry_landing_on_new_log_does_not_mark_new_log_joined() {
    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();

    for i in 0..20u32 {
        let mut payload = String::with_capacity(40_000);
        let mut h = blake3::Hasher::new();
        h.update(&i.to_le_bytes());
        let mut reader = h.finalize_xof();
        let mut buf = [0u8; 20_000];
        reader.fill(&mut buf);
        for b in buf {
            payload.push_str(&format!("{b:02x}"));
        }
        d.host.edit("servers", &format!("s{i:02}"), Some(json!({ "blob": payload })));
    }

    let sync = LogSync::new(d.host.clone(), log.clone(), key);
    // Batch 1 commits on log-1; fail persist so join stops with join_sent recorded on log-1.
    log.fail_persist_append.store(true, Ordering::SeqCst);
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(d.host.state(vec!["log.log".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert!(d.host.state(vec!["log.join_sent".into()]).await.unwrap()[0].is_some());

    // Transport wrapper: `read` still reports log-1 (no 410 yet), while the next
    // `append` (batch 2, selected from log-1's join_sent) lands on a newly
    // created log-2.
    struct SwitchOnAppendLog {
        inner: Arc<MemLog>,
        switched: AtomicBool,
    }
    impl BlobStore for SwitchOnAppendLog {
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
    impl LogTransport for SwitchOnAppendLog {
        async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
            if self.switched.swap(false, Ordering::SeqCst) {
                let mut s = self.inner.lock();
                s.log = "log-2".into();
                s.batches.clear();
                s.dropped = 0;
                s.snapshot = None;
            }
            self.inner.append(key, body).await
        }
        async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
            self.inner.read(after, log).await
        }
        async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
            self.inner.put_snapshot(seq, body).await
        }
        async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
            self.inner.snapshot().await
        }
    }

    let switching = Arc::new(SwitchOnAppendLog { inner: log.clone(), switched: AtomicBool::new(true) });
    let sync_switch = LogSync::new(d.host.clone(), switching, d.key(&file).await.unwrap());
    // Sync sends batch 2 (which lands on log-2). log-2 MUST NOT be marked JOINED!
    sync_switch.sync().await.unwrap();
    assert_ne!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-2"));

    // Next sync discovers log-2 and completes a full join onto log-2 so another device sees all 20 records.
    sync_switch.sync().await.unwrap();
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-2"));
    let d2 = Device::new("pw");
    let k2 = d2.key(&file).await.unwrap();
    LogSync::new(d2.host.clone(), log.clone(), k2).sync().await.unwrap();
    assert_eq!(d2.host.values(), d.host.values());
}

#[tokio::test]
async fn append_checkpoint_put_failure_retries_without_resending_batch() {
    struct FailOncePutHost {
        inner: Arc<MemHost>,
        fail_next_put: AtomicBool,
    }
    impl Host for FailOncePutHost {
        async fn device(&self) -> Result<u64> {
            self.inner.device().await
        }
        async fn stamp(&self) -> Result<()> {
            self.inner.stamp().await
        }
        async fn all(&self) -> Result<Vec<Stamped>> {
            self.inner.all().await
        }
        async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
            self.inner.pending(after).await
        }
        async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
            self.inner.read(ids).await
        }
        async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
            self.inner.apply(ops).await
        }
        async fn not_carried(&self) -> Result<HashSet<String>> {
            self.inner.not_carried().await
        }
        async fn after_read(&self, nc: HashSet<String>) -> Result<()> {
            self.inner.after_read(nc).await
        }
        async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
            self.inner.state(keys).await
        }
        async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
            self.inner.state_prefixed(prefix).await
        }
        async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
            if self.fail_next_put.swap(false, Ordering::SeqCst) {
                return Err(Error::Host("sqlite busy".into()));
            }
            self.inner.set_state(values).await
        }
        async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
            self.inner.clear_state(prefix, keep).await
        }
        async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
            self.inner.pass(engine, ops).await
        }
        async fn passed(&self, engine: String) -> Result<Vec<Op>> {
            self.inner.passed(engine).await
        }
        async fn forget_passed(&self, engine: String) -> Result<()> {
            self.inner.forget_passed(engine).await
        }
        fn warn(&self, message: String) {
            self.inner.warn(message);
        }
    }

    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let host = Arc::new(FailOncePutHost { inner: d.host.clone(), fail_next_put: AtomicBool::new(true) });
    let sync = LogSync::new(host, log.clone(), key);
    log.fail_persist_append.store(true, Ordering::SeqCst);

    // Remote append commits (AppendPersistFailed) AND local core.put(state) fails.
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].is_none());

    // Retry applies the retained checkpoint WITHOUT calling transport.append again,
    // advancing local state cleanly.
    sync.sync().await.unwrap();
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1, "retained checkpoint must be applied without resending batch");
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert_eq!(d.host.state(vec!["log.cursor".into()]).await.unwrap()[0].as_deref(), Some("1"));
}

#[tokio::test]
async fn rotate_checkpoints_pending_accepted_join_before_rekey_and_aborts_on_failure() {
    struct ToggleFailPutHost {
        inner: Arc<MemHost>,
        fail_put: AtomicBool,
    }
    impl Host for ToggleFailPutHost {
        async fn device(&self) -> Result<u64> {
            self.inner.device().await
        }
        async fn stamp(&self) -> Result<()> {
            self.inner.stamp().await
        }
        async fn all(&self) -> Result<Vec<Stamped>> {
            self.inner.all().await
        }
        async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
            self.inner.pending(after).await
        }
        async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
            self.inner.read(ids).await
        }
        async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
            self.inner.apply(ops).await
        }
        async fn not_carried(&self) -> Result<HashSet<String>> {
            self.inner.not_carried().await
        }
        async fn after_read(&self, nc: HashSet<String>) -> Result<()> {
            self.inner.after_read(nc).await
        }
        async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
            self.inner.state(keys).await
        }
        async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
            self.inner.state_prefixed(prefix).await
        }
        async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
            if self.fail_put.load(Ordering::SeqCst) {
                return Err(Error::Host("sqlite busy".into()));
            }
            self.inner.set_state(values).await
        }
        async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
            self.inner.clear_state(prefix, keep).await
        }
        async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
            self.inner.pass(engine, ops).await
        }
        async fn passed(&self, engine: String) -> Result<Vec<Op>> {
            self.inner.passed(engine).await
        }
        async fn forget_passed(&self, engine: String) -> Result<()> {
            self.inner.forget_passed(engine).await
        }
        fn warn(&self, message: String) {
            self.inner.warn(message);
        }
    }

    let log = MemLog::new();
    let file = Arc::new(MemKeyFile::default());
    let d = Device::new("pw");
    let key = d.key(&file).await.unwrap();
    d.host.edit("servers", "s1", Some(json!({ "name": "box1" })));

    let host = Arc::new(ToggleFailPutHost { inner: d.host.clone(), fail_put: AtomicBool::new(true) });
    let sync = LogSync::new(host.clone(), log.clone(), key.clone());

    // First join append is accepted remotely (seq 1), but checkpoint write fails.
    assert!(matches!(sync.sync().await, Err(Error::Host(_))));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);
    assert!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].is_none());

    // Calling rotate while checkpoint still fails MUST NOT run rekey or send rotation append.
    let rekey_called = Arc::new(AtomicBool::new(false));
    let rk = rekey_called.clone();
    assert!(matches!(
        sync.rotate(async move {
            rk.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await,
        Err(Error::Host(_))
    ));
    assert!(!rekey_called.load(Ordering::SeqCst), "rekey must not run if checkpointing accepted join fails");
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 1);

    // Once storage recovers, rotate checkpoints the accepted join first without resending it,
    // then proceeds with rekey, rotation append, and snapshot.
    host.fail_put.store(false, Ordering::SeqCst);
    let key_c = key.clone();
    sync.rotate(async move { key_c.rotate().await }).await.unwrap();
    assert_eq!(d.host.state(vec!["log.joined".into()]).await.unwrap()[0].as_deref(), Some("log-1"));
    assert_eq!(log.append_calls.load(Ordering::SeqCst), 2, "only the rotation append should be sent after checkpointing");
    assert!(log.lock().snapshot.is_some());
}
