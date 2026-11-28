//! The log's snapshot: put, reconciled after a lost answer, and read.

use super::*;

impl<S: Store> SyncClient<S> {
    /// [from] as the log's snapshot up to [seq]: further than the last, up to
    /// the head. Answers its version.
    pub async fn put_snapshot(&self, seq: i64, from: &Path) -> Result<String, Error> {
        self.put_snapshot_bytes(seq, read_file(from).await?).await
    }

    /// [body] as the log's snapshot up to [seq].
    pub async fn put_snapshot_bytes(&self, seq: i64, body: Vec<u8>) -> Result<String, Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.put_snapshot_signed(seq, body, None).await;
        };
        // Every request of the write, an upload's too, goes under the session
        // and auth it began with.
        let bound = Some((self.session.identity().ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?, auth_gen, true));
        let body = bytes::Bytes::from(body);
        let commit_key = (seq, *blake3::hash(&body).as_bytes());
        let mut expected_id = {
            let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
            (guard.generation == auth_gen)
                .then(|| guard.snapshots.get(&commit_key).map(|(id, _, _)| *id))
                .flatten()
        };
        let mut gone_entry = None;
        if expected_id.is_some() {
            for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                let Some(entry_id) = expected_id else { break };
                let flushed = auth.flush_pending_versions().await;
                let current_log = auth.signed_log_id(&self.app).await;
                match flushed {
                    Ok(()) => {
                        enum CacheCheck {
                            Hit(String),
                            HitAndRecordLog(String, String),
                            NeedReconcile(String),
                            Replaced(u64),
                            Gone,
                        }
                        let check = {
                            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                            if slot.generation == auth_gen {
                                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                if guard.generation == auth_gen {
                                    match guard.snapshots.get(&commit_key) {
                                        Some((cur_id, _, _)) if *cur_id != entry_id => CacheCheck::Replaced(*cur_id),
                                        Some((_, SnapshotLogBinding::Confirmed(k), _)) => match current_log.as_deref() {
                                            Some(cur) if cur == k => {
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                guard.recovered_snapshot(commit_key, entry_id, &etag);
                                                CacheCheck::Hit(etag)
                                            }
                                            Some(_) => {
                                                guard.snapshots.remove(&commit_key);
                                                CacheCheck::Gone
                                            }
                                            None => {
                                                let k = k.clone();
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                CacheCheck::HitAndRecordLog(k, etag)
                                            }
                                        },
                                        Some((_, SnapshotLogBinding::Assumed(k), _)) => {
                                            if current_log.as_deref() == Some(k.as_str()) {
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                guard.recovered_snapshot(commit_key, entry_id, &etag);
                                                CacheCheck::Hit(etag)
                                            } else {
                                                let etag = guard.snapshots.get(&commit_key).expect("entry present").2.clone();
                                                CacheCheck::NeedReconcile(etag)
                                            }
                                        }
                                        Some((_, SnapshotLogBinding::Unknown, etag)) => {
                                            CacheCheck::NeedReconcile(etag.clone())
                                        }
                                        // Recovered by another retry meanwhile: its ETag.
                                        None => guard.recovered_etag(&commit_key, entry_id).map_or(CacheCheck::Gone, CacheCheck::Hit),
                                    }
                                } else {
                                    CacheCheck::Gone
                                }
                            } else {
                                CacheCheck::Gone
                            }
                        };
                        match check {
                            CacheCheck::Hit(etag) => return Ok(etag),
                            CacheCheck::HitAndRecordLog(log_id, etag) => {
                                let compatible = match auth
                                    .record_snapshot_if_log_compatible(&self.app, Some(&log_id), seq, &PendingLogObserver { client: self, auth_gen })
                                    .await
                                {
                                    Ok(compatible) => compatible,
                                    Err(e) => {
                                        if e.kind == Kind::Invalid {
                                            let cur_now = auth.signed_log_id(&self.app).await;
                                            let still_valid = {
                                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                                if slot.generation == auth_gen {
                                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                                    if guard.generation == auth_gen {
                                                        match guard.snapshots.get(&commit_key) {
                                                            Some((cur_id, _, _))
                                                                if *cur_id == entry_id
                                                                    && cur_now.as_deref().is_none_or(|c| c == log_id) =>
                                                            {
                                                                Some(etag)
                                                            }
                                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                                guard.snapshots.remove(&commit_key);
                                                                None
                                                            }
                                                            _ => None,
                                                        }
                                                    } else {
                                                        None
                                                    }
                                                } else {
                                                    None
                                                }
                                            };
                                            if let Some(valid_etag) = still_valid {
                                                return Err(e.with_committed(Committed::Snapshot {
                                                    etag: valid_etag,
                                                    seq,
                                                    log: Some(log_id),
                                                }));
                                            }
                                        }
                                        return Err(e);
                                    }
                                };
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.snapshots.get(&commit_key) {
                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                if compatible {
                                                    guard.recovered_snapshot(commit_key, entry_id, &etag);
                                                    return Ok(etag);
                                                }
                                                guard.snapshots.remove(&commit_key);
                                                break;
                                            }
                                            Some((cur_id, _, _)) => {
                                                expected_id = Some(*cur_id);
                                                continue;
                                            }
                                            None => break,
                                        }
                                    }
                                }
                                break;
                            }
                            CacheCheck::NeedReconcile(expected_etag) => {
                                self.ensure_personal_gen(auth_gen)?;
                                match self
                                    .reconcile_snapshot_commit(&auth, auth_gen, commit_key, entry_id, &expected_etag)
                                    .await?
                                {
                                    ReconciledSnapshot::Hit(etag, _) => return Ok(etag),
                                    // Kept for the log observed; this PUT is judged by the server.
                                    ReconciledSnapshot::Conflicted => break,
                                    ReconciledSnapshot::Replaced(next_id) => {
                                        expected_id = Some(next_id);
                                        continue;
                                    }
                                    ReconciledSnapshot::Gone => {
                                        // Superseded by the PUT sent next; settled after the barrier below.
                                        gone_entry = Some(entry_id);
                                        break;
                                    }
                                }
                            }
                            CacheCheck::Replaced(next_id) => {
                                expected_id = Some(next_id);
                                continue;
                            }
                            CacheCheck::Gone => break,
                        }
                    }
                    Err(e) => {
                        if e.kind == Kind::Invalid {
                            let still_valid = {
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.snapshots.get(&commit_key) {
                                            Some((cur_id, SnapshotLogBinding::Confirmed(k), _))
                                                if *cur_id == entry_id && current_log.as_deref().is_some_and(|cur| cur != k) =>
                                            {
                                                guard.snapshots.remove(&commit_key);
                                                None
                                            }
                                            Some((cur_id, binding, etag)) if *cur_id == entry_id => {
                                                let confirmed_log = match binding {
                                                    SnapshotLogBinding::Confirmed(k) => Some(k.clone()),
                                                    SnapshotLogBinding::Assumed(_) | SnapshotLogBinding::Unknown => None,
                                                };
                                                Some((etag.clone(), confirmed_log))
                                            }
                                            _ => None,
                                        }
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                }
                            };
                            if let Some((etag, log)) = still_valid {
                                return Err(e.with_committed(Committed::Snapshot { etag, seq, log }));
                            }
                        }
                        return Err(e);
                    }
                }
            }
            self.ensure_personal_gen(auth_gen)?;
        }
        auth.flush_pending_versions().await?;
        self.ensure_personal_gen(auth_gen)?;
        if let Some(entry_id) = gone_entry
            && !self.settle_committed_snapshots(auth_gen, Settle::Entry(commit_key, entry_id))
        {
            return Err(Error::new(Kind::SignedOut, "personal signing auth changed during write"));
        }
        auth.ensure_published(&self.session, false).await?;
        self.ensure_personal_gen(auth_gen)?;
        let log_before = auth.signed_log_id(&self.app).await;
        let sig = auth.sign_snapshot(&self.app, seq, &body).await;
        let ticket = self.observation_ticket(auth_gen);
        let (etag, resp_log) = match self.put_snapshot_signed_bytes(bound, seq, body.clone(), Some(&sig)).await {
            Err(e) if matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                self.ensure_personal_gen(auth_gen)?;
                auth.ensure_published(&self.session, true).await?;
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_snapshot(&self.app, seq, &body).await;
                self.put_snapshot_signed_bytes(bound, seq, body, Some(&sig)).await?
            }
            other => other?,
        };
        // Answered on a log another observation replaced meanwhile: only its
        // signed-snapshot marker is kept, the newer log's binding untouched.
        if let Some(ref log_id) = resp_log
            && !self.retain_log_commits(auth_gen, Some(log_id), ticket)
        {
            return match auth.record_snapshot_seen(&self.app).await {
                Ok(()) => Ok(etag),
                Err(e) if e.kind == Kind::Invalid => {
                    // Kept for a retry as the main path keeps it: a hit while
                    // its log is the one observed, a fresh write otherwise.
                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                    if slot.generation == auth_gen {
                        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                        if guard.generation == auth_gen {
                            let id = guard.next_id();
                            guard.snapshots.insert(commit_key, (id, SnapshotLogBinding::Confirmed(log_id.clone()), etag.clone()));
                        }
                    }
                    Err(e.with_committed(Committed::Snapshot { etag, seq, log: resp_log }))
                }
                Err(e) => Err(e),
            };
        }
        if let Err(e) = auth.record_snapshot_written_on(&self.app, resp_log.as_deref(), seq).await {
            if e.kind == Kind::Invalid {
                let committed_log = resp_log.clone();
                let binding = match resp_log {
                    Some(log_id) => SnapshotLogBinding::Confirmed(log_id),
                    None => {
                        let log_after = auth.signed_log_id(&self.app).await;
                        match (log_before, log_after) {
                            (Some(before), Some(after)) if before == after => SnapshotLogBinding::Assumed(before),
                            _ => SnapshotLogBinding::Unknown,
                        }
                    }
                };
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        let id = guard.next_id();
                        guard.snapshots.insert(commit_key, (id, binding, etag.clone()));
                    }
                }
                return Err(e.with_committed(Committed::Snapshot { etag, seq, log: committed_log }));
            }
            return Err(e);
        }
        Ok(etag)
    }

    /// Reconciles an uncommitted-log snapshot recovery entry against `/snapshot`
    /// before reusing it. A `Gone` entry stays for the caller to settle after
    /// its durability barrier; network or persistence errors retain it too, so
    /// the committed snapshot remains recoverable on retry.
    pub(super) async fn reconcile_snapshot_commit(
        &self,
        auth: &PersonalAuth,
        auth_gen: u64,
        commit_key: (i64, [u8; 32]),
        entry_id: u64,
        expected_etag: &str,
    ) -> Result<ReconciledSnapshot, Error> {
        let (seq, ref expected_digest) = commit_key;
        let mut digest = [0u8; 32];
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), Target::HashOnly(&mut digest), None, |response| {
                found = answered_snapshot(response);
            })
            .await?;
        self.ensure_personal_gen(auth_gen)?;
        match fetched {
            Fetched::Missing => {
                // Left for the caller to settle once the marker is persisted.
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen
                        && let Some((cur_id, _, _)) = guard.snapshots.get(&commit_key)
                        && *cur_id != entry_id
                    {
                        return Ok(ReconciledSnapshot::Replaced(*cur_id));
                    }
                } else {
                    drop(slot);
                    self.ensure_personal_gen(auth_gen)?;
                }
                Ok(ReconciledSnapshot::Gone)
            }
            Fetched::Saved(remote_etag) => {
                let Some(snap) = found else {
                    return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                };
                let same_snapshot = remote_etag == expected_etag && snap.seq == seq && &digest == expected_digest;
                let verified = auth
                    .verify_snapshot_digest_observed(&self.app, &snap, &digest, &PendingLogObserver { client: self, auth_gen })
                    .await;
                if matches!(verified, Ok(false)) {
                    // Another log observed live: nothing was bound to this one.
                    self.ensure_personal_gen(auth_gen)?;
                    return Ok(ReconciledSnapshot::Conflicted);
                }
                if let Err(e) = verified {
                    self.ensure_personal_gen(auth_gen)?;
                    if e.kind == Kind::Invalid && same_snapshot {
                        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                        if slot.generation == auth_gen && slot.auth.is_some() {
                            let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                            if guard.generation == auth_gen
                                && let Some((cur_id, binding, _)) = guard.snapshots.get_mut(&commit_key)
                                && *cur_id == entry_id
                            {
                                // Keep the entry in `Unknown` until persisting the verified log ID
                                // succeeds so a mismatch with the still-unpersisted `PersonalAuth`
                                // log ID cannot discard the recovery entry on the next retry.
                                *binding = SnapshotLogBinding::Unknown;
                                return Err(e.with_committed(Committed::Snapshot {
                                    etag: expected_etag.to_string(),
                                    seq,
                                    log: Some(snap.log),
                                }));
                            }
                        } else {
                            drop(slot);
                            self.ensure_personal_gen(auth_gen)?;
                        }
                    }
                    return Err(e);
                }
                self.ensure_personal_gen(auth_gen)?;
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        // A log observed live under `auth_gen` takes precedence:
                        // its observation and recovery entries stay. Only an
                        // unsigned snapshot gets here unordered by the verification.
                        if guard.observed_log.as_deref().is_some_and(|obs| obs != snap.log) {
                            return Ok(ReconciledSnapshot::Conflicted);
                        }
                        guard.observe(&snap.log);
                        return Ok(match guard.snapshots.get(&commit_key) {
                            Some((cur_id, _, _)) if *cur_id == entry_id && same_snapshot => {
                                guard.recovered_snapshot(commit_key, entry_id, expected_etag);
                                ReconciledSnapshot::Hit(expected_etag.to_string(), snap.log)
                            }
                            Some((cur_id, _, _)) if *cur_id == entry_id => ReconciledSnapshot::Gone,
                            Some((cur_id, _, _)) => ReconciledSnapshot::Replaced(*cur_id),
                            None => match guard.recovered_etag(&commit_key, entry_id) {
                                Some(etag) => ReconciledSnapshot::Hit(etag, snap.log),
                                None => ReconciledSnapshot::Gone,
                            },
                        });
                    }
                }
                drop(slot);
                self.ensure_personal_gen(auth_gen)?;
                Ok(ReconciledSnapshot::Gone)
            }
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }

    /// [put_snapshot_bytes], signed by its writer ([sig], no version).
    pub async fn put_snapshot_signed(&self, seq: i64, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<String, Error> {
        self.put_snapshot_signed_bytes(None, seq, bytes::Bytes::from(body), sig).await.map(|(etag, _)| etag)
    }

    async fn put_snapshot_signed_bytes(
        &self,
        bound: Option<(u64, u64, bool)>,
        seq: i64,
        bytes: bytes::Bytes,
        sig: Option<&WriteSig>,
    ) -> Result<(String, Option<String>), Error> {
        let path = format!("{}/snapshot", self.app_path()?);
        let size = bytes.len() as u64;
        let session = bound.map(|(s, _, _)| s);
        if size <= DIRECT_MAX {
            let response = self
                .send_for(bound, Method::PUT, &format!("{path}?seq={seq}"), |r| {
                    signed_by(r, sig).header(header::CONTENT_TYPE, "application/octet-stream").header(header::CONTENT_LENGTH, size).body(bytes.clone())
                })
                .await?;
            let sync_log = answered_log(header_non_empty(&response, "sync-log"))?;
            return self.written_version_for(session, response).await.map(|etag| (etag, sync_log));
        }
        let response = self
            .send_for(bound, Method::POST, &format!("{path}/uploads?seq={seq}"), |r| signed_by(r, sig).json(&serde_json::json!({ "size": size })))
            .await?;
        let begun: Begun = self.json_for(session, response, MAX_JSON).await?;
        self.store_upload(&begun.url, bytes).await?;
        self.complete_with_log_for(bound, &path, &begun.id).await
    }

    /// The log's snapshot written to [to]; `None` before there is one.
    pub async fn download_snapshot(&self, to: &Path) -> Result<Option<Snapshot>, Error> {
        if let Some((auth_gen, auth)) = self.personal_auth_with_gen() {
            let lock = self.dest_lock(to);
            let _guard = lock.lock().await;
            let mut part = None;
            let mut found = None;
            let mut digest = [0u8; 32];
            let ticket = self.observation_ticket(auth_gen);
            let fetched = self
                .fetch_with(&format!("{}/snapshot", self.app_path()?), Target::FileHashed(to, &mut part, &mut digest), None, |response| {
                    found = answered_snapshot(response);
                })
                .await?;
            return match fetched {
                Fetched::Missing => {
                    self.ensure_personal_gen(auth_gen)?;
                    Ok(None)
                }
                Fetched::Saved(_) => {
                    self.ensure_personal_gen(auth_gen)?;
                    let Some(snap) = found else {
                        return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                    };
                    auth.verify_snapshot_digest(&self.app, &snap, &digest).await?;
                    self.ensure_personal_gen(auth_gen)?;
                    self.retain_log_commits(auth_gen, Some(&snap.log), ticket);
                    let staged = part.ok_or_else(|| Error::new(Kind::Invalid, "missing staged snapshot file"))?;
                    self.publish_verified(auth_gen, staged, to)?;
                    Ok(Some(snap))
                }
                Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
            };
        }
        self.snapshot_into(Target::File(to)).await
    }

    /// The log's snapshot and its bytes; `None` before there is one.
    pub async fn download_snapshot_bytes(&self) -> Result<Option<(Snapshot, Vec<u8>)>, Error> {
        self.download_snapshot_bytes_checked().await.map(|(found, _)| found)
    }

    /// Like [`Self::download_snapshot_bytes`], also answering whether personal
    /// auth verified this read's signature.
    pub async fn download_snapshot_bytes_checked(&self) -> Result<(Option<(Snapshot, Vec<u8>)>, bool), Error> {
        let mut body = Vec::new();
        let auth = self.personal_auth_with_gen();
        let ticket = auth.as_ref().map_or(0, |(auth_gen, _)| self.observation_ticket(*auth_gen));
        let verified = auth.is_some();
        let Some(snap) = self.snapshot_into(Target::Memory(&mut body)).await? else {
            if let Some((auth_gen, _)) = auth {
                self.ensure_personal_gen(auth_gen)?;
            }
            return Ok((None, verified));
        };
        if let Some((auth_gen, auth)) = auth {
            self.ensure_personal_gen(auth_gen)?;
            auth.verify_snapshot(&self.app, &snap, &body).await?;
            self.ensure_personal_gen(auth_gen)?;
            self.retain_log_commits(auth_gen, Some(&snap.log), ticket);
        }
        Ok((Some((snap, body)), verified))
    }

    async fn snapshot_into(&self, into: Target<'_>) -> Result<Option<Snapshot>, Error> {
        let mut found = None;
        let fetched = self
            .fetch_with(&format!("{}/snapshot", self.app_path()?), into, None, |response| {
                found = answered_snapshot(response);
            })
            .await?;
        match fetched {
            Fetched::Missing => Ok(None),
            Fetched::Saved(_) => found.map(Some).ok_or_else(|| Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq")),
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }
}
