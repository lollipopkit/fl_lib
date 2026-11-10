//! What `api::sync_engine` runs on that codegen need not read: the host, its
//! keychain, its folder and key file, all one Dart callback answering JSON
//! (and bytes) by method.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use fl_sync_engine::key::{BoxFuture, KeyFile, Secrets, Versioned};
use fl_sync_engine::log::{Appended, LogTransport, Page, SnapshotBody};
use fl_sync_engine::segment::Files;
use fl_sync_engine::{BlobStore, Error, Hlc, Host, Listed, Op, Read, Result, Stamped};
use flutter_rust_bridge::{BaseAsyncRuntime, DartFnFuture};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::api::sync_engine::SyncReply;
use crate::frb_generated::FLUTTER_RUST_BRIDGE_HANDLER;

pub type Call = Arc<dyn Fn(String, String, Option<Vec<u8>>) -> DartFnFuture<SyncReply> + Send + Sync>;

/// One Dart callback: [method] with [args] (JSON) and [bytes].
#[derive(Clone)]
pub struct Bridge(pub Call);

impl Bridge {
    async fn raw(&self, method: &str, args: Value, bytes: Option<Vec<u8>>) -> Result<SyncReply> {
        let reply = (self.0)(method.to_string(), args.to_string(), bytes).await;
        if let Some(error) = reply.error.clone() {
            return Err(match reply.error_kind.as_deref() {
                Some("remote") => Error::Remote(error),
                Some("refused") => Error::Refused(error),
                Some("signedOut") => Error::SignedOut,
                Some("passwordMissing") => Error::PasswordMissing,
                _ => Error::Host(format!("{method}: {error}")),
            });
        }
        Ok(reply)
    }

    async fn call<T: DeserializeOwned>(&self, method: &str, args: impl Serialize) -> Result<T> {
        let args = serde_json::to_value(args).map_err(|e| Error::Host(e.to_string()))?;
        let reply = self.raw(method, args, None).await?;
        let json = if reply.json.is_empty() { "null" } else { &reply.json };
        serde_json::from_str(json).map_err(|e| Error::Host(format!("{method} answered: {e}")))
    }

    async fn call_with<T: DeserializeOwned>(&self, method: &str, args: Value, bytes: Vec<u8>) -> Result<T> {
        let reply = self.raw(method, args, Some(bytes)).await?;
        let json = if reply.json.is_empty() { "null" } else { &reply.json };
        serde_json::from_str(json).map_err(|e| Error::Host(format!("{method} answered: {e}")))
    }

    fn tell(&self, method: &str, args: Value) {
        let call = self.0.clone();
        let method = method.to_string();
        // Fire and forget: what Dart does with it answers nothing here.
        FLUTTER_RUST_BRIDGE_HANDLER.async_runtime().spawn(async move {
            let _ = call(method, args.to_string(), None).await;
        });
    }
}

fn stamped(rows: Vec<(String, String, String)>) -> Result<Vec<Stamped>> {
    rows.into_iter().map(|(c, id, h)| Ok(Stamped { c, id, h: h.parse().map_err(|_| Error::Host(format!("not a stamp: {h}")))? })).collect()
}

/// The host in Dart.
pub struct DartHost(pub Bridge);

impl Host for DartHost {
    async fn device(&self) -> Result<u64> {
        self.0.call("device", ()).await
    }

    async fn stamp(&self) -> Result<()> {
        self.0.call::<Value>("stamp", ()).await.map(|_| ())
    }

    async fn all(&self) -> Result<Vec<Stamped>> {
        stamped(self.0.call("all", ()).await?)
    }

    async fn pending(&self, after: Option<Hlc>) -> Result<Vec<Stamped>> {
        stamped(self.0.call("pending", after.map(|h| h.to_string())).await?)
    }

    async fn read(&self, ids: Vec<(String, String)>) -> Result<Vec<Read>> {
        let read: Vec<Value> = self.0.call("read", ids).await?;
        read.into_iter()
            .map(|r| match r {
                Value::Object(mut m) => Ok(match m.remove("v") {
                    Some(v) => Read::Value(v),
                    None if m.contains_key("unread") => Read::Unread,
                    None if m.contains_key("silent") => Read::Silent,
                    None => Read::Gone,
                }),
                other => Err(Error::Host(format!("read answered {other}"))),
            })
            .collect()
    }

    async fn apply(&self, ops: Vec<Op>) -> Result<Vec<Op>> {
        Ok(self.0.call::<Option<Vec<Op>>>("apply", ops).await?.unwrap_or_default())
    }

    async fn not_carried(&self) -> Result<HashSet<String>> {
        self.0.call("notCarried", ()).await
    }

    async fn after_read(&self, not_carried: HashSet<String>) -> Result<()> {
        self.0.call::<Value>("afterRead", not_carried).await.map(|_| ())
    }

    async fn state(&self, keys: Vec<String>) -> Result<Vec<Option<String>>> {
        self.0.call("state", keys).await
    }

    async fn state_prefixed(&self, prefix: String) -> Result<Vec<(String, String)>> {
        self.0.call("statePrefixed", prefix).await
    }

    async fn set_state(&self, values: Vec<(String, Option<String>)>) -> Result<()> {
        self.0.call::<Value>("setState", values).await.map(|_| ())
    }

    async fn clear_state(&self, prefix: String, keep: Vec<String>) -> Result<()> {
        self.0.call::<Value>("clearState", json!({ "prefix": prefix, "keep": keep })).await.map(|_| ())
    }

    async fn pass(&self, engine: String, ops: Vec<Op>) -> Result<()> {
        self.0.call::<Value>("pass", json!({ "engine": engine, "ops": ops })).await.map(|_| ())
    }

    async fn passed(&self, engine: String) -> Result<Vec<Op>> {
        self.0.call("passed", engine).await
    }

    async fn forget_passed(&self, engine: String) -> Result<()> {
        self.0.call::<Value>("forgetPassed", engine).await.map(|_| ())
    }

    fn warn(&self, message: String) {
        self.0.tell("warn", Value::String(message));
    }
}

/// A folder in Dart (WebDAV, iCloud): `files.*`.
pub struct DartFiles(pub Bridge);

impl BlobStore for DartFiles {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.0.raw("files.write", json!(name), Some(body)).await.map(|_| ())
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        Ok(self.0.raw("files.read", json!(name), None).await?.bytes)
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        let listed: Vec<(String, Option<i64>)> = self.0.call("files.list", prefix).await?;
        Ok(listed.into_iter().map(|(name, at)| Listed { name, at }).collect())
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.0.raw("files.delete", json!(name), None).await.map(|_| ())
    }
}

impl Files for DartFiles {
    async fn write(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.put_blob(name, body).await
    }
}

/// A key file in Dart, beside a folder's segments: `keyFile.*`.
pub struct DartKeyFile {
    pub bridge: Bridge,
    pub id: String,
}

impl KeyFile for DartKeyFile {
    fn id(&self) -> String {
        self.id.clone()
    }

    fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
        Box::pin(async {
            let reply = self.bridge.raw("keyFile.read", Value::Null, None).await?;
            let version: Option<String> = serde_json::from_str(&reply.json).map_err(|e| Error::Host(e.to_string()))?;
            Ok(reply.bytes.zip(version))
        })
    }

    fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async move {
            let reply = self.bridge.raw("keyFile.write", json!(if_version), Some(body)).await?;
            serde_json::from_str(&reply.json).map_err(|e| Error::Host(e.to_string()))
        })
    }

    fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
        Box::pin(async { self.bridge.call("keyFile.canCreate", ()).await })
    }
}

/// The keychain in Dart: `secrets.*`.
pub struct DartSecrets(pub Bridge);

impl Secrets for DartSecrets {
    fn password(&self) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async { self.0.call("secrets.password", ()).await })
    }

    fn kept(&self, id: String) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async move { self.0.call("secrets.kept", id).await })
    }

    fn set_kept(&self, id: String, identities: String) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move { self.0.call::<Value>("secrets.setKept", json!({ "id": id, "identities": identities })).await.map(|_| ()) })
    }

    fn epochs(&self) -> BoxFuture<'_, Result<HashMap<String, i64>>> {
        Box::pin(async { self.0.call("secrets.epochs", ()).await })
    }

    fn set_epochs(&self, epochs: HashMap<String, i64>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move { self.0.call::<Value>("secrets.setEpochs", epochs).await.map(|_| ()) })
    }

    fn pending(&self) -> BoxFuture<'_, Result<HashMap<String, String>>> {
        Box::pin(async { self.0.call("secrets.pending", ()).await })
    }

    fn set_pending(&self, pending: HashMap<String, String>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move { self.0.call::<Value>("secrets.setPending", pending).await.map(|_| ()) })
    }
}

/// A log in Dart (`log.*`, its blobs `files.*`): a test's, or a store the
/// app reaches itself.
pub struct DartLog(pub Bridge);

impl BlobStore for DartLog {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        DartFiles(self.0.clone()).put_blob(name, body).await
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        DartFiles(self.0.clone()).get_blob(name).await
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        DartFiles(self.0.clone()).blobs(prefix).await
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        DartFiles(self.0.clone()).delete_blob(name).await
    }
}

impl LogTransport for DartLog {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        let reply = self.0.raw("log.append", json!(key), Some(body)).await;
        let reply = match reply {
            Err(Error::Refused(r)) if r == "sync_log_full" => return Err(Error::LogFull),
            other => other?,
        };
        let a: Value = serde_json::from_str(&reply.json).map_err(|e| Error::Host(e.to_string()))?;
        let field = |k: &str| a.get(k).cloned().unwrap_or(Value::Null);
        Ok(Appended {
            log: field("log").as_str().ok_or_else(|| Error::Host("log.append: no log".into()))?.to_string(),
            seq: field("seq").as_i64().ok_or_else(|| Error::Host("log.append: no seq".into()))?,
            compact: field("compact").as_bool().unwrap_or(false),
        })
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        let page: Value = self.0.call("log.read", json!({ "after": after, "log": log })).await?;
        let log = page.get("log").and_then(Value::as_str).map(str::to_string);
        if page.get("compacted").and_then(Value::as_bool).unwrap_or(false) {
            return Ok(Page::Compacted { log });
        }
        let mut batches = Vec::new();
        for b in page.get("batches").and_then(Value::as_array).cloned().unwrap_or_default() {
            let seq = b.get("seq").and_then(Value::as_i64).ok_or_else(|| Error::Host("log.read: a batch without seq".into()))?;
            // Fetched apart: bytes do not travel in JSON.
            let body = self.0.raw("log.batch", json!(seq), None).await?.bytes.ok_or_else(|| Error::Host(format!("log.batch {seq}: gone")))?;
            batches.push((seq, body));
        }
        Ok(Page::Batches { log, batches, more: page.get("more").and_then(Value::as_bool).unwrap_or(false) })
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        self.0.call_with("log.putSnapshot", json!(seq), body).await
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        let reply = self.0.raw("log.snapshot", Value::Null, None).await?;
        let Some(body) = reply.bytes else { return Ok(None) };
        let s: Value = serde_json::from_str(&reply.json).map_err(|e| Error::Host(e.to_string()))?;
        Ok(Some(SnapshotBody {
            log: s.get("log").and_then(Value::as_str).ok_or_else(|| Error::Host("log.snapshot: no log".into()))?.to_string(),
            seq: s.get("seq").and_then(Value::as_i64).ok_or_else(|| Error::Host("log.snapshot: no seq".into()))?,
            body,
        }))
    }
}
