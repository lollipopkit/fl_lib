//! One app's files and log in a team's space, sealed, signed, opened and
//! checked here: the app reads and writes plain bytes. Every write is sealed
//! under the current key and signed by this account; every read is checked
//! signed by one who could write under its epoch, and never older than the
//! newest this device saw of its name. A write under a key replaced meanwhile
//! is sealed again under the new one and sent once more.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};

use tokio::sync::RwLock;

use super::crypto::{self, KEY_LEN};
use super::teams::Teams;
use super::trust::Keeper;
use super::verify::{self, Keyring, raw32};
use super::{TeamError, b64, canonical, unb64};
use crate::session::Store;
use crate::sync::{self, Appended, Batch, Condition, File, Kind, LogRead, Signed, Snapshot, SyncClient, WriteSig};

pub struct TeamSpace<S: Store, K: Keeper> {
    teams: Arc<Teams<S, K>>,
    team: String,
    app: String,
    /// `team:{id}`: what every write's signature names as its owner.
    owner: String,
    sync: Arc<SyncClient<S>>,
    /// Held for reading while a write is sealed and sent, for writing while
    /// it and the epoch the sync names change: a write is always sent under
    /// the epoch of the key it is sealed with.
    ring: RwLock<Arc<Keyring>>,
    /// Each append's sealed bytes, until answered.
    appending: Mutex<HashMap<String, Pending>>,
    /// The seq each batch read (by log and idempotency key) was at.
    taken: Mutex<HashMap<(String, String), i64>>,
}

/// Batches read kept at most ([TeamSpace::taken]): past it, all are
/// forgotten. A log is compacted long before.
const TAKEN_MAX: usize = 20_000;

/// An append's epoch, sealed bytes and signature.
type Pending = (i64, Vec<u8>, String);

/// Appends whose bytes are kept at most: past it, all are forgotten.
const APPENDING_MAX: usize = 64;

/// A read of a team's log: [LogRead], opened and checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TeamLog {
    Page {
        log: Option<String>,
        batches: Vec<Batch>,
        /// Batches sealed under an epoch this device holds no key of, or
        /// signed by none who could write under it: passed.
        unreadable: Vec<i64>,
        head: i64,
        snapshot_seq: i64,
        more: bool,
    },
    Compacted { log: Option<String>, snapshot_seq: i64 },
}

fn digest(body: &[u8]) -> [u8; KEY_LEN] {
    *blake3::hash(body).as_bytes()
}

impl<S: Store, K: Keeper> TeamSpace<S, K> {
    pub(crate) fn new(teams: Arc<Teams<S, K>>, team: &str, app: &str, ring: Arc<Keyring>) -> Result<Self, TeamError> {
        let canonical = canonical(team)?;
        let sync = Arc::new(SyncClient::for_team(teams.client().session().clone(), &canonical, app, ring.epoch()));
        Ok(Self {
            teams,
            owner: format!("team:{canonical}"),
            team: canonical,
            app: app.to_string(),
            sync,
            ring: RwLock::new(ring),
            appending: Mutex::new(HashMap::new()),
            taken: Mutex::new(HashMap::new()),
        })
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

    /// What [Trust] keeps [name]'s highest version under.
    fn version_key(&self, name: &str) -> String {
        format!("{}/{}/{name}", self.owner, self.app)
    }

    fn sign(&self, message: &[u8]) -> String {
        b64(&crypto::sign(self.teams.key().signing(), message))
    }

    /// [write] sealed under the current key (and signed by [sign] of the
    /// epoch and the sealed bytes); once more under the new one when the key
    /// was replaced meanwhile.
    async fn sealed<T, F: Future<Output = Result<T, sync::Error>>>(
        &self,
        plain: &[u8],
        sign: impl Fn(i64, &[u8]) -> WriteSig,
        write: impl Fn(Vec<u8>, WriteSig) -> F,
    ) -> Result<T, TeamError> {
        let first = {
            let ring = self.ring.read().await;
            let sealed = ring.seal(plain)?;
            let sig = sign(ring.epoch(), &sealed);
            write(sealed, sig).await
        };
        match first {
            Err(e) if matches!(e.kind, Kind::StaleEpoch(_)) => {
                self.refresh().await?;
                let ring = self.ring.read().await;
                let sealed = ring.seal(plain)?;
                let sig = sign(ring.epoch(), &sealed);
                Ok(write(sealed, sig).await?)
            }
            other => Ok(other?),
        }
    }

    pub async fn list(&self) -> Result<Vec<File>, TeamError> {
        Ok(self.sync.list().await?)
    }

    /// The epoch held whose key [signed] signed [message_of] under, by one
    /// who could write then; [TeamError::Untrusted] if none. With [retry],
    /// checked again after the keyring (and so its key records) is read
    /// again, when the write may be newer than them (an epoch, a join, a key).
    async fn check_signed(&self, signed: Option<&Signed>, what: &str, epoch: Option<i64>, retry: bool, message_of: impl Fn(i64) -> Vec<u8>) -> Result<i64, TeamError> {
        let signed = signed.ok_or_else(|| TeamError::Untrusted(format!("{what}: not signed")))?;
        let signing_key = raw32(&signed.signing_key, "signing_key")?;
        let signature = unb64(&signed.signature, "signature")?;
        let mut fresh = false;
        loop {
            let ring = if fresh { self.refresh().await? } else { self.ring().await };
            let epochs: Vec<i64> = match epoch {
                Some(e) => vec![e],
                None => ring.keys().map(|(e, _)| e).collect(),
            };
            let checked = match epochs.into_iter().rev().find(|e| crypto::verify(&signing_key, &message_of(*e), &signature, "a write").is_ok()) {
                None => Err(TeamError::Untrusted(format!("{what}: a signature that does not verify"))),
                // A file (a log's batches are of their own epoch) from before
                // the files were all sealed again: homebase going back.
                Some(e) if epoch.is_none() && e < ring.migrated_epoch() => Err(TeamError::Untrusted(format!("{what}: of epoch {e}, before every file was sealed again"))),
                Some(e) => self.by_writer(&ring, e, &signed.signer, &signing_key).await.map(|()| e).map_err(|err| match err {
                    TeamError::Untrusted(why) => TeamError::Untrusted(format!("{what}: {why}")),
                    other => other,
                }),
            };
            match checked {
                Err(TeamError::Untrusted(_)) if retry && !fresh => fresh = true,
                other => return other,
            }
        }
    }

    /// Whether [signer], under [signing_key], could write under [epoch] of
    /// [ring], by the key records read with it; and is trusted so.
    async fn by_writer(&self, ring: &Keyring, epoch: i64, signer: &str, signing_key: &[u8; KEY_LEN]) -> Result<(), TeamError> {
        let record = ring.record(epoch).ok_or_else(|| TeamError::Untrusted(format!("of epoch {epoch}, not checked")))?;
        let mut users: Vec<String> = record.members.iter().map(|m| m.user_id.clone()).collect();
        users.extend(record.joins.iter().flat_map(|j| [j.user_id.clone(), j.signed_by.clone()]));
        users.push(signer.to_string());
        users.sort();
        users.dedup();
        let chains = self.teams.chains_held(&users);
        if !verify::may_write(ring.team(), record, signer, signing_key, &chains)? {
            return Err(TeamError::Untrusted(format!("written by one who could not write under epoch {epoch}")));
        }
        self.teams.check_signer(signer, verify::chain_of(&chains, signer), signing_key).await
    }

    /// [name] opened and checked, and its version; `None` when there is
    /// none.
    pub async fn read(&self, name: &str) -> Result<Option<(Vec<u8>, String)>, TeamError> {
        let Some((sealed, etag, signed)) = self.sync.download_bytes(name).await? else { return Ok(None) };
        let version = signed.as_ref().and_then(|s| s.version).ok_or_else(|| TeamError::Untrusted(format!("{name}: no version")))?;
        let body = digest(&sealed);
        let epoch = self
            .check_signed(signed.as_ref(), name, None, true, |e| crypto::sync_file_message(&self.owner, &self.app, name, e, version, &body))
            .await?;
        let key = self.version_key(name);
        if version < self.teams.version_of(&key).await {
            return Err(TeamError::Untrusted(format!("{name}: an older version than one seen")));
        }
        let plain = self.open(&sealed, Some(epoch)).await?;
        self.teams.saw_version(&key, version).await?;
        Ok(Some((plain, etag)))
    }

    /// [plain] sealed and signed as [name]'s next version, if [condition]
    /// holds.
    pub async fn write(&self, name: &str, plain: &[u8], condition: Condition) -> Result<String, TeamError> {
        let key = self.version_key(name);
        let mut version = self.teams.version_of(&key).await + 1;
        for again in [true, false] {
            let at = version;
            let written = self
                .sealed(
                    plain,
                    |epoch, sealed| WriteSig {
                        signature: self.sign(&crypto::sync_file_message(&self.owner, &self.app, name, epoch, at, &digest(sealed))),
                        version: Some(at),
                    },
                    |sealed, sig| {
                        let condition = condition.clone();
                        async move { self.sync.upload_signed(name, sealed, condition, Some(&sig)).await }
                    },
                )
                .await;
            match written {
                // Another device's version is higher: past it.
                Err(TeamError::Sync(Kind::Version(highest), _)) if again => version = highest + 1,
                Ok(etag) => {
                    self.teams.saw_version(&key, at).await?;
                    return Ok(etag);
                }
                Err(e) => return Err(e),
            }
        }
        unreachable!("the loop answers on its last turn")
    }

    pub async fn delete(&self, name: &str, if_match: Option<&str>) -> Result<bool, TeamError> {
        Ok(self.sync.delete(name, if_match).await?)
    }

    /// [plain] sealed, signed and appended once per [key]. Sealing is random,
    /// so a retry of [key] sends the bytes its first try sent (kept until it
    /// is answered), as homebase takes only those again.
    pub async fn append(&self, key: &str, plain: &[u8]) -> Result<Appended, TeamError> {
        let kept = self.appending.lock().unwrap_or_else(|e| e.into_inner()).get(key).cloned();
        let batch_sig = |epoch: i64, sealed: &[u8]| self.sign(&crypto::sync_batch_message(&self.owner, &self.app, epoch, &digest(sealed), key));
        let ring = self.ring.read().await;
        let (sealed, signature) = match kept {
            Some((epoch, sealed, signature)) if epoch == ring.epoch() => (sealed, signature),
            _ => {
                let sealed = ring.seal(plain)?;
                let signature = batch_sig(ring.epoch(), &sealed);
                (sealed, signature)
            }
        };
        self.keep_appending(key, ring.epoch(), sealed.clone(), signature.clone());
        let first = self.sync.append_signed(key, sealed, Some(&WriteSig { signature, version: None })).await;
        drop(ring);
        let answered = match first {
            // Refused, so not taken: sealed anew under the new key.
            Err(e) if matches!(e.kind, Kind::StaleEpoch(_)) => {
                self.refresh().await?;
                let ring = self.ring.read().await;
                let sealed = ring.seal(plain)?;
                let signature = batch_sig(ring.epoch(), &sealed);
                self.keep_appending(key, ring.epoch(), sealed.clone(), signature.clone());
                self.sync.append_signed(key, sealed, Some(&WriteSig { signature, version: None })).await
            }
            other => other,
        };
        if !matches!(&answered, Err(e) if e.kind == Kind::Unreachable) {
            self.appending.lock().unwrap_or_else(|e| e.into_inner()).remove(key);
        }
        Ok(answered?)
    }

    fn keep_appending(&self, key: &str, epoch: i64, sealed: Vec<u8>, signature: String) {
        let mut kept = self.appending.lock().unwrap_or_else(|e| e.into_inner());
        if kept.len() >= APPENDING_MAX && !kept.contains_key(key) {
            kept.clear();
        }
        kept.insert(key.to_string(), (epoch, sealed, signature));
    }

    /// The log's batches after [after] of [log], opened and checked; one
    /// this device cannot open, or not signed by one who could write under
    /// its epoch, is named apart, its seq passed.
    ///
    pub async fn read_log(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<TeamLog, TeamError> {
        match self.sync.read_log(after, log, limit).await? {
            LogRead::Page { log, batches, head, snapshot_seq, more } => {
                let mut opened = Vec::with_capacity(batches.len());
                let mut unreadable = Vec::new();
                // Those failing are checked again once, after one read of the
                // keyring for the page.
                let mut failed = Vec::new();
                for b in batches {
                    match self.open_batch(&b, log.as_deref()).await {
                        Ok(body) => opened.push(Batch { body, ..b }),
                        Err(TeamError::Crypto(_) | TeamError::Untrusted(_)) => failed.push(b),
                        Err(e) => return Err(e),
                    }
                }
                if !failed.is_empty() {
                    self.refresh().await?;
                    for b in failed {
                        match self.open_batch(&b, log.as_deref()).await {
                            Ok(body) => opened.push(Batch { body, ..b }),
                            Err(TeamError::Crypto(_) | TeamError::Untrusted(_)) => unreadable.push(b.seq),
                            Err(e) => return Err(e),
                        }
                    }
                    opened.sort_by_key(|b| b.seq);
                }
                Ok(TeamLog::Page { log, batches: opened, unreadable, head, snapshot_seq, more })
            }
            LogRead::Compacted { log, snapshot_seq } => Ok(TeamLog::Compacted { log, snapshot_seq }),
        }
    }

    /// [b] of [log] checked and opened. Its signature names no seq: one
    /// shown again at another seq (homebase replaying it) is refused. The
    /// order of a page is homebase's word.
    async fn open_batch(&self, b: &Batch, log: Option<&str>) -> Result<Vec<u8>, TeamError> {
        let what = format!("batch {}", b.seq);
        let body = digest(&b.body);
        let idempotency = b.idempotency_key.as_deref().ok_or_else(|| TeamError::Untrusted(format!("{what}: no idempotency key")))?;
        let taken = (log.unwrap_or_default().to_string(), idempotency.to_string());
        if self.taken.lock().unwrap_or_else(|e| e.into_inner()).get(&taken).is_some_and(|seq| *seq != b.seq) {
            return Err(TeamError::Untrusted(format!("{what}: a batch shown before at another seq")));
        }
        let epoch = b.epoch.ok_or_else(|| TeamError::Untrusted(format!("{what}: no epoch")))?;
        let epoch = self
            .check_signed(b.signed.as_ref(), &what, Some(epoch), false, |e| crypto::sync_batch_message(&self.owner, &self.app, e, &body, idempotency))
            .await?;
        let plain = self.open(&b.body, Some(epoch)).await?;
        let mut held = self.taken.lock().unwrap_or_else(|e| e.into_inner());
        if held.len() >= TAKEN_MAX {
            held.clear();
        }
        held.insert(taken, b.seq);
        Ok(plain)
    }

    /// [plain] sealed and signed as the log's snapshot up to [seq].
    pub async fn put_snapshot(&self, seq: i64, plain: &[u8]) -> Result<String, TeamError> {
        self.sealed(
            plain,
            |epoch, sealed| WriteSig { signature: self.sign(&crypto::sync_snapshot_message(&self.owner, &self.app, epoch, seq, &digest(sealed))), version: None },
            |sealed, sig| async move { self.sync.put_snapshot_signed(seq, sealed, Some(&sig)).await },
        )
        .await
    }

    /// The log's snapshot, opened and checked; `None` before there is one.
    pub async fn snapshot(&self) -> Result<Option<(Snapshot, Vec<u8>)>, TeamError> {
        let Some((s, sealed)) = self.sync.download_snapshot_bytes().await? else { return Ok(None) };
        let body = digest(&sealed);
        let epoch = self
            .check_signed(s.signed.as_ref(), "the snapshot", None, true, |e| crypto::sync_snapshot_message(&self.owner, &self.app, e, s.seq, &body))
            .await?;
        let plain = self.open(&sealed, Some(epoch)).await?;
        Ok(Some((s, plain)))
    }

    /// After a rotation: [name] read, checked, and written again under the
    /// current key; read again when another wrote meanwhile.
    pub(crate) async fn reseal(&self, name: &str) -> Result<(), TeamError> {
        loop {
            let Some((plain, etag)) = self.read(name).await? else { return Ok(()) };
            match self.write(name, &plain, Condition::Match(etag)).await {
                Ok(_) => return Ok(()),
                Err(TeamError::Sync(Kind::Changed, _)) => continue,
                Err(e) => return Err(e),
            }
        }
    }

    /// After a rotation: the snapshot written again under the current key,
    /// at its own seq (homebase takes that once, from a newer epoch).
    pub(crate) async fn reseal_snapshot(&self) -> Result<(), TeamError> {
        let Some((s, plain)) = self.snapshot().await? else { return Ok(()) };
        self.put_snapshot(s.seq, &plain).await.map(|_| ())
    }

    /// [sealed] (of [epoch]) opened; with a keyring read again when it may
    /// be of an epoch newer than this one's.
    async fn open(&self, sealed: &[u8], epoch: Option<i64>) -> Result<Vec<u8>, TeamError> {
        let ring = self.ring().await;
        match ring.open(sealed) {
            Ok(plain) => Ok(plain),
            Err(_) if epoch.is_none_or(|e| e > ring.epoch()) => self.refresh().await?.open(sealed),
            Err(e) => Err(e),
        }
    }
}
