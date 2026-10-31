//! Homebase's sync for real: signs in with a device code (approve it in a
//! browser), writes, races, reads and removes a file of its own, then revokes
//! the session. Needs an account whose plan has sync; leaves nothing behind
//! (never a token printed):
//! `cargo run -p fl_lkc --example sync_e2e` (from `rust/`).

use std::sync::Arc;
use std::time::Duration;

use fl_lkc::sync::{Condition, DIRECT_MAX, Event, Fetched, Kind, SyncClient};
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
    let session = Arc::new(Session::restore(client, Memory, None).await);
    session.sign_in(tokens).await.expect("session");

    let result = tokio::spawn(run(session.clone())).await;
    session.sign_out().await;
    println!("signed out");
    if let Err(e) = result {
        std::panic::resume_unwind(e.into_panic());
    }
    println!("all passed");
}

async fn run(session: Arc<Session<Memory>>) {
    let dir = std::env::temp_dir().join(format!("fl-lkc-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let name = format!("e2e-{}.age", fl_lkc::now_ms());
    let large = format!("e2e-{}-large.age", fl_lkc::now_ms());
    let this = Arc::new(SyncClient::new(session.clone(), APP));
    let other = SyncClient::new(session, APP);

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
    let _ = std::fs::remove_dir_all(&dir);
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
