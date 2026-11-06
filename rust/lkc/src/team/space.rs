//! One app's files and log in a team's space, sealed and opened here: the
//! app reads and writes plain bytes, and a write under a key replaced
//! meanwhile is sealed again under the new one and sent once more.

use std::future::Future;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::RwLock;

use super::teams::Teams;
use super::trust::Keeper;
use super::verify::Keyring;
use super::TeamError;
use crate::session::Store;
use crate::sync::{self, Appended, Batch, Condition, File, Kind, LogRead, Snapshot, SyncClient};

pub struct TeamSpace<S: Store, K: Keeper> {
    teams: Arc<Teams<S, K>>,
    team: String,
    sync: Arc<SyncClient<S>>,
    /// Held for reading while a write is sealed and sent, for writing while
    /// it and the epoch the sync names change: a write is always sent under
    /// the epoch of the key it is sealed with.
    ring: RwLock<Arc<Keyring>>,
    /// Each append's sealed bytes and their epoch, until answered.
    appending: Mutex<HashMap<String, (i64, Vec<u8>)>>,
}

/// Appends whose bytes are kept at most: past it, all are forgotten.
const APPENDING_MAX: usize = 64;

/// A read of a team's log: [LogRead], opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TeamLog {
    Page {
        log: Option<String>,
        batches: Vec<Batch>,
        /// Batches sealed under an epoch this device holds no key of.
        unreadable: Vec<i64>,
        head: i64,
        snapshot_seq: i64,
        more: bool,
    },
    Compacted { log: Option<String>, snapshot_seq: i64 },
}

impl<S: Store, K: Keeper> TeamSpace<S, K> {
    pub(crate) fn new(teams: Arc<Teams<S, K>>, team: &str, app: &str, ring: Arc<Keyring>) -> Self {
        let sync = Arc::new(SyncClient::for_team(teams.client().session().clone(), team, app, ring.epoch()));
        Self { teams, team: team.to_string(), sync, ring: RwLock::new(ring), appending: Mutex::new(HashMap::new()) }
    }

    /// The space's sync, for its events ([SyncClient::events]).
    pub fn sync(&self) -> &Arc<SyncClient<S>> {
        &self.sync
    }

    pub async fn ring(&self) -> Arc<Keyring> {
        self.ring.read().await.clone()
    }

    /// The keyring read and checked again: after an event of the team's.
    pub async fn refresh(&self) -> Result<Arc<Keyring>, TeamError> {
        let ring = self.teams.keyring(&self.team).await?;
        let mut held = self.ring.write().await;
        self.sync.set_epoch(ring.epoch());
        *held = ring.clone();
        Ok(ring)
    }

    /// [write] sealed under the current key; once more under the new one
    /// when the key was replaced meanwhile.
    async fn sealed<T, F: Future<Output = Result<T, sync::Error>>>(&self, plain: &[u8], write: impl Fn(Vec<u8>) -> F) -> Result<T, TeamError> {
        let first = {
            let ring = self.ring.read().await;
            write(ring.seal(plain)?).await
        };
        match first {
            Err(e) if matches!(e.kind, Kind::StaleEpoch(_)) => {
                self.refresh().await?;
                let ring = self.ring.read().await;
                Ok(write(ring.seal(plain)?).await?)
            }
            other => Ok(other?),
        }
    }

    pub async fn list(&self) -> Result<Vec<File>, TeamError> {
        Ok(self.sync.list().await?)
    }

    /// [name] opened, and its version; `None` when there is none.
    pub async fn read(&self, name: &str) -> Result<Option<(Vec<u8>, String)>, TeamError> {
        match self.sync.download_bytes(name).await? {
            Some((sealed, etag)) => Ok(Some((self.open(&sealed, None).await?, etag))),
            None => Ok(None),
        }
    }

    /// [plain] sealed as [name]'s new version, if [condition] holds.
    pub async fn write(&self, name: &str, plain: &[u8], condition: Condition) -> Result<String, TeamError> {
        self.sealed(plain, |sealed| self.sync.upload_bytes(name, sealed, condition.clone())).await
    }

    pub async fn delete(&self, name: &str, if_match: Option<&str>) -> Result<bool, TeamError> {
        Ok(self.sync.delete(name, if_match).await?)
    }

    /// [plain] sealed and appended once per [key]. Sealing is random, so a
    /// retry of [key] sends the bytes its first try sent (kept until it is
    /// answered), as homebase takes only those again.
    pub async fn append(&self, key: &str, plain: &[u8]) -> Result<Appended, TeamError> {
        let kept = self.appending.lock().unwrap_or_else(|e| e.into_inner()).get(key).cloned();
        let ring = self.ring.read().await;
        let sealed = match kept {
            Some((epoch, sealed)) if epoch == ring.epoch() => sealed,
            _ => ring.seal(plain)?,
        };
        self.keep_appending(key, ring.epoch(), sealed.clone());
        let first = self.sync.append(key, sealed).await;
        drop(ring);
        let answered = match first {
            // Refused, so not taken: sealed anew under the new key.
            Err(e) if matches!(e.kind, Kind::StaleEpoch(_)) => {
                self.refresh().await?;
                let ring = self.ring.read().await;
                let sealed = ring.seal(plain)?;
                self.keep_appending(key, ring.epoch(), sealed.clone());
                self.sync.append(key, sealed).await
            }
            other => other,
        };
        if !matches!(&answered, Err(e) if e.kind == Kind::Unreachable) {
            self.appending.lock().unwrap_or_else(|e| e.into_inner()).remove(key);
        }
        Ok(answered?)
    }

    fn keep_appending(&self, key: &str, epoch: i64, sealed: Vec<u8>) {
        let mut kept = self.appending.lock().unwrap_or_else(|e| e.into_inner());
        if kept.len() >= APPENDING_MAX && !kept.contains_key(key) {
            kept.clear();
        }
        kept.insert(key.to_string(), (epoch, sealed));
    }

    /// The log's batches after [after] of [log], opened; one sealed under an
    /// epoch this device holds no key of is named apart, its seq passed.
    pub async fn read_log(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<TeamLog, TeamError> {
        match self.sync.read_log(after, log, limit).await? {
            LogRead::Page { log, batches, head, snapshot_seq, more } => {
                let mut opened = Vec::with_capacity(batches.len());
                let mut unreadable = Vec::new();
                for b in batches {
                    match self.open(&b.body, b.epoch).await {
                        Ok(body) => opened.push(Batch { seq: b.seq, body, epoch: b.epoch }),
                        Err(TeamError::Crypto(_)) => unreadable.push(b.seq),
                        Err(e) => return Err(e),
                    }
                }
                Ok(TeamLog::Page { log, batches: opened, unreadable, head, snapshot_seq, more })
            }
            LogRead::Compacted { log, snapshot_seq } => Ok(TeamLog::Compacted { log, snapshot_seq }),
        }
    }

    /// [plain] sealed as the log's snapshot up to [seq].
    pub async fn put_snapshot(&self, seq: i64, plain: &[u8]) -> Result<String, TeamError> {
        self.sealed(plain, |sealed| self.sync.put_snapshot_bytes(seq, sealed)).await
    }

    /// The log's snapshot, opened; `None` before there is one.
    pub async fn snapshot(&self) -> Result<Option<(Snapshot, Vec<u8>)>, TeamError> {
        match self.sync.download_snapshot_bytes().await? {
            Some((s, sealed)) => Ok(Some((s, self.open(&sealed, None).await?))),
            None => Ok(None),
        }
    }

    /// [sealed] (of [epoch], when homebase says) opened; with a keyring
    /// read again when it may be of an epoch newer than this one's.
    async fn open(&self, sealed: &[u8], epoch: Option<i64>) -> Result<Vec<u8>, TeamError> {
        let ring = self.ring().await;
        match ring.open(sealed) {
            Ok(plain) => Ok(plain),
            Err(_) if epoch.is_none_or(|e| e > ring.epoch()) => self.refresh().await?.open(sealed),
            Err(e) => Err(e),
        }
    }
}
