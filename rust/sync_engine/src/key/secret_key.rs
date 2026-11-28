//! The client-side secret key: staged, committed, and recovered after a
//! remote write outside this ring.

use super::*;

impl RingInner {
    async fn hydrate_recovered_external_locked(&self, init: &mut SecretKeyInitState) -> Result<()> {
        if init.recovered_external_commit.is_some() {
            return Ok(());
        }
        let _st = self.pending_lock.lock().await;
        let pending = self.secrets.pending().await?;
        let recovered = pending.get(&external_intent_key(EXTERNAL_COMMIT_ID)).and_then(|raw| decode_external_intent(raw));
        init.recovered_external_commit = Some(recovered);
        Ok(())
    }

    async fn persist_external_intent_locked(
        &self,
        recovered: Option<&RecoveredExternal>,
        in_process: impl Iterator<Item = (Option<&str>, &str)>,
    ) -> Result<()> {
        let mut key: Option<String> = None;
        let mut owners = BTreeSet::new();
        let mut unowned = false;
        if let Some(rec) = recovered
            && !rec.is_empty()
        {
            key = Some(rec.key.clone());
            owners.extend(rec.owners.iter().cloned());
            unowned |= rec.unowned;
        }
        for (owner, cand) in in_process {
            if key.is_none() {
                key = Some(cand.to_string());
            }
            match owner {
                Some(uid) if !uid.is_empty() => {
                    owners.insert(uid.to_string());
                }
                _ => unowned = true,
            }
        }
        let Some(key) = key else {
            return self.clear_external_commit_intent_for(None).await;
        };
        let encoded = encode_external_intent(&RecoveredExternal { key, owners, unowned });
        let _st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let map_key = external_intent_key(EXTERNAL_COMMIT_ID);
        if all.get(&map_key) == Some(&encoded) {
            return Ok(());
        }
        all.insert(map_key, encoded);
        self.secrets.set_pending(all).await
    }

    async fn clear_external_commit_intent_for(&self, expected: Option<&str>) -> Result<()> {
        let _st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let key = external_intent_key(EXTERNAL_COMMIT_ID);
        let should_remove = match (all.get(&key), expected) {
            (None, _) => false,
            (Some(_), None) => true,
            (Some(raw), Some(cand)) => external_intent_secret_key(raw).is_none_or(|k| k == cand),
        };
        if should_remove {
            all.remove(&key);
            self.secrets.set_pending(all).await?;
        }
        Ok(())
    }

    pub(super) async fn secret_key(&self) -> Result<Option<SecretKey>> {
        match self.secrets.secret_key().await? {
            Some(s) if !s.trim().is_empty() => Ok(Some(SecretKey::parse(&s).map_err(|e| Error::Unreadable(e.to_string()))?)),
            _ => Ok(None),
        }
    }

    pub(super) async fn pending_secret_key(&self) -> Result<Option<SecretKey>> {
        match self.secrets.pending_secret_key().await? {
            Some(s) if !s.trim().is_empty() => Ok(Some(SecretKey::parse(&s).map_err(|e| Error::Unreadable(e.to_string()))?)),
            _ => Ok(None),
        }
    }

    /// The secret key to seal a first write with, `secret_key_init` held:
    /// the one held, else the one staged by an earlier attempt, else one
    /// made and staged now when the app allows it ([Error::SecretKeyMissing]
    /// otherwise); `true` while it is not yet this device's.
    pub(super) async fn candidate_locked(&self) -> Result<(SecretKey, bool)> {
        if let Some(existing) = self.secret_key().await? {
            return Ok((existing, false));
        }
        if let Some(staged) = self.pending_secret_key().await? {
            return Ok((staged, true));
        }
        if !self.secrets.allow_auto_generate_secret_key().await? {
            return Err(Error::SecretKeyMissing);
        }
        let candidate = SecretKey::generate();
        self.secrets.set_pending_secret_key(Some(candidate.format().to_string())).await?;
        Ok((candidate, true))
    }

    /// Settles one staged external write for [formatted]. When [stage_id] is
    /// `Some`, removes only that exact stage (ignoring missing or mismatched
    /// stages) while preserving any recovered pre-restart write intent until
    /// that recovered write settles via `None`; when `None`, settles only the
    /// recovered pre-restart intent whose persisted owner matches [account]
    /// (records without an owner are never attributed to a named account).
    async fn settle_external_commit_locked(
        &self,
        init: &mut SecretKeyInitState,
        formatted: &str,
        stage_id: Option<&str>,
        account: Option<&str>,
    ) -> Result<()> {
        self.hydrate_recovered_external_locked(init).await?;
        match stage_id {
            Some(id) => {
                let Some((entry_owner, entry_key)) = init.external_commits.get(id) else {
                    return Ok(());
                };
                if entry_key != formatted || entry_owner.as_deref() != account {
                    return Ok(());
                }
                let recovered = init.recovered_external_commit.as_ref().and_then(Option::as_ref);
                // Persist intent update BEFORE removing `id` from `external_commits`
                // so a transient persistence failure remains retryable with the same `stage_id`.
                self.persist_external_intent_locked(
                    recovered,
                    init.external_commits
                        .iter()
                        .filter(|(k, _)| k.as_str() != id)
                        .map(|(_, (o, c))| (o.as_deref(), c.as_str())),
                )
                .await?;
                init.external_commits.remove(id);
                Ok(())
            }
            None => {
                let Some(Some(cur)) = init.recovered_external_commit.as_ref() else {
                    if init.external_commits.is_empty() {
                        // Clean up any corrupt/unreadable entry when idle.
                        self.clear_external_commit_intent_for(Some(formatted)).await?;
                    }
                    return Ok(());
                };
                if cur.key != formatted {
                    return Ok(());
                }
                let mut next = cur.clone();
                // Every write [account] staged before the restart at once:
                // what its remote shows now resolves each.
                match account {
                    Some(uid) => {
                        if uid.is_empty() || !next.owners.remove(uid) {
                            return Ok(());
                        }
                    }
                    None => {
                        if !next.unowned {
                            return Ok(());
                        }
                        next.unowned = false;
                    }
                }
                let next_opt = (!next.is_empty()).then_some(next);
                self.persist_external_intent_locked(
                    next_opt.as_ref(),
                    init.external_commits
                        .values()
                        .map(|(o, c)| (o.as_deref(), c.as_str())),
                )
                .await?;
                init.recovered_external_commit = Some(next_opt);
                Ok(())
            }
        }
    }

    /// [candidate] as this device's secret key, `secret_key_init` held, now
    /// that a remote holds what it sealed. When [settle_external] is `Some`,
    /// settles the matching external write stage (or crash-recovery durable
    /// intent when `Some((None, account))`), leaving any other unresolved
    /// stages or other accounts' intents intact.
    pub(super) async fn commit_locked(
        &self,
        init: &mut SecretKeyInitState,
        candidate: &SecretKey,
        settle_external: Option<(Option<&str>, Option<&str>)>,
    ) -> Result<()> {
        let formatted = candidate.format().to_string();
        match self.secret_key().await? {
            Some(existing) if existing.format().as_str() == formatted.as_str() => {}
            Some(_) => return Err(Error::Host("another secret key was stored meanwhile".into())),
            None => {
                init.committed_staged = Some(formatted.clone());
                self.secrets.set_secret_key(formatted.clone()).await?;
            }
        }
        init.committed_staged = None;
        if let Some((stage_id, account)) = settle_external {
            self.settle_external_commit_locked(init, &formatted, stage_id, account).await?;
        }
        let _ = self.secrets.set_pending_secret_key(None).await;
        self.bump_recheck_gen();
        Ok(())
    }

}

impl KeyRing {
    /// The secret key currently staged in the pending slot, if any (read only).
    pub async fn pending_secret_key(&self) -> Result<Option<String>> {
        let _init = self.0.secret_key_init.lock().await;
        Ok(self.0.pending_secret_key().await?.map(|k| k.format().to_string()))
    }

    /// The secret key a first remote write outside this ring (LK Cloud's
    /// account key) seals with: the one held, else one staged for it, made
    /// now when the app allows ([Error::SecretKeyMissing] otherwise). Kept
    /// as this device's by [Self::commit_secret_key] once written.
    pub async fn secret_key_candidate(&self) -> Result<String> {
        let _init = self.0.secret_key_init.lock().await;
        Ok(self.0.candidate_locked().await?.0.format().to_string())
    }

    /// [candidate] ([Self::secret_key_candidate]) as this device's secret
    /// key: a remote holds what it sealed.
    pub async fn commit_secret_key(&self, candidate: &str, stage_id: Option<&str>) -> Result<()> {
        self.commit_secret_key_for(candidate, stage_id, None).await
    }

    /// Account-scoped variant of [`Self::commit_secret_key`]: when `stage_id`
    /// is `None`, settles only a crash-recovered intent recorded for [account]
    /// (treating ownerless records as unmatched when [account] is `Some`).
    pub async fn commit_secret_key_for(&self, candidate: &str, stage_id: Option<&str>, account: Option<&str>) -> Result<()> {
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let mut init = self.0.secret_key_init.lock().await;
        self.0.commit_locked(&mut init, &candidate, Some((stage_id, account))).await
    }

    /// Records that an external remote write (such as LK Cloud's account key)
    /// is about to commit using [candidate], returning a unique stage identity
    /// that settles only this write.
    pub async fn stage_external_secret_key_commit(&self, candidate: &str) -> Result<String> {
        self.stage_external_secret_key_commit_for(candidate, None).await
    }

    /// Account-scoped variant of [`Self::stage_external_secret_key_commit`],
    /// persisting [account] alongside the external write intent so crash
    /// recovery never attributes one account's unresolved write to another.
    pub async fn stage_external_secret_key_commit_for(&self, candidate: &str, account: Option<&str>) -> Result<String> {
        if matches!(account, Some(uid) if uid.is_empty()) {
            return Err(Error::Host("external secret key commit account cannot be empty".into()));
        }
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = candidate.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        self.0.hydrate_recovered_external_locked(&mut init).await?;
        if matches!(&init.recovered_external_commit, Some(Some(rec)) if !rec.is_empty() && rec.key != formatted)
            || init.external_commits.values().any(|(_, c)| c != &formatted)
        {
            return Err(Error::Host("another secret key has an unresolved external write intent".into()));
        }
        if let Some(active) = self.0.secret_key().await? {
            if active.format().as_str() != formatted.as_str() {
                return Err(Error::Host("stale secret key candidate does not match active secret key".into()));
            }
        } else {
            let staged = self.0.pending_secret_key().await?;
            if staged.as_ref().is_none_or(|k| k.format().as_str() != formatted.as_str()) {
                return Err(Error::Host("stale secret key candidate does not match staged secret key".into()));
            }
        }
        let recovered = init.recovered_external_commit.as_ref().and_then(Option::as_ref);
        let existing_in_proc = init
            .external_commits
            .values()
            .map(|(o, c)| (o.as_deref(), c.as_str()));
        self.0
            .persist_external_intent_locked(recovered, existing_in_proc.chain(std::iter::once((account, formatted.as_str()))))
            .await?;
        init.next_external_commit_id = init.next_external_commit_id.wrapping_add(1);
        let stage_id = format!("ext-{}", init.next_external_commit_id);
        init.external_commits.insert(stage_id.clone(), (account.map(str::to_string), formatted));
        Ok(stage_id)
    }

    /// Clears the staged external commit identified by [stage_id] (or an
    /// ownerless crash-recovered durable intent when `stage_id` is `None`).
    pub async fn clear_external_secret_key_commit(&self, candidate: &str, stage_id: Option<&str>) -> Result<()> {
        self.clear_external_secret_key_commit_for(candidate, stage_id, None).await
    }

    /// Account-scoped variant of [`Self::clear_external_secret_key_commit`].
    pub async fn clear_external_secret_key_commit_for(&self, candidate: &str, stage_id: Option<&str>, account: Option<&str>) -> Result<()> {
        let candidate = SecretKey::parse(candidate).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = candidate.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        self.0.settle_external_commit_locked(&mut init, &formatted, stage_id, account).await
    }

    /// Imports [key] as this device's secret key, serialized with all remote
    /// key-file staging/write/promotion operations on this [`KeyRing`].
    ///
    /// Rejects a conflicting import when a staged key has already committed to
    /// a remote (either in-flight in this process or recorded durably before
    /// promotion finished), preserving that staged key so recovery can finish.
    pub async fn store_secret_key(&self, key: &str) -> Result<()> {
        let expect_empty_before = self.0.secret_key().await?.is_none();
        self.store_secret_key_with_prior(key, expect_empty_before).await
    }

    /// Like [`Self::store_secret_key`], accepting whether the caller already
    /// observed an empty secret-key slot before acquiring external locks so an
    /// intervening concurrent commit between Dart and Rust cannot be overwritten.
    pub async fn store_secret_key_with_prior(&self, key: &str, expect_empty_before: bool) -> Result<()> {
        let parsed = SecretKey::parse(key).map_err(|e| Error::Unreadable(e.to_string()))?;
        let formatted = parsed.format().to_string();
        let mut init = self.0.secret_key_init.lock().await;
        let existing = self.0.secret_key().await?;
        if expect_empty_before
            && let Some(ref cur) = existing
            && cur.format().as_str() != formatted.as_str()
        {
            return Err(Error::Host("a staged secret key committed while importing".into()));
        }
        if let Some(ref committed) = init.committed_staged
            && committed.as_str() != formatted.as_str()
        {
            return Err(Error::Host("a staged secret key already committed to a remote; refusing conflicting import".into()));
        }
        if init.external_commits.values().any(|(_, c)| c.as_str() != formatted.as_str()) {
            return Err(Error::Host("a staged secret key has an unresolved external write; refusing conflicting import".into()));
        }
        let pending = self.0.secrets.pending().await?;
        let ext_intent_key = external_intent_key(EXTERNAL_COMMIT_ID);
        if let Some(raw) = pending.get(&ext_intent_key) {
            let protected = external_intent_secret_key(raw);
            if protected.as_deref() != Some(formatted.as_str()) {
                return Err(Error::Host("a secret key has an unresolved external write intent; refusing conflicting import".into()));
            }
        }
        let staged = self.0.pending_secret_key().await?;
        let replacing_different_key = existing.as_ref().is_some_and(|k| k.format().as_str() != formatted.as_str())
            || staged.as_ref().is_some_and(|k| k.format().as_str() != formatted.as_str());
        if replacing_different_key {
            if pending.keys().any(|k| k.starts_with(WRITE_INTENT_PREFIX)) {
                return Err(Error::Host("a secret key has an unresolved remote write intent; refusing conflicting import".into()));
            }
            let has_pending_write = {
                let table = self.0.keys.lock().unwrap_or_else(|e| e.into_inner());
                !table.pending_writes.is_empty()
            };
            if has_pending_write {
                return Err(Error::Host("a secret key has a pending remote commit; refusing conflicting import".into()));
            }
        }
        if let Some(ref staged_key) = staged
            && staged_key.format().as_str() != formatted.as_str()
            && existing.is_none()
        {
            let epochs = self.0.secrets.epochs().await?;
            if epochs.keys().any(|k| k.starts_with(TWO_FA_PREFIX)) {
                return Err(Error::Host("a staged secret key has a committed remote write; refusing conflicting import".into()));
            }
        }
        self.0.secrets.import_secret_key(formatted).await?;
        init.committed_staged = None;
        let _ = self.0.secrets.set_pending_secret_key(None).await;
        self.0.bump_recheck_gen();
        Ok(())
    }

}
