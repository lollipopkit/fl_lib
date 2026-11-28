//! A [SyncKey]'s checks, its key-file writes, and sealing with it.

use super::*;

impl SyncKey {
    pub(super) fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(super) fn file(&self) -> Arc<dyn KeyFile> {
        self.file.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Whether a lookup is checking it before any returned it.
    pub(super) fn in_first_lookup(&self) -> bool {
        self.lookups.load(Ordering::SeqCst) > 0 && !self.handed_out.load(Ordering::SeqCst)
    }

    /// Whether this is the handle registered for its remote.
    fn registered(&self) -> bool {
        self.ring.keys.lock().unwrap_or_else(|e| e.into_inner()).is_current(&self.id(), self)
    }

    /// [read]'s settling, held to the file bound now too: one bound since the
    /// read (another store, signed in again) settles nothing either does not.
    pub(super) fn settles_now(&self, read: Settles) -> Settles {
        read.and(Settles::of(&*self.file()))
    }

    pub fn id(&self) -> String {
        self.file().id()
    }

    /// Opened with the backup password here, read again past a minute, or now
    /// with [force]. [Error::PasswordMismatch] while the password does not
    /// open the file.
    pub async fn check(&self, force: bool, create: bool) -> Result<()> {
        if force {
            self.lock().checked_at = None;
        }
        let _checking = self.checking.lock().await;
        self.check_locked(force, create).await.map(|_| ())
    }

    async fn check_locked(&self, force: bool, create: bool) -> Result<Option<(Zeroizing<String>, SecretKey)>> {
        if force {
            self.lock().checked_at = None;
        }
        let id = self.id();
        let has_pending_write = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner()).pending_writes.contains_key(&id);
        if self.lock().checked_at.is_some_and(|at| at.elapsed() < RECHECK_AFTER) && !has_pending_write {
            let awaiting = self.lock().awaiting_secret_key;
            // Waiting for a secret key: one stored since (no recheck asked)
            // opens the file again at once.
            if self.ring.secret_key_missing.borrow().contains(&id) || (awaiting && self.ring.secret_key().await?.is_none()) {
                return Err(Error::SecretKeyMissing);
            }
            if !awaiting {
                if self.ring.mismatch.borrow().contains(&id) {
                    return Err(Error::PasswordMismatch(id));
                }
                if self.lock().opened.is_some() {
                    return Ok(None);
                }
            }
        }
        if self.lock().identities.is_empty() {
            let kept = self.ring.secrets.kept(self.id()).await?;
            self.use_identities(lines(kept.as_deref(), false), false).await?;
        }
        // Flush any committed remote key-file PUT whose local signing watermark
        // save previously failed, without resending the PUT.
        self.flush_pending_write().await?;
        // Once more when the password changed meanwhile: what was opened with
        // the one before is to be sealed with it.
        let mut pwd = self.ring.password().await?;
        self.lock().awaiting_secret_key = false;
        let opened_sk = loop {
            let (sk, mut seen) = match self.open(&pwd, create).await {
                Ok(opened) => opened,
                Err(e) => {
                    if matches!(e, Error::PasswordMismatch(_))
                        || (matches!(e, Error::SecretKeyMissing)
                            && (self.lock().awaiting_secret_key || self.ring.secret_key_missing.borrow().contains(&self.id())))
                    {
                        self.lock().checked_at = Some(Instant::now());
                    }
                    return Err(e);
                }
            };
            // Reconcile pending immediately for the password that just opened
            // the remote so a concurrent password change before the next loop
            // iteration never sees a stale older pending entry.
            // Only the handle registered for the remote settles, and only what
            // it still holds: one released meanwhile settles nothing and stops
            // there, its replacement's settlement standing.
            seen.read.settles = self.settles_now(seen.read.settles);
            let current = || self.registered() && self.lock().opened.as_ref().is_some_and(|(v, _)| *v == seen.version);
            if !self.ring.clear_pending_if_settled(&self.id(), self.forget_gen, &seen, &pwd, current).await? {
                if !self.registered() {
                    break sk;
                }
                continue;
            }
            let now = self.ring.password().await?;
            if *now == *pwd {
                break sk;
            }
            pwd = now;
        };
        self.lock().checked_at = Some(Instant::now());
        Ok(Some((pwd, opened_sk)))
    }

    async fn flush_pending_write(&self) -> Result<()> {
        let id = self.id();
        let pw = {
            let table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
            table.pending_writes.get(&id).cloned()
        };
        let Some(pw) = pw else {
            return Ok(());
        };
        self.file()
            .flush_committed_write(pw.version, pw.sync_version)
            .await?;
        let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
        if table.pending_writes.get(&id).is_some_and(|cur| cur.seq == pw.seq) {
            table.pending_writes.remove(&id);
        }
        Ok(())
    }

    /// Whether a new key-file write may start through this handle: its remote
    /// is not forgotten and, for an LK Cloud account, still the selected one.
    /// Recovery of an already committed write checks only the forget
    /// generation.
    fn writable_in(&self, table: &KeyTable, id: &str) -> Result<()> {
        if table.forget_gen_of(id) != self.forget_gen || self.lkc_tokens.is_some_and(|t| !table.lkc_tokens_live(id, t)) {
            return Err(Error::SignedOut);
        }
        Ok(())
    }

    pub(super) fn ensure_writable(&self, id: &str) -> Result<()> {
        self.writable_in(&self.ring.keys.lock().unwrap_or_else(|e| e.into_inner()), id)
    }

    /// Performs a conditional key-file write, separating a committed remote PUT
    /// whose local signing watermark save failed (`Ok(Some((version, Some(detail))))`)
    /// from a CAS miss (`Ok(None)` -> HTTP 412) and uncommitted transport errors.
    pub(super) async fn commit_key_file(&self, body: Vec<u8>, if_version: Option<String>) -> Result<Option<(String, Option<String>)>> {
        let id = self.id();
        let superseded_seq = self.admit_write(&id)?;
        self.put_key_file(id, superseded_seq, body, if_version).await
    }

    /// [Self::commit_key_file] behind a pre-CAS write intent for `(epoch,
    /// pwd)`: rolled back when the write is refused before dispatch or loses
    /// its CAS, kept whenever the PUT may have reached the backend.
    pub(super) async fn commit_key_file_with_intent(
        &self,
        body: Vec<u8>,
        if_version: Option<String>,
        epoch: i64,
        pwd: &str,
    ) -> Result<Option<(String, Option<String>)>> {
        let id = self.id();
        let staged = self.ring.stage_write_intent(&id, self.forget_gen, epoch, pwd).await?;
        self.ring.dispatching(&id, &staged.intent).await;
        // Admitted last: nothing is awaited between the check and the PUT, so
        // no account switch meanwhile sends it under another.
        let superseded_seq = match self.admit_write(&id) {
            Ok(seq) => seq,
            Err(e) => {
                // A rollback that fails leaves an intent for a write that never
                // committed: it goes once the verified epoch floor passes it.
                let _ = self.ring.rollback_write_intent(&id, self.forget_gen, &staged).await;
                return Err(e);
            }
        };
        let res = self.put_key_file(id.clone(), superseded_seq, body, if_version).await;
        if matches!(res, Ok(None)) {
            let _ = self.ring.rollback_write_intent(&id, self.forget_gen, &staged).await;
        }
        res
    }

    /// Whether a write may be dispatched now, with the pending write it would
    /// supersede.
    fn admit_write(&self, id: &str) -> Result<Option<u64>> {
        let table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
        self.writable_in(&table, id)?;
        Ok(table
            .pending_writes
            .get(id)
            .filter(|pw| pw.handle_id <= self.handle_id)
            .map(|pw| pw.seq))
    }

    async fn put_key_file(
        &self,
        id: String,
        superseded_seq: Option<u64>,
        body: Vec<u8>,
        if_version: Option<String>,
    ) -> Result<Option<(String, Option<String>)>> {
        match self.file().write(body.clone(), if_version.clone()).await {
            Ok(Some(version)) => {
                let forgotten = {
                    let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                    if table.forget_gen_of(&id) != self.forget_gen {
                        true
                    } else {
                        table.record_committed_handle(&id, self.handle_id);
                        if table.pending_writes.get(&id).is_some_and(|cur| {
                            cur.handle_id < self.handle_id || Some(cur.seq) == superseded_seq
                        }) {
                            table.pending_writes.remove(&id);
                        }
                        false
                    }
                };
                if forgotten {
                    return Err(Error::SignedOut);
                }
                Ok(Some((version, None)))
            }
            Ok(None) => {
                self.ring.ensure_not_forgotten(&id, self.forget_gen)?;
                Ok(None)
            }
            Err(Error::KeyFilePersistFailed { version, sync_version, detail }) => {
                let forgotten = {
                    let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                    if table.forget_gen_of(&id) != self.forget_gen {
                        true
                    } else {
                        let superseded_by_newer_handle = table.committed_handle_id(&id) > self.handle_id
                            || table.pending_writes.get(&id).is_some_and(|cur| {
                                cur.handle_id > self.handle_id
                                    || match (cur.sync_version, sync_version) {
                                        (Some(cur_v), Some(new_v)) => cur_v > new_v,
                                        _ => false,
                                    }
                            });
                        if !superseded_by_newer_handle {
                            table.record_committed_handle(&id, self.handle_id);
                            table.next_pending_write_seq = table.next_pending_write_seq.wrapping_add(1);
                            let seq = table.next_pending_write_seq;
                            table.pending_writes.insert(
                                id,
                                PendingKeyWrite {
                                    seq,
                                    handle_id: self.handle_id,
                                    version: version.clone(),
                                    sync_version,
                                },
                            );
                        }
                        false
                    }
                };
                let mut s = self.lock();
                s.opened = None;
                s.checked_at = None;
                drop(s);
                if forgotten {
                    return Err(Error::SignedOut);
                }
                Ok(Some((version, Some(detail))))
            }
            Err(e) => Err(e),
        }
    }

    /// Serializes candidate secret-key acquisition, durable staging, remote
    /// conditional write, and final secret-key commit across all remotes
    /// sharing `self.ring`. Returns `Ok(None)` when the remote CAS write lost
    /// so the caller should re-read and retry.
    pub(super) async fn write_with_secret_key(
        &self,
        identities: &[String],
        epoch: i64,
        pwd: &str,
        if_version: Option<String>,
        settles: Settles,
    ) -> Result<Option<(String, SecretKey, Option<String>)>> {
        let mut init = self.ring.secret_key_init.lock().await;
        let id = self.id();
        self.ensure_writable(&id)?;
        let (sk, generated) = match self.ring.candidate_locked().await {
            Err(Error::SecretKeyMissing) => {
                // None may be made here: one is to be made or imported by
                // the person, and checks wait for it ([RECHECK_AFTER], or a
                // recheck) instead of opening the file again each time.
                self.lock().awaiting_secret_key = true;
                return Err(Error::SecretKeyMissing);
            }
            other => other?,
        };
        let body = self.sealed(identities, epoch, pwd, &sk)?;
        let Some((version, persist_err)) = self.commit_key_file_with_intent(body, if_version, epoch, pwd).await? else {
            return Ok(None);
        };
        if generated {
            init.committed_staged = Some(sk.format().to_string());
        }
        // The remote file is now committed under `(pwd, sk)` at `epoch`:
        // persist the epoch, reconcile `pending`, and clear the write intent
        // BEFORE `set_secret_key` or `set_kept`, so a later or concurrent
        // `password_changed` matches `pwd` instead of keeping a stale entry.
        if let Err(e) = self.ring.record_committed_write(&id, self.forget_gen, epoch, pwd, self.settles_now(settles)).await {
            init.committed_staged = None;
            return Err(e);
        }
        if generated {
            self.ring.commit_locked(&mut init, &sk, None).await?;
        }
        Ok(Some((version, sk, persist_err)))
    }

    /// A new key in place of this one, put in the file first, so a device that
    /// meets what it seals finds it there ([refresh]). Fails, changing nothing
    /// here, when another device changed the file meanwhile.
    pub async fn rotate(&self) -> Result<()> {
        self.rotate_with_hook(|| Box::pin(async { Ok(()) })).await
    }

    #[cfg(test)]
    pub(crate) fn set_before_take_merge<F>(&self, hook: F)
    where
        F: Fn() -> BoxFuture<'static, ()> + Send + Sync + 'static,
    {
        *self.before_take_merge.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(hook));
    }

    #[cfg(test)]
    pub(crate) async fn rotate_after_check<F>(&self, hook: F) -> Result<()>
    where
        F: FnOnce() -> BoxFuture<'static, Result<()>>,
    {
        self.rotate_with_hook(hook).await
    }

    async fn rotate_with_hook<F>(&self, after_check: F) -> Result<()>
    where
        F: FnOnce() -> BoxFuture<'static, Result<()>>,
    {
        let _checking = self.checking.lock().await;
        // Seal with the exact `(pwd, sk)` that opened the version validated by
        // `check_locked`, keeping `epoch` and `pending` consistent even if a
        // concurrent password change occurs before sealing and PUT commit.
        let (pwd, sk) = self
            .check_locked(true, true)
            .await?
            .ok_or_else(|| Error::Host("rotate did not verify key credentials".into()))?;
        after_check().await?;
        let (identities, epoch, opened) = {
            let s = self.lock();
            let mut identities = vec![generate()];
            identities.extend(s.identities.iter().cloned());
            identities.truncate(HISTORY + 1);
            (identities, s.epoch, s.opened.as_ref().map(|(v, _)| v.clone()))
        };
        let (version, persist_err) = {
            let _init = self.ring.secret_key_init.lock().await;
            self.ensure_writable(&self.id())?;
            let cur_sk = self.ring.secret_key().await?;
            if cur_sk.as_ref().map(|k| k.format()) != Some(sk.format()) {
                return Err(Error::Host("the secret key changed during rotation".into()));
            }
            let Some(res) = self.commit_key_file(self.sealed(&identities, epoch, &pwd, &sk)?, opened).await? else {
                return Err(Error::Host("identity.age changed meanwhile".into()));
            };
            res
        };
        {
            let mut s = self.lock();
            s.opened = None;
            s.checked_at = None;
        }
        self.use_identities(identities, true).await?;
        if let Some(detail) = persist_err {
            return Err(Error::Host(detail));
        }
        self.opened_at(epoch, &version, &pwd, &sk).await
    }

    /// [other] first, then those kept here, at most [HISTORY] besides the
    /// newest.
    pub(super) fn merged(&self, other: Vec<String>) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mine = self.lock().identities.clone();
        other.into_iter().chain(mine).filter(|i| seen.insert(i.clone())).take(HISTORY + 1).collect()
    }

    pub(super) async fn use_identities(&self, identities: Vec<String>, save: bool) -> Result<()> {
        if identities.is_empty() {
            return Ok(());
        }
        let parsed = parse_identities(&identities)?;
        let unsaved = {
            let mut s = self.lock();
            let changed = s.identities != identities;
            if changed || s.recipient.is_none() {
                s.recipient = Some(parsed[0].to_public());
            }
            s.identities = identities.clone();
            s.parsed = parsed;
            // Read from the keychain: what is held there already.
            s.unsaved = if save { s.unsaved || changed } else { s.unsaved && !changed };
            save && s.unsaved
        };
        if unsaved {
            let id = self.id();
            self.ring.ensure_not_forgotten(&id, self.forget_gen)?;
            self.ring.secrets.set_kept(id, identities.join("\n")).await?;
            let mut s = self.lock();
            if s.identities == identities {
                s.unsaved = false;
            }
        }
        Ok(())
    }

    pub(super) fn sealed(&self, identities: &[String], epoch: i64, pwd: &str, sk: &SecretKey) -> Result<Vec<u8>> {
        let mut text = Zeroizing::new(format!("# {}, epoch {epoch}", self.ring.label));
        for i in identities {
            text.push('\n');
            text.push_str(i);
        }
        let derived = sk.combine_passphrase(pwd);
        seal_with_password(text.as_bytes(), &derived)
    }

    /// [Seal::open], once more after looking for a newer key when none kept
    /// here opens it (it was replaced elsewhere).
    pub async fn open_fresh(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        match self.open_sealed(sealed) {
            Err(Error::Unreadable(e)) => {
                if !self.refresh().await? {
                    return Err(Error::Unreadable(e));
                }
                self.open_sealed(sealed)
            }
            other => other,
        }
    }

    fn open_sealed(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        let parsed = self.lock().parsed.clone();
        open_with(sealed, &parsed)
    }
}

impl Seal for SyncKey {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>> {
        let recipient = self.lock().recipient.clone().ok_or_else(|| Error::Host("the sync key is not opened".into()))?;
        let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient)).map_err(|e| Error::Host(e.to_string()))?;
        let mut out = Vec::with_capacity(plain.len() + 256);
        let mut w = encryptor.wrap_output(&mut out).map_err(|e| Error::Host(e.to_string()))?;
        w.write_all(plain).and_then(|_| w.finish()).map_err(|e| Error::Host(e.to_string()))?;
        Ok(out)
    }

    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        self.open_sealed(sealed)
    }

    fn name_of(&self, data: &[u8]) -> String {
        let first = self.lock().identities.first().cloned().unwrap_or_default();
        fl_sync::blob_name(&first, data)
    }

    fn matches_name_of(&self, name: &str, data: &[u8]) -> bool {
        self.lock()
            .identities
            .iter()
            .any(|id| name == fl_sync::blob_name(id, data))
    }

    /// Reads the file again: whether it held keys not here.
    async fn refresh(&self) -> Result<bool> {
        let before: std::collections::HashSet<String> = self.lock().identities.iter().cloned().collect();
        self.check(true, true).await?;
        Ok(!self.lock().identities.iter().all(|i| before.contains(i)))
    }
}
