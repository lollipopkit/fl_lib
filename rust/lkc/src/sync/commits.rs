//! Watermarks of writes that committed while their local save failed:
//! flushed without writing again.

use super::*;

impl<S: Store> SyncClient<S> {
    /// Persists the local signing watermark for a file write that already
    /// committed remotely at [version] under [expected_user], without resending
    /// a conditional PUT even if [`Self::set_personal`] has since replaced the
    /// [`PersonalAuth`] instance for the same account.
    pub async fn flush_committed_file(&self, expected_user: &str, name: &str, version: i64) -> Result<(), Error> {
        const MAX_AUTH_REBIND_RETRIES: usize = 4;
        if version <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed file version {version}")));
        }
        for _ in 0..MAX_AUTH_REBIND_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            auth.record_file_version(&self.app, name, version).await?;
            let lock = self.file_lock(name);
            let _file_guard = lock.lock().await;
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if slot.generation == auth_gen && slot.auth.is_some() {
                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                if guard.generation == auth_gen {
                    guard.files.retain(|(file_name, _, _, mode), (_, _, entry_ver)| {
                        !(file_name == name && *mode == UploadMode::File && *entry_ver <= version)
                    });
                }
                return Ok(());
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during file watermark flush"))
    }

    /// Persists the local signing watermark for a snapshot write that already
    /// committed remotely at [seq] under [expected_user] (on [log], when known,
    /// or resolved from [body]'s recovery entry / `/snapshot` when [log] is
    /// `None`), without resending `PUT /snapshot`. Returns `(compatible, resolved_log)`.
    pub async fn flush_committed_snapshot_bytes(
        &self,
        expected_user: &str,
        log: Option<&str>,
        seq: i64,
        body: &[u8],
    ) -> Result<(bool, Option<String>), Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        if seq <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed snapshot seq {seq}")));
        }
        let commit_key = (seq, *blake3::hash(body).as_bytes());
        for _ in 0..MAX_CACHE_FLUSH_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before snapshot watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            let current_log = auth.signed_log_id(&self.app).await;
            enum FlushAction {
                Direct(String),
                Reconcile(u64, String),
                Missing,
            }
            let action = {
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen && slot.auth.is_some() {
                    let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        match guard.snapshots.get(&commit_key) {
                            Some((_, SnapshotLogBinding::Confirmed(k), _)) => FlushAction::Direct(k.clone()),
                            Some((id, SnapshotLogBinding::Assumed(_) | SnapshotLogBinding::Unknown, etag)) => {
                                FlushAction::Reconcile(*id, etag.clone())
                            }
                            None => FlushAction::Missing,
                        }
                    } else {
                        continue;
                    }
                } else {
                    continue;
                }
            };
            match action {
                FlushAction::Direct(resolved_log) => {
                    let compatible = self.flush_committed_snapshot(expected_user, Some(&resolved_log), seq).await?;
                    return Ok((compatible, compatible.then_some(resolved_log)));
                }
                FlushAction::Reconcile(entry_id, expected_etag) => {
                    match self.reconcile_snapshot_commit(&auth, auth_gen, commit_key, entry_id, &expected_etag).await? {
                        ReconciledSnapshot::Hit(_, resolved_log) => return Ok((true, Some(resolved_log))),
                        ReconciledSnapshot::Conflicted => return Ok((false, None)),
                        ReconciledSnapshot::Replaced(_) => continue,
                        ReconciledSnapshot::Gone => {
                            self.record_committed_snapshot(expected_user, log, seq, Settle::Entry(commit_key, entry_id)).await?;
                            return Ok((false, None));
                        }
                    }
                }
                FlushAction::Missing => {
                    let observed_conflicts = log.is_some_and(|target_log| {
                        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                        if slot.generation != auth_gen {
                            return false;
                        }
                        let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                        guard.generation == auth_gen
                            && guard.observed_log.as_deref().is_some_and(|obs| obs != target_log)
                    });
                    match log {
                        Some(target_log)
                            if !observed_conflicts
                                && (current_log.is_none() || current_log.as_deref() == Some(target_log)) =>
                        {
                            let compatible = self.flush_committed_snapshot(expected_user, Some(target_log), seq).await?;
                            return Ok((compatible, compatible.then(|| target_log.to_string())));
                        }
                        _ => match self.reconcile_detached_snapshot(&auth, auth_gen, commit_key).await? {
                            DetachedReconcile::Recovered(resolved_log) => return Ok((true, Some(resolved_log))),
                            DetachedReconcile::Conflicted => return Ok((false, None)),
                            DetachedReconcile::Gone => {
                                self.record_committed_snapshot(expected_user, log, seq, Settle::Nothing).await?;
                                return Ok((false, None));
                            }
                        },
                    }
                }
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during snapshot watermark flush"))
    }

    pub(super) async fn reconcile_detached_snapshot(
        &self,
        auth: &PersonalAuth,
        auth_gen: u64,
        commit_key: (i64, [u8; 32]),
    ) -> Result<DetachedReconcile, Error> {
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
            Fetched::Missing => Ok(DetachedReconcile::Gone),
            Fetched::Saved(_) => {
                let Some(snap) = found else {
                    return Err(Error::new(Kind::Invalid, "a snapshot without Sync-Log or Sync-Seq"));
                };
                let same_snapshot = snap.seq == seq && &digest == expected_digest;
                if snap.signed.is_none() {
                    if same_snapshot {
                        return Err(Error::new(
                            Kind::Untrusted,
                            format!("{}/snapshot seq {}: server stripped signature", self.app, snap.seq),
                        ));
                    }
                    auth.verify_snapshot_digest(&self.app, &snap, &digest).await?;
                    self.ensure_personal_gen(auth_gen)?;
                    return Ok(DetachedReconcile::Gone);
                }
                // Any log observed under `auth_gen` or recorded on this
                // `PersonalAuth` takes precedence over a detached recovery
                // probe for a different log.
                let recorded = auth
                    .verify_snapshot_digest_for_detached(&self.app, &snap, &digest, &self.observer(auth_gen))
                    .await?;
                self.ensure_personal_gen(auth_gen)?;
                if !recorded {
                    return Ok(DetachedReconcile::Conflicted);
                }
                Ok(if same_snapshot {
                    DetachedReconcile::Recovered(snap.log)
                } else {
                    DetachedReconcile::Gone
                })
            }
            Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a snapshot answered 304")),
        }
    }
    /// Persists the local signing watermark for a snapshot write that already
    /// committed remotely at [seq] under [expected_user] (on [log], when known),
    /// without resending `PUT /snapshot`. Returns `false` if another log
    /// superseded [log], including one observed while its binding was saved.
    /// On an unknown log only the signed-snapshot marker is kept: [seq] belongs
    /// to no known log's floor.
    pub async fn flush_committed_snapshot(&self, expected_user: &str, log: Option<&str>, seq: i64) -> Result<bool, Error> {
        self.record_committed_snapshot(expected_user, log, seq, Settle::Covered(log.map(str::to_string), seq)).await
    }

    /// [`Self::flush_committed_snapshot`], settling recovery entries by [settle]
    /// once the watermark is persisted.
    async fn record_committed_snapshot(&self, expected_user: &str, log: Option<&str>, seq: i64, settle: Settle) -> Result<bool, Error> {
        const MAX_AUTH_REBIND_RETRIES: usize = 4;
        if seq <= 0 {
            return Err(Error::new(Kind::Invalid, format!("invalid committed snapshot seq {seq}")));
        }
        for _ in 0..MAX_AUTH_REBIND_RETRIES {
            let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
                return Err(Error::new(Kind::SignedOut, "personal signing auth detached before snapshot watermark flush"));
            };
            if auth.user_id().await != expected_user {
                return Err(Error::new(Kind::SignedOut, "personal signing auth belongs to a different user"));
            }
            let recorded = match log {
                Some(_) => auth.record_snapshot_if_log_compatible(&self.app, log, seq, &self.observer(auth_gen)).await,
                None => auth.record_snapshot_seen(&self.app).await.map(|()| true),
            };
            let compatible = match recorded {
                Ok(compatible) => compatible,
                Err(e) if e.kind == Kind::SignedOut && self.ensure_personal_gen(auth_gen).is_err() => continue,
                Err(e) => return Err(e),
            };
            if self.settle_committed_snapshots(auth_gen, settle.clone()) {
                return Ok(compatible);
            }
        }
        Err(Error::new(Kind::Invalid, "personal signing auth changed during snapshot watermark flush"))
    }

    /// Drops the recovery entries [settle] names; false when the signing auth
    /// changed.
    pub(super) fn settle_committed_snapshots(&self, auth_gen: u64, settle: Settle) -> bool {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation != auth_gen || slot.auth.is_none() {
            return false;
        }
        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation != auth_gen {
            return true;
        }
        match settle {
            Settle::Nothing => {}
            Settle::Entry(key, id) => {
                if guard.snapshots.get(&key).is_some_and(|(cur_id, _, _)| *cur_id == id) {
                    guard.snapshots.remove(&key);
                }
            }
            Settle::Covered(log, seq) => guard.snapshots.retain(|(entry_seq, _), (_, binding, _)| {
                if *entry_seq > seq {
                    return true;
                }
                match (log.as_deref(), binding) {
                    (Some(l), SnapshotLogBinding::Confirmed(k) | SnapshotLogBinding::Assumed(k)) => k != l,
                    (Some(_), SnapshotLogBinding::Unknown) => true,
                    (None, SnapshotLogBinding::Confirmed(_) | SnapshotLogBinding::Assumed(_)) => true,
                    (None, SnapshotLogBinding::Unknown) => false,
                }
            }),
        }
        true
    }

    /// Records what a request sent at [ticket] ([Self::observation_ticket])
    /// observed: [observed_log], or none (the log gone, its entries with it).
    /// False, changing nothing, when one sent later observed another log:
    /// that one is newer and keeps what is bound to it.
    pub(super) fn retain_log_commits(&self, auth_gen: u64, observed_log: Option<&str>, ticket: u64) -> bool {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation != auth_gen {
            return true;
        }
        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation != auth_gen {
            return true;
        }
        match observed_log {
            Some(log_id) => guard.observe_at(log_id, ticket),
            None if ticket < guard.observed_ticket => false,
            None => {
                guard.batches.clear();
                guard.snapshots.clear();
                guard.recovered_snapshots.clear();
                true
            }
        }
    }

    /// The place of a request about to be sent in the order observations are
    /// taken in ([Self::retain_log_commits]).
    pub(super) fn observation_ticket(&self, auth_gen: u64) -> u64 {
        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation == auth_gen { guard.ticket() } else { 0 }
    }
}
