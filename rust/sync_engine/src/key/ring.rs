//! [KeyRing], every key of this process.

use super::*;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct RecoveredExternal {
    pub(super) key: String,
    /// The accounts with writes staged before the restart. A stage-less
    /// settlement or clear for one stands for what its account's remote shows
    /// now (opened with [key], or with another), which resolves every write
    /// it staged then at once; asked again, it changes nothing.
    pub(super) owners: BTreeSet<String>,
    /// An ownerless write was staged then: treated as unmatched by
    /// account-scoped stage-less settlement/clear so another account cannot
    /// clear it.
    pub(super) unowned: bool,
}

impl RecoveredExternal {
    pub(super) fn is_empty(&self) -> bool {
        self.owners.is_empty() && !self.unowned
    }
}

#[derive(Default)]
pub(super) struct SecretKeyInitState {
    /// Staged secret key that has already committed to a remote key file via
    /// internal key-file writes and has not yet finished promotion into
    /// `secrets.secret_key()`. While set, conflicting imports are rejected so
    /// the staged key stays recoverable.
    pub(super) committed_staged: Option<String>,
    /// Monotonic counter generating unique stage identities for unresolved
    /// external remote writes (such as LK Cloud's account key).
    pub(super) next_external_commit_id: u64,
    /// Unresolved external remote writes keyed by stage identity
    /// (`stage_id -> (creating_account, canonical_secret_key)`). Each settlement
    /// consumes only its matching stage so repeated clears or unrelated commits
    /// never drop another write's protection.
    pub(super) external_commits: HashMap<String, (Option<String>, String)>,
    /// Lazy-hydrated pre-restart external write intent from durable
    /// `pending["ext-intent:lkc-account-key"]`:
    /// - `None`: durable map not yet inspected on this `KeyRing` instance.
    /// - `Some(None)`: no unresolved pre-restart external write remains.
    /// - `Some(Some(rec))`: pre-restart external write(s) for `rec.key` remain
    ///   unresolved and stay protected per owner until settled via `stage_id == None`.
    pub(super) recovered_external_commit: Option<Option<RecoveredExternal>>,
}

#[derive(Default)]
pub(super) struct KeyTable {
    next_handle_id: u64,
    pub(super) keys: HashMap<String, Arc<SyncKey>>,
    /// Per-remote generation bumped whenever that remote's registered handle
    /// opens or is released, so a stale probe for one remote cannot be
    /// invalidated by unrelated activity on another remote.
    gens: HashMap<String, u64>,
    /// Per-remote forget generation bumped ONLY by [`KeyRing::forget`], so an
    /// in-flight write whose handle was forgotten never re-inserts a stale
    /// recovery entry into [`Self::pending_writes`], while ordinary
    /// [`KeyRing::release`] preserves recovery.
    forget_gens: HashMap<String, u64>,
    /// Highest `handle_id` that has already committed a remote key-file write
    /// per remote, preventing an earlier released handle's late completion from
    /// overwriting or re-inserting stale [`Self::pending_writes`].
    committed_handle_ids: HashMap<String, u64>,
    pub(super) next_pending_write_seq: u64,
    /// Committed remote key-file writes whose local signing watermark save has
    /// not yet completed, retained across [`KeyRing::release`] until flushed or
    /// [`KeyRing::forget`].
    pub(super) pending_writes: HashMap<String, PendingKeyWrite>,
    /// Active LK Cloud account as last synchronized via [`KeyRing::sync_lkc_account`],
    /// alongside all LK Cloud account IDs touched here, a monotonic switch
    /// counter for account switches / sign-outs, and per-account generations so
    /// first selecting an account invalidates stale other accounts without
    /// invalidating in-flight operations for the selected account.
    lkc_active: Option<Option<String>>,
    lkc_known: BTreeSet<String>,
    pub(super) lkc_switch_gen: u64,
    lkc_account_gens: HashMap<String, u64>,
}

impl KeyTable {
    fn gen_of(&self, id: &str) -> u64 {
        self.gens.get(id).copied().unwrap_or(0)
    }

    pub(super) fn bump_id(&mut self, id: &str) {
        let entry = self.gens.entry(id.to_string()).or_insert(0);
        *entry = entry.wrapping_add(1);
    }

    fn lkc_account_gen_of(&self, id: &str) -> u64 {
        self.lkc_account_gens.get(id).copied().unwrap_or(0)
    }

    fn bump_lkc_account_gen(&mut self, id: &str) {
        let entry = self.lkc_account_gens.entry(id.to_string()).or_insert(0);
        *entry = entry.wrapping_add(1);
    }

    pub(super) fn forget_gen_of(&self, id: &str) -> u64 {
        self.forget_gens.get(id).copied().unwrap_or(0)
    }

    fn bump_forget_gen(&mut self, id: &str) {
        let entry = self.forget_gens.entry(id.to_string()).or_insert(0);
        *entry = entry.wrapping_add(1);
    }

    pub(super) fn committed_handle_id(&self, id: &str) -> u64 {
        self.committed_handle_ids.get(id).copied().unwrap_or(0)
    }

    pub(super) fn record_committed_handle(&mut self, id: &str, handle_id: u64) {
        let entry = self.committed_handle_ids.entry(id.to_string()).or_insert(0);
        *entry = (*entry).max(handle_id);
    }

    pub(super) fn is_current(&self, id: &str, handle: &SyncKey) -> bool {
        self.keys.get(id).is_some_and(|registered| std::ptr::eq(Arc::as_ptr(registered), handle))
    }

    /// Whether LK Cloud account tokens captured for [id] still name the
    /// active (or not yet selected) account.
    pub(super) fn lkc_tokens_live(&self, id: &str, (switch_gen, account_gen): (u64, u64)) -> bool {
        self.lkc_switch_gen == switch_gen
            && self.lkc_account_gen_of(id) == account_gen
            && self.lkc_active.as_ref().is_none_or(|a| a.as_deref() == Some(id))
    }
}

pub(super) struct RingInner {
    pub(super) secrets: Arc<dyn Secrets>,
    /// The comment the key file starts with: `<label>, epoch <n>`.
    pub(super) label: String,
    pub(super) keys: StdMutex<KeyTable>,
    pub(super) mismatch: watch::Sender<BTreeSet<String>>,
    pub(super) secret_key_missing: watch::Sender<BTreeSet<String>>,
    /// Ring-wide generation bumped on credential changes and `recheck()`,
    /// invalidating in-flight probes across all remotes.
    recheck_gen: AtomicU64,
    /// Serializes read-modify-write updates to the shared `epochs` metadata map.
    pub(super) epochs_lock: Mutex<()>,
    /// Serializes read-modify-write updates to the shared `pending` map and
    /// coordinates outstanding `password_changed` notifications.
    pub(super) pending_lock: Mutex<PendingState>,
    /// Serializes secret-key generation/staging/import/persistence across all
    /// remotes sharing this [`KeyRing`].
    pub(super) secret_key_init: Mutex<SecretKeyInitState>,
}

pub(super) const EXTERNAL_COMMIT_ID: &str = "lkc-account-key";

impl RingInner {
    fn recheck_gen(&self) -> u64 {
        self.recheck_gen.load(Ordering::Acquire)
    }

    pub(super) fn bump_recheck_gen(&self) {
        self.recheck_gen.fetch_add(1, Ordering::AcqRel);
    }

    pub(super) fn said_mismatch(&self, id: &str) {
        self.secret_key_missing.send_if_modified(|now| now.remove(id));
        self.mismatch.send_if_modified(|now| now.insert(id.to_string()));
    }

    pub(super) fn said_missing(&self, id: &str) {
        self.mismatch.send_if_modified(|now| now.remove(id));
        self.secret_key_missing.send_if_modified(|now| now.insert(id.to_string()));
    }

    pub(super) fn said_ok(&self, id: &str) {
        self.mismatch.send_if_modified(|now| now.remove(id));
        self.secret_key_missing.send_if_modified(|now| now.remove(id));
    }

    pub(super) async fn password(&self) -> Result<Zeroizing<String>> {
        match self.secrets.password().await? {
            Some(p) if !p.is_empty() => Ok(Zeroizing::new(p)),
            _ => Err(Error::PasswordMissing),
        }
    }

}

/// Every [SyncKey] of this process, one per key file, and what the backup
/// password here does not open.
#[derive(Clone)]
pub struct KeyRing(pub(super) Arc<RingInner>);

impl KeyRing {
    /// [label] begins the key file's comment line (`ServerBox sync key`).
    pub fn new(secrets: Arc<dyn Secrets>, label: impl Into<String>) -> Self {
        Self(Arc::new(RingInner {
            secrets,
            label: label.into(),
            keys: StdMutex::new(KeyTable::default()),
            mismatch: watch::Sender::new(BTreeSet::new()),
            secret_key_missing: watch::Sender::new(BTreeSet::new()),
            recheck_gen: AtomicU64::new(0),
            epochs_lock: Mutex::new(()),
            pending_lock: Mutex::new(PendingState::default()),
            secret_key_init: Mutex::new(SecretKeyInitState::default()),
        }))
    }

    /// The key files the backup password here does not open. Nothing syncs to
    /// their remotes meanwhile.
    pub fn mismatch(&self) -> watch::Receiver<BTreeSet<String>> {
        self.0.mismatch.subscribe()
    }

    /// The key files that cannot be opened because this device has no
    /// client-side secret key.
    pub fn secret_key_missing(&self) -> watch::Receiver<BTreeSet<String>> {
        self.0.secret_key_missing.subscribe()
    }

    /// The handles registered, but one a first lookup still checks: that is
    /// the lookup's own to check.
    pub(super) fn keys(&self) -> Vec<Arc<SyncKey>> {
        let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        table.keys.values().filter(|k| !k.in_first_lookup()).cloned().collect()
    }

    /// [file]'s key, opened with the backup password here: one per remote,
    /// checked again at most every minute. [Error::PasswordMismatch] while the
    /// password does not open it. Without [create] (a restore, nothing
    /// synced), none is put where there is none: [Error::KeyNotHere].
    pub async fn of(&self, file: Arc<dyn KeyFile>, create: bool) -> Result<Arc<SyncKey>> {
        self.of_inner(file, create, false).await
    }

    /// Registers [account] as an LK Cloud key remote before opening, so a
    /// subsequent [`Self::sync_lkc_account`] switch or sign-out releases it.
    pub async fn of_lkc(&self, file: Arc<dyn KeyFile>, create: bool) -> Result<Arc<SyncKey>> {
        self.of_inner(file, create, true).await
    }

    async fn of_inner(&self, file: Arc<dyn KeyFile>, create: bool, lkc: bool) -> Result<Arc<SyncKey>> {
        let id = file.id();
        validate_remote_id(&id)?;
        let (key, start_lkc_tokens) = {
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            let tokens = if lkc {
                if table
                    .lkc_active
                    .as_ref()
                    .is_some_and(|a| a.as_deref() != Some(id.as_str()))
                {
                    return Err(Error::SignedOut);
                }
                table.lkc_known.insert(id.clone());
                Some((table.lkc_switch_gen, table.lkc_account_gen_of(&id)))
            } else {
                None
            };
            // A handle made under other LK Cloud account tokens (or none) is
            // replaced, so every write through the returned one checks these.
            match table.keys.get(&id).filter(|k| k.lkc_tokens == tokens) {
                Some(k) => {
                    *k.file.lock().unwrap_or_else(|e| e.into_inner()) = file;
                    k.lookups.fetch_add(1, Ordering::SeqCst);
                    (k.clone(), tokens)
                }
                None => {
                    table.next_handle_id = table.next_handle_id.wrapping_add(1);
                    let handle_id = table.next_handle_id;
                    let forget_gen = table.forget_gen_of(&id);
                    let key = Arc::new(SyncKey {
                        handle_id,
                        forget_gen,
                        lkc_tokens: tokens,
                        file: StdMutex::new(file),
                        ring: self.0.clone(),
                        state: StdMutex::new(State::default()),
                        checking: Mutex::new(()),
                        lookups: AtomicUsize::new(1),
                        handed_out: AtomicBool::new(false),
                        #[cfg(test)]
                        before_take_merge: StdMutex::new(None),
                    });
                    table.keys.insert(id.clone(), key.clone());
                    (key, tokens)
                }
            }
        };
        if let Err(e) = key.check(false, create).await {
            // A restore's lookup leaves nothing behind for a remote nothing
            // syncs to, unless another lookup holds or returned the handle;
            // any committed write awaiting watermark flush stays in
            // `KeyTable::pending_writes` across lookups and releases.
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            let others = key.lookups.fetch_sub(1, Ordering::SeqCst) - 1;
            if !create
                && others == 0
                && !key.handed_out.load(Ordering::SeqCst)
                && table.keys.get(&id).is_some_and(|k| Arc::ptr_eq(k, &key))
                && !table.pending_writes.contains_key(&id)
            {
                // What it said goes with it: nothing checks that remote now.
                table.keys.remove(&id);
                table.bump_id(&id);
                self.0.said_ok(&id);
            }
            if start_lkc_tokens.is_some_and(|t| !table.lkc_tokens_live(&id, t)) {
                return Err(Error::SignedOut);
            }
            return Err(e);
        }
        let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        key.lookups.fetch_sub(1, Ordering::SeqCst);
        key.handed_out.store(true, Ordering::SeqCst);
        if let Some(t) = start_lkc_tokens
            && !table.lkc_tokens_live(&id, t)
        {
            if table.keys.get(&id).is_some_and(|k| Arc::ptr_eq(k, &key)) {
                table.keys.remove(&id);
                table.bump_id(&id);
                self.0.said_ok(&id);
            }
            return Err(Error::SignedOut);
        }
        Ok(key)
    }

    /// Synchronizes the active LK Cloud account (`None` when signed out):
    /// invalidates any in-flight missing-key probe for a previous LK Cloud
    /// account and clears only that previous LK Cloud account's missing-key /
    /// mismatch status, preserving folder remotes and the newly active account.
    pub fn sync_lkc_account(&self, account: Option<&str>) {
        let active = account.filter(|s| validate_remote_id(s).is_ok());
        let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        let next_active = active.map(str::to_string);
        let was_unset = table.lkc_active.is_none();
        let prev_active = table.lkc_active.replace(next_active.clone()).flatten();
        let mut stale: Vec<String> = table
            .lkc_known
            .iter()
            .filter(|id| Some(id.as_str()) != active)
            .cloned()
            .collect();
        if let Some(prev) = prev_active.as_ref()
            && Some(prev.as_str()) != active
            && !stale.contains(prev)
        {
            stale.push(prev.clone());
        }
        // First selecting an account (`was_unset && active.is_some()`) preserves
        // in-flight tokens for that selected account while per-account
        // generations below invalidate any stale other accounts. Sign-out or
        // replacing an active account bumps `lkc_switch_gen` too.
        let switched = if was_unset {
            active.is_none()
        } else {
            prev_active != next_active
        };
        if switched {
            table.lkc_switch_gen = table.lkc_switch_gen.wrapping_add(1);
        }
        for id in stale {
            table.lkc_known.remove(&id);
            table.keys.remove(&id);
            table.bump_lkc_account_gen(&id);
            table.bump_id(&id);
            self.0.said_ok(&id);
        }
        if let Some(uid) = active {
            table.lkc_known.insert(uid.to_string());
        }
    }

    /// Captures the current LK Cloud account-switch generation and per-ID
    /// generation synchronously at probe creation time so an account switch,
    /// sign-out, or `release` before Tokio polls the probe future still
    /// invalidates it.
    pub fn register_lkc_probe(&self, account: &str) -> Result<(u64, u64)> {
        validate_remote_id(account)?;
        let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        if table
            .lkc_active
            .as_ref()
            .is_none_or(|a| a.as_deref() == Some(account))
        {
            table.lkc_known.insert(account.to_string());
        }
        Ok((table.lkc_switch_gen, table.gen_of(account)))
    }

    /// [id]'s remote is not synced here any more (turned off): its key is read
    /// again next time, and nothing is said of it meanwhile.
    pub fn release(&self, id: &str) {
        if validate_remote_id(id).is_err() {
            return;
        }
        let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
        table.lkc_known.remove(id);
        table.keys.remove(id);
        table.bump_id(id);
        self.0.said_ok(id);
    }

    /// [id]'s remote is gone from this device (signed out, another server): as
    /// [release], and what this device knew of its file goes too.
    pub async fn forget(&self, id: &str) -> Result<()> {
        validate_remote_id(id)?;
        {
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            table.lkc_known.remove(id);
            table.keys.remove(id);
            table.pending_writes.remove(id);
            table.committed_handle_ids.remove(id);
            table.bump_id(id);
            table.bump_forget_gen(id);
            self.0.said_ok(id);
        }
        self.0.clear_epoch(id).await?;
        self.0.clear_all_pending(id).await
    }

    /// Before the backup password here changes from [previous]: the files of
    /// the syncs on here, opened with it, are to be sealed with the new one.
    /// Kept on this device until then, so a restart or a remote out of reach
    /// meanwhile loses nothing; a file already waiting keeps the password it
    /// is sealed with.
    pub async fn password_changed(&self, previous: Option<String>) -> Result<()> {
        let Some(previous) = previous.filter(|p| !p.is_empty()) else { return Ok(()) };
        let mut st = self.0.pending_lock.lock().await;
        let mut pending = self.0.secrets.pending().await?;
        let ids: Vec<String> = self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys.keys().cloned().collect();
        for id in &ids {
            pending.entry(id.clone()).or_insert_with(|| previous.clone());
        }
        self.0.secrets.set_pending(pending).await?;
        for id in ids {
            let list = st.notified.entry(id).or_default();
            if !list.iter().any(|p| p == &previous) {
                list.push(previous.clone());
            }
        }
        Ok(())
    }

    /// [sealed] opened with a key of a sync on here that the password opens,
    /// looking again for newer keys when none does: what was downloaded from
    /// one of them.
    pub async fn open_any(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        loop {
            let keys: Vec<_> = self.keys().into_iter().filter(|k| k.lock().opened.is_some()).collect();
            let identities: Vec<_> = keys.iter().flat_map(|k| k.lock().parsed.clone()).collect();
            match open_with(sealed, &identities) {
                Err(Error::Unreadable(e)) => {
                    let mut found = false;
                    for k in &keys {
                        if k.refresh().await? {
                            found = true;
                            break;
                        }
                    }
                    if !found {
                        return Err(Error::Unreadable(e));
                    }
                }
                other => return other,
            }
        }
    }

    /// [sealed] opened with any key this device keeps, whatever syncs here
    /// now: a synced backup the person picked to restore. Not one of a remote
    /// the password here is refused by.
    pub async fn open_kept(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        let mut refused = self.0.mismatch.borrow().clone();
        refused.extend(self.0.secret_key_missing.borrow().iter().cloned());
        let mut identities: Vec<String> = Vec::new();
        for (id, k) in self.0.keys.lock().unwrap_or_else(|e| e.into_inner()).keys.iter() {
            if !refused.contains(id) {
                identities.extend(k.lock().identities.clone());
            }
        }
        for id in self.0.secrets.epochs().await?.into_keys() {
            if !id.starts_with(TWO_FA_PREFIX) && !refused.contains(&id) {
                identities.extend(lines(self.0.secrets.kept(id).await?.as_deref(), false));
            }
        }
        let mut seen = std::collections::HashSet::new();
        identities.retain(|i| seen.insert(i.clone()));
        if identities.is_empty() {
            return Err(Error::Unreadable("no sync key kept here".into()));
        }
        open_with(sealed, &parse_identities(&identities)?)
    }

    /// Whether [file] is there sealed with a secret key, read without opening
    /// or writing anything: a device holding none is to import the one that
    /// sealed it (or its password is not the file's). Said through
    /// [Self::secret_key_missing] until a recheck or the file opens here, only
    /// if this remote's open/release generation and ring recheck generation are
    /// still current.
    pub async fn sealed_with_secret_key(&self, file: Arc<dyn KeyFile>) -> Result<bool> {
        self.sealed_with_secret_key_inner(file, None).await
    }

    /// LK Cloud account variant of [`Self::sealed_with_secret_key`] bound to
    /// `(expected_switch_gen, expected_id_gen)` from [`Self::register_lkc_probe`].
    pub async fn lkc_sealed_with_secret_key(
        &self,
        file: Arc<dyn KeyFile>,
        expected_switch_gen: u64,
        expected_id_gen: u64,
    ) -> Result<bool> {
        self.sealed_with_secret_key_inner(file, Some((expected_switch_gen, expected_id_gen)))
            .await
    }

    async fn sealed_with_secret_key_inner(&self, file: Arc<dyn KeyFile>, lkc_probe: Option<(u64, u64)>) -> Result<bool> {
        let id = file.id();
        validate_remote_id(&id)?;
        let (recheck_before, id_gen_before, lkc_allowed_before) = {
            let mut table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            let (id_gen, allowed) = match lkc_probe {
                None => (table.gen_of(&id), true),
                Some((expected_switch_gen, expected_id_gen)) => {
                    let ok = table.lkc_switch_gen == expected_switch_gen
                        && table.gen_of(&id) == expected_id_gen
                        && table.lkc_active.as_ref().is_none_or(|a| a.as_deref() == Some(id.as_str()));
                    if ok {
                        table.lkc_known.insert(id.clone());
                    }
                    (expected_id_gen, ok)
                }
            };
            (self.0.recheck_gen(), id_gen, allowed)
        };
        let sk_before = self.0.secret_key().await?;
        let pwd = self.0.password().await?;
        let pending_before = self.0.secrets.pending().await?;
        let sealed = match file.read().await? {
            Some((body, _)) => {
                let epochs = self.0.secrets.epochs().await?;
                let upgraded_2fa = epochs.contains_key(&two_fa_key(&id));
                let verified = epochs.get(&id).copied();
                if upgraded_2fa {
                    true
                } else if let Some((old_epoch, _)) = read(&body, &pwd)?
                    && verified.is_none_or(|v| old_epoch >= v)
                {
                    false
                } else if let Some(previous) = pending_before.get(&id)
                    && previous.as_str() != pwd.as_str()
                    && let Some((old_epoch, _)) = read(&body, previous)?
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    false
                } else {
                    true
                }
            }
            None => false,
        };
        if sealed && sk_before.is_none() && lkc_allowed_before {
            let sk_now = self.0.secret_key().await?;
            let pwd_now = self.0.secrets.password().await?;
            let pending_now = self.0.secrets.pending().await?;
            if sk_now.is_none()
                && pwd_now.as_deref() == Some(pwd.as_str())
                && pending_now.get(&id) == pending_before.get(&id)
            {
                let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                let lkc_still_allowed = match lkc_probe {
                    None => true,
                    Some((expected_switch_gen, expected_id_gen)) => {
                        table.lkc_switch_gen == expected_switch_gen
                            && table.gen_of(&id) == expected_id_gen
                            && table.lkc_active.as_ref().is_none_or(|a| a.as_deref() == Some(id.as_str()))
                    }
                };
                let already_opened = table.keys.get(&id).is_some_and(|k| k.lock().opened.is_some());
                if lkc_still_allowed && !already_opened && table.gen_of(&id) == id_gen_before && self.0.recheck_gen() == recheck_before {
                    self.0.said_missing(&id);
                }
            }
        }
        Ok(sealed)
    }

    /// Every key in use checked again now: the password or the secret key
    /// here changed.
    pub async fn recheck(&self) {
        let keys = {
            let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
            self.0.bump_recheck_gen();
            let held: BTreeSet<String> = table.keys.keys().cloned().collect();
            // What only [Self::sealed_with_secret_key] said is said again when
            // asked again.
            self.0.secret_key_missing.send_if_modified(|now| {
                let before = now.len();
                now.retain(|id| held.contains(id));
                now.len() != before
            });
            // One a first lookup still checks is its own to check.
            table.keys.values().filter(|k| !k.in_first_lookup()).cloned().collect::<Vec<_>>()
        };
        for k in &keys {
            k.lock().checked_at = None;
        }
        for k in keys {
            // Said through [mismatch]; nothing else stops here.
            let _ = k.check(false, true).await;
        }
    }
}
