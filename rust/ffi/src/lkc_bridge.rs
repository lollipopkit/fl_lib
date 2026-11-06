//! What `api::lkc` runs on that codegen need not read: the keychain through
//! Dart, and an event stream forwarded to Dart.

use std::sync::Arc;

use fl_lkc::sync::{Event, SyncClient};
use fl_lkc::team::Keeper;
use fl_lkc::{Store, Stored};
use flutter_rust_bridge::DartFnFuture;
use futures_util::{Stream, StreamExt};
use tokio::sync::watch;

use crate::api::lkc::LkcSyncEvent;
use crate::frb_generated::StreamSink;

/// The session's keeping in Dart: the JSON of `fl_lkc::Stored`, `None` when
/// signed out. Dart answers whether it was written. And why a session
/// ended, for its log.
pub struct DartStore {
    pub save: Arc<dyn Fn(Option<String>) -> DartFnFuture<bool> + Send + Sync>,
    pub signed_out: Arc<dyn Fn(String) -> DartFnFuture<()> + Send + Sync>,
}

impl Store for DartStore {
    async fn save(&self, state: Option<Stored>) -> Result<(), String> {
        let json = state.map(|s| serde_json::to_string(&s).expect("a session serializes"));
        if (self.save)(json).await { Ok(()) } else { Err("not written".into()) }
    }

    async fn signed_out(&self, why: String) {
        (self.signed_out)(why).await;
    }
}

/// [sync]'s events into [sink] until [stopped] says so or Dart stops reading.
pub async fn forward(sync: Arc<SyncClient<DartStore>>, sink: StreamSink<LkcSyncEvent>, stopped: watch::Receiver<bool>) {
    forward_events(sync.events(), sink, stopped).await;
}

/// [events] into [sink] until [stopped] says so or Dart stops reading.
pub async fn forward_events(events: impl Stream<Item = Event> + Send, sink: StreamSink<LkcSyncEvent>, mut stopped: watch::Receiver<bool>) {
    let mut events = Box::pin(events);
    loop {
        let event = tokio::select! {
            _ = stopped.changed() => break,
            event = events.next() => event,
        };
        let Some(event) = event else { break };
        let event = match event {
            Event::Connected => LkcSyncEvent { connected: true, ..Default::default() },
            Event::Changed { name, etag } => LkcSyncEvent { name: Some(name), etag, ..Default::default() },
            Event::Log { seq } => LkcSyncEvent { log_seq: Some(seq), ..Default::default() },
            Event::Team { change } => LkcSyncEvent { team_change: Some(change), ..Default::default() },
            Event::Lost(detail) => LkcSyncEvent { lost: Some(detail), ..Default::default() },
        };
        if sink.add(event).is_err() {
            break;
        }
    }
}

/// The teams' trust in Dart: its JSON written to the keychain, answering
/// whether it was.
pub struct DartKeeper {
    pub save: Arc<dyn Fn(String) -> DartFnFuture<bool> + Send + Sync>,
}

impl Keeper for DartKeeper {
    async fn save(&self, json: String) -> Result<(), String> {
        if (self.save)(json).await { Ok(()) } else { Err("not written".into()) }
    }
}
