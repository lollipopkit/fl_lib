use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::StreamExt;
use serde_json::json;
use tokio::sync::Notify;

use super::*;
use crate::fake::{Fake, Request, Response};
use crate::personal::PersonalVersions;
use crate::session::{Session, Store, Stored};
use crate::team::identity::AccountKey;
use crate::{Client, now_ms};

mod auth;
mod commits;
mod files;
mod log;
mod snapshot;

#[derive(Clone, Default)]
struct Kept(Arc<StdMutex<Vec<Option<Stored>>>>);

impl Store for Kept {
    async fn save(&self, state: Option<Stored>) -> Result<(), String> {
        self.0.lock().unwrap().push(state);
        Ok(())
    }
}

/// Homebase, answering every request with [answer]; the session's token
/// is good for an hour, so the IdP is never asked.
async fn homebase(answer: impl Fn(&Request) -> Response + Send + Sync + 'static) -> (Fake, Arc<SyncClient<Kept>>) {
    let fake = Fake::start(answer).await;
    let client = Arc::new(Client::with(&fake.issuer(), "app", &fake.base).unwrap());
    let stored = Stored { access: "tok".into(), refresh: Some("r".into()), expires_at: now_ms() + 3_600_000, refreshing: false };
    let session = Arc::new(Session::restore(client, Kept::default(), Some(stored)).await);
    (fake, Arc::new(SyncClient::new(session, "serverbox")))
}

fn file(dir: &tempdir::Dir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

mod tempdir {
    pub struct Dir(std::path::PathBuf);
    impl Dir {
        pub fn new() -> Self {
            let p = std::env::temp_dir().join(format!("fl-lkc-sync-{}-{}", std::process::id(), rand()));
            std::fs::create_dir_all(&p).unwrap();
            Self(p)
        }
        pub fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn rand() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64
    }
}

const NAME: &str = "srvbox_bak_v4.age";

fn written(etag: &str) -> Response {
    Response::status(204).header("ETag", &format!("\"{etag}\""))
}

const KEY: &str = "0000019a3f2b1c000000000000000007";

fn page(batches: &[(i64, &[u8])], head: i64, more: bool) -> Response {
    let batches: Vec<_> = batches
        .iter()
        .map(|(seq, body)| json!({ "seq": seq, "size": body.len(), "digest": blake3::hash(body).to_hex().as_str(), "body": BASE64.encode(body) }))
        .collect();
    Response::json(200, json!({ "code": 0, "data": { "log": "6f1c", "batches": batches, "head": head, "snapshot_seq": 0, "more": more } }))
}

struct TestKeeper {
    saved: StdMutex<String>,
    fail: AtomicBool,
}

impl TestKeeper {
    fn new() -> Arc<Self> {
        Arc::new(Self { saved: StdMutex::new(String::new()), fail: AtomicBool::new(false) })
    }
}

impl crate::personal::VersionKeeper for TestKeeper {
    fn save(&self, json: String) -> crate::personal::BoxFuture<'_, Result<(), String>> {
        if self.fail.load(Ordering::SeqCst) {
            return Box::pin(async { Err("disk full".into()) });
        }
        *self.saved.lock().unwrap() = json;
        Box::pin(async { Ok(()) })
    }
}

/// Waits until [task] reaches the fixture's [reached] notification, failing
/// with [stage] if it finishes first or does not get there in time.
async fn reach<T: std::fmt::Debug>(stage: &str, reached: &Notify, task: &mut tokio::task::JoinHandle<T>) {
    tokio::select! {
        biased;
        () = reached.notified() => {}
        done = task => panic!("{stage}: request finished before reaching the fixture: {done:?}"),
        () = tokio::time::sleep(Duration::from_secs(5)) => panic!("{stage}: timed out"),
    }
}
