//! Homebase's sync for real: signs in with a device code (approve it in a
//! browser), writes, races, reads and removes a file of its own, appends to and
//! snapshots a log of an app of its own ([`LOG_APP`]), then revokes the
//! session. With `LKC_KEY_PASSPHRASE` (the account key's password), it does so
//! again signed under the account key, on [SIGNED_APP]. Needs an account whose
//! plan has sync; leaves only those logs' snapshots and the batches they
//! cover, which homebase drops a day later (never a token printed):
//! `LKC_KEY_PASSPHRASE=$(op read op://Dev/lkc-key-password/password) cargo run -p fl_lkc --example sync_e2e`
//! (from `rust/`).

use std::sync::Arc;
use std::time::Duration;

use fl_lkc::personal::{BoxFuture, PersonalAuth, PersonalVersions, VersionKeeper};
use fl_lkc::sync::{Condition, DIRECT_MAX, Event, Fetched, Kind, LogRead, Snapshot, SyncClient};
use fl_lkc::team::TeamClient;
use fl_lkc::team::identity::AccountKeyFile;
use fl_lkc::{Client, DevicePoll, Failure, Session, Store, Stored};
use futures_util::StreamExt;

/// Kept in memory only: this run's session ends with it.
struct Memory;

impl Store for Memory {
    async fn save(&self, _: Option<Stored>) -> Result<(), String> {
        Ok(())
    }
}

const APP: &str = "serverbox";
/// Not ServerBox's: its devices would try to read the batches written here.
const LOG_APP: &str = "fl-lkc-e2e";
/// Signed under the account key, apart from [LOG_APP]'s unsigned batches.
const SIGNED_APP: &str = "fl-lkc-e2e-signed";

/// This run's signing watermarks, kept in memory only.
struct Forget;

impl VersionKeeper for Forget {
    fn save(&self, _: String) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }
}

/// An age file's header ahead of [len] bytes: homebase keeps age files only.
fn age(len: usize, fill: u8) -> Vec<u8> {
    let mut bytes = b"age-encryption.org/v1\n-> scrypt e2e 18\nAAAA\n--- e2e\n".to_vec();
    bytes.resize(len, fill);
    bytes
}

#[tokio::main]
async fn main() {
    let client = Arc::new(Client::new("serverbox").expect("client"));
    let mut device = client.start_device().await.expect("device code");
    println!("Open {}", device.verification_uri_complete.as_deref().unwrap_or(&device.verification_uri));
    println!("Code: {}", device.user_code);
    let tokens = loop {
        tokio::time::sleep(Duration::from_secs(device.interval_secs)).await;
        match client.poll_device(&device).await {
            Ok(DevicePoll::Pending) => {}
            Ok(DevicePoll::SlowDown(secs)) => device.interval_secs = secs,
            Ok(DevicePoll::Done(tokens)) => break tokens,
            Err(e) if e.failure == Failure::Unreachable => eprintln!("retrying: {e}"),
            Err(e) => panic!("poll: {e}"),
        }
    };
    let me = client.user(&tokens.access).await.expect("user").id;
    let session = Arc::new(Session::restore(client, Memory, None).await);
    session.sign_in(tokens).await.expect("session");

    let passphrase = std::env::var("LKC_KEY_PASSPHRASE").ok();
    let result = tokio::spawn(run(session.clone(), me, passphrase)).await;
    session.sign_out("the e2e run ended".into()).await;
    println!("signed out");
    if let Err(e) = result {
        std::panic::resume_unwind(e.into_panic());
    }
    println!("all passed");
}

async fn run(session: Arc<Session<Memory>>, me: String, passphrase: Option<String>) {
    let dir = std::env::temp_dir().join(format!("fl-lkc-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let name = format!("e2e-{}.age", fl_lkc::now_ms());
    let large = format!("e2e-{}-large.age", fl_lkc::now_ms());
    let this = Arc::new(SyncClient::new(session.clone(), APP));
    let other = SyncClient::new(session.clone(), APP);

    let mut events = Box::pin(this.clone().events());
    assert_eq!(next(&mut events).await, Event::Connected);
    println!("listening");

    let one = dir.join("one");
    std::fs::write(&one, age(200, b'1')).unwrap();
    let e1 = this.upload(&name, &one, Condition::Absent).await.expect("first write");
    assert_eq!(this.upload(&name, &one, Condition::Absent).await.unwrap_err().kind, Kind::Changed);
    assert_eq!(this.head(&name).await.unwrap().as_deref(), Some(e1.as_str()));
    println!("written, a second new file refused");

    // Another device writes on the version both read; this one's write on it
    // then loses.
    let two = dir.join("two");
    std::fs::write(&two, age(300, b'2')).unwrap();
    let e2 = other.upload(&name, &two, Condition::Match(e1.clone())).await.expect("other's write");
    assert_eq!(this.upload(&name, &one, Condition::Match(e1.clone())).await.unwrap_err().kind, Kind::Changed);
    assert_eq!(next(&mut events).await, Event::Changed { name: name.clone(), etag: Some(e2.clone()) });
    println!("the race lost, and heard of");

    let got = dir.join("got");
    assert_eq!(this.download(&name, &got, None).await.unwrap(), Fetched::Saved(e2.clone()));
    assert_eq!(std::fs::read(&got).unwrap(), std::fs::read(&two).unwrap());
    assert_eq!(this.download(&name, &got, Some(&e2)).await.unwrap(), Fetched::Unchanged);
    let versions = this.versions(&name).await.expect("versions");
    assert!(versions.iter().any(|v| v.etag == e1), "{versions:?}");
    assert_eq!(this.download_version(&name, &e1, &got).await.unwrap(), Fetched::Saved(e1.clone()));
    assert_eq!(std::fs::read(&got).unwrap(), std::fs::read(&one).unwrap());
    println!("read back, and the version before");

    let big = dir.join("big");
    std::fs::write(&big, age(DIRECT_MAX as usize + 4096, b'3')).unwrap();
    let e3 = this.upload(&large, &big, Condition::Absent).await.expect("large write");
    assert_eq!(this.download(&large, &got, None).await.unwrap(), Fetched::Saved(e3.clone()));
    assert_eq!(std::fs::read(&got).unwrap(), std::fs::read(&big).unwrap());
    println!("a large file through the store");

    let listed = this.list().await.expect("list");
    assert!(listed.iter().any(|f| f.name == name && f.etag == e2));
    assert!(this.offset_ms().abs() < 60_000, "clock offset {}", this.offset_ms());

    assert!(this.delete(&name, Some(&e2)).await.unwrap());
    assert!(this.delete(&large, Some(&e3)).await.unwrap());
    assert_eq!(this.head(&name).await.unwrap(), None);
    println!("removed");

    log(Arc::new(SyncClient::new(session.clone(), LOG_APP)), &dir).await;
    match passphrase {
        Some(p) => signed(session, &me, &p).await,
        None => println!("signed log skipped: no LKC_KEY_PASSPHRASE"),
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Batches, a snapshot and a blob signed under the account key: each read
/// answers verified only once personal auth checked it.
async fn signed(session: Arc<Session<Memory>>, me: &str, passphrase: &str) {
    let key = AccountKeyFile::new(session.clone(), me).load_or_create(passphrase).await.expect("the account key");
    TeamClient::new(session.clone()).publish_no_reset(&key).await.expect("publish it");
    let sync = SyncClient::new(session, SIGNED_APP);
    let (_, verified) = sync.read_log_checked(0, None, Some(1)).await.expect("read unchecked");
    assert!(!verified, "verified without personal auth");
    sync.set_personal(Some(Arc::new(PersonalAuth::new(key, PersonalVersions::default(), Arc::new(Forget)))));

    let head = match sync.read_log_checked(0, None, Some(1)).await.expect("read the signed log") {
        (LogRead::Page { head, .. }, true) => head,
        (LogRead::Compacted { log, snapshot_seq }, true) => match sync.read_log_checked(snapshot_seq, log.as_deref(), Some(1)).await.expect("read past the snapshot") {
            (LogRead::Page { head, .. }, true) => head,
            other => panic!("{other:?}"),
        },
        other => panic!("{other:?}"),
    };
    let batch_key = format!("{:016x}{:016x}", fl_lkc::now_ms(), std::process::id());
    let appended = sync.append(&batch_key, age(150, b'x')).await.expect("signed append");
    assert_eq!(appended.seq, head + 1);
    let (read, verified) = sync.read_log_checked(appended.seq - 1, Some(&appended.log), None).await.expect("read it back");
    let LogRead::Page { batches, .. } = read else { panic!("compacted right after an append") };
    assert!(verified && batches.len() == 1 && batches[0].signed.is_some(), "{batches:?}");
    println!("a signed batch read back, verified");

    sync.put_snapshot_bytes(appended.seq, age(400, b'y')).await.expect("signed snapshot");
    let (found, verified) = sync.download_snapshot_bytes_checked().await.expect("read the snapshot");
    let (snap, body) = found.expect("a snapshot");
    assert!(verified && snap.signed.is_some() && snap.seq == appended.seq && body == age(400, b'y'), "{snap:?}");
    println!("a signed snapshot read back, verified");

    let blob = format!("op-e2e-{}.age", fl_lkc::now_ms());
    let (put, signed) = sync.upload_blob_bytes_checked(&blob, age(300, b'z')).await;
    put.expect("signed blob");
    assert!(signed, "a blob uploaded unsigned");
    let (got, verified) = sync.download_blob_bytes_checked(&blob).await;
    let (body, _, sig) = got.expect("read the blob").expect("the blob");
    assert!(verified && sig.is_some() && body == age(300, b'z'));
    let (again, _) = sync.upload_blob_bytes_checked(&blob, age(300, b'w')).await;
    assert_eq!(again.unwrap_err().kind, Kind::Changed);
    assert!(sync.delete(&blob, None).await.unwrap());
    println!("a signed blob read back verified, a second write refused, removed");
}

async fn log(sync: Arc<SyncClient<Memory>>, dir: &std::path::Path) {
    let mut events = Box::pin(sync.clone().events());
    assert_eq!(next(&mut events).await, Event::Connected);
    // A log an earlier run compacted is read from its snapshot on.
    let (before, head) = match sync.read_log(0, None, Some(1)).await.expect("read the log") {
        LogRead::Page { log, head, .. } => (log, head),
        LogRead::Compacted { log, snapshot_seq } => {
            let LogRead::Page { log, head, .. } = sync.read_log(snapshot_seq, log.as_deref(), Some(1)).await.expect("read past the snapshot") else {
                panic!("compacted again at the snapshot's seq")
            };
            (log, head)
        }
    };

    let key = format!("{:016x}{:016x}", fl_lkc::now_ms(), std::process::id());
    let appended = sync.append(&key, age(150, b'a')).await.expect("append");
    assert_eq!(appended.seq, head + 1);
    assert!(before.is_none_or(|l| l == appended.log), "the log changed under the run");
    assert_eq!(sync.append(&key, age(150, b'a')).await.expect("append again").seq, appended.seq);
    assert_eq!(sync.append(&key, age(150, b'b')).await.unwrap_err().kind, Kind::Refused("sync_key_reused".into()));
    assert_eq!(next(&mut events).await, Event::Log { seq: appended.seq });
    println!("appended once under its key, and heard of");

    let LogRead::Page { log, batches, head, more, .. } = sync.read_log(appended.seq - 1, Some(&appended.log), None).await.expect("read on") else {
        panic!("compacted right after an append")
    };
    assert_eq!((log.as_deref(), head, more), (Some(appended.log.as_str()), appended.seq, false));
    assert_eq!(batches.len(), 1);
    assert_eq!((batches[0].seq, &batches[0].body), (appended.seq, &age(150, b'a')));
    let other = sync.read_log(appended.seq, Some("00000000-0000-0000-0000-000000000000"), None).await.expect("read another log");
    assert!(matches!(other, LogRead::Compacted { log: Some(ref l), .. } if *l == appended.log), "{other:?}");
    println!("read back from the cursor; another log's cursor sent to the snapshot");

    let snap = dir.join("snap");
    std::fs::write(&snap, age(400, b's')).unwrap();
    sync.put_snapshot(appended.seq, &snap).await.expect("snapshot");
    sync.put_snapshot(appended.seq, &snap).await.expect("the same snapshot again");
    std::fs::write(&snap, age(400, b't')).unwrap();
    assert_eq!(sync.put_snapshot(appended.seq, &snap).await.unwrap_err().kind, Kind::Refused("sync_snapshot_stale".into()));
    let got = dir.join("got-snap");
    assert_eq!(sync.download_snapshot(&got).await.expect("read the snapshot"), Some(Snapshot { log: appended.log.clone(), seq: appended.seq, signed: None }));
    assert_eq!(std::fs::read(&got).unwrap(), age(400, b's'));
    println!("snapshot written, retried, a stale one refused, read back");
}

/// The next event but a lost connection, each of those printed.
async fn next(events: &mut (impl futures_util::Stream<Item = Event> + Unpin)) -> Event {
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            match events.next().await.expect("the events ended") {
                Event::Lost(why) => eprintln!("events: {why}"),
                event => return event,
            }
        }
    })
    .await
    .expect("no event in 90 s")
}
