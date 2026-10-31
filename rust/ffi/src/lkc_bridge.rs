//! What `api::lkc` runs on that codegen need not read: the keychain through
//! Dart, and an event stream forwarded to Dart.

use std::sync::Arc;

use fl_lkc::sync::{Event, SyncClient};
use fl_lkc::{Store, Stored};
use flutter_rust_bridge::DartFnFuture;
use futures_util::StreamExt;
use tokio::sync::watch;

use crate::api::lkc::LkcSyncEvent;
use crate::frb_generated::StreamSink;

/// The session's keeping in Dart: the JSON of `fl_lkc::Stored`, `None` when
/// signed out. Dart answers whether it was written.
pub struct DartStore(pub Arc<dyn Fn(Option<String>) -> DartFnFuture<bool> + Send + Sync>);

impl Store for DartStore {
    async fn save(&self, state: Option<Stored>) -> Result<(), String> {
        let json = state.map(|s| serde_json::to_string(&s).expect("a session serializes"));
        if (self.0)(json).await { Ok(()) } else { Err("not written".into()) }
    }
}

/// [sync]'s events into [sink] until [stopped] says so or Dart stops reading.
pub async fn forward(sync: Arc<SyncClient<DartStore>>, sink: StreamSink<LkcSyncEvent>, mut stopped: watch::Receiver<bool>) {
    let mut events = Box::pin(sync.events());
    loop {
        let event = tokio::select! {
            _ = stopped.changed() => break,
            event = events.next() => event,
        };
        let Some(event) = event else { break };
        let event = match event {
            Event::Connected => LkcSyncEvent { connected: true, name: None, etag: None },
            Event::Changed { name, etag } => LkcSyncEvent { connected: false, name: Some(name), etag },
        };
        if sink.add(event).is_err() {
            break;
        }
    }
}
