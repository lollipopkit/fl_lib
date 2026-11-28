//! Opening the key file with the backup password and recovering an earlier write.

use super::*;

impl SyncKey {
    pub(super) async fn open(&self, pwd: &str, create: bool) -> Result<(SecretKey, Seen)> {
        let id = self.id();
        'open: loop {
            let sk = self.ring.secret_key().await?;
            let tag = cred_tag(pwd, sk.as_ref());
            let file = self.file();
            let observed = Read::of(&*file);
            let Some((body, version)) = file.read().await? else {
                // None to open: put there, unless this `(pwd, sk)` was refused
                // there, so nothing it seals replaces what another device sealed.
                if let Some((refused_tag, was_missing)) = self.lock().refused
                    && refused_tag == tag
                {
                    return Err(if was_missing { Error::SecretKeyMissing } else { Error::PasswordMismatch(id) });
                }
                let epochs = self.ring.secrets.epochs().await?;
                let epoch = epochs.get(&id).copied();
                let held = self.lock().identities.clone();
                let knew = epoch.is_some() && !held.is_empty();
                // A device that opened it before puts back the keys it holds;
                // another makes none where synced data may only be waiting for
                // its key.
                if !create || (!knew && !file.can_create().await?) {
                    // Where a write is ordered, none landed: what was
                    // dispatched past the window is over.
                    if observed.settles.ordered {
                        self.ring.absent_for(&id, self.forget_gen, observed).await?;
                    }
                    return Err(Error::KeyNotHere(id));
                }
                let identities = if held.is_empty() { vec![generate()] } else { held };
                let epoch = epoch.unwrap_or(0);
                let Some((version, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, None, observed.settles).await? else { continue };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, &version, pwd, &sk).await?;
                let seen = observed.seen(epoch, version);
                return Ok((sk, seen));
            };
            if let Some(ref sk) = sk
                && self.lock().opened.as_ref().is_some_and(|(v, t)| v == &version && *t == tag)
            {
                let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                if table.is_current(&id, self) {
                    table.bump_id(&id);
                    self.ring.said_ok(&id);
                }
                let epoch = self.lock().epoch;
                return Ok((sk.clone(), observed.seen(epoch, version)));
            }
            let epochs = self.ring.secrets.epochs().await?;
            let upgraded_2fa = epochs.contains_key(&two_fa_key(&id));
            let verified = epochs.get(&id).copied();
            let staged = if sk.is_none() { self.ring.pending_secret_key().await? } else { None };
            if let Some(ref sk) = sk {
                let derived = sk.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    if let Some(floor) = verified
                        && epoch < floor
                    {
                        self.lock().opened = None;
                        return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
                    }
                    if let Some(seen) = self.take(epoch, identities, version, pwd, sk, observed).await? {
                        return Ok((sk.clone(), seen));
                    }
                    continue;
                }
            } else if let Some(ref staged) = staged {
                // Recover a candidate key whose remote write committed before
                // `set_secret_key` failed or the process exited.
                let derived = staged.combine_passphrase(pwd);
                if let Some((epoch, identities)) = read(&body, &derived)? {
                    if let Some(floor) = verified
                        && epoch < floor
                    {
                        self.lock().opened = None;
                        return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
                    }
                    let use_staged = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        self.ring.ensure_not_forgotten(&id, self.forget_gen)?;
                        init.committed_staged = Some(staged.format().to_string());
                        if let Some(existing) = self.ring.secret_key().await? {
                            if existing.format().as_str() == staged.format().as_str() {
                                init.committed_staged = None;
                                let _ = self.ring.secrets.set_pending_secret_key(None).await;
                                true
                            } else {
                                init.committed_staged = None;
                                false
                            }
                        } else {
                            self.ring.secrets.set_secret_key(staged.format().to_string()).await?;
                            init.committed_staged = None;
                            let _ = self.ring.secrets.set_pending_secret_key(None).await;
                            self.ring.bump_recheck_gen();
                            true
                        }
                    };
                    if !use_staged {
                        continue;
                    }
                    if let Some(seen) = self.take(epoch, identities, version, pwd, staged, observed).await? {
                        return Ok((staged.clone(), seen));
                    }
                    continue;
                }
            }
            // TODO(migration): drop passphrase-only fallback once existing
            // single-factor `identity.age` files have upgraded to SecretKey.
            // Never allow bare-password fallback once this remote has already
            // used 2FA, preventing a weak-password key takeover or replay.
            if !upgraded_2fa
                && let Some((old_epoch, old_identities)) = read(&body, pwd)?
                && verified.is_none_or(|v| old_epoch >= v)
            {
                let identities = self.merged(old_identities);
                let epoch = next_epoch(&id, old_epoch)?;
                let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version), observed.settles).await? else { continue };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, &written, pwd, &sk).await?;
                let seen = observed.seen(epoch, written);
                return Ok((sk, seen));
            }
            self.lock().opened = None;
            let pending_map = self.ring.secrets.pending().await?;
            // First check every durable pre-CAS write intent (only those at the
            // body's epoch can match, and only under the password that sealed
            // it): if one of our earlier remote writes already committed at
            // `intent.epoch` under `intent.pwd` (e.g. `set_epoch_2fa` or
            // `set_pending` failed afterward, or a later attempt followed) and
            // the password changed again since, recover from that committed
            // state instead of treating it as a mismatch.
            for intent in WriteIntent::all_of(&pending_map, &id).into_iter().rev().filter(|i| i.pwd != pwd) {
                if sk.is_none()
                    && let Some(ref staged) = staged
                    && let Some((old_epoch, old_identities)) = read(&body, &staged.combine_passphrase(&intent.pwd))?
                    && old_epoch == intent.epoch
                    && verified.is_none_or(|v| old_epoch >= v)
                {
                    // Persist the confirmed previous commit FIRST before staging
                    // the next write intent, so a CAS miss or network error on
                    // the new write cannot lose `(old_epoch, intent.pwd)`.
                    self.ring.record_committed_write(&id, self.forget_gen, old_epoch, &intent.pwd, self.settles_now(observed.settles)).await?;
                    let identities = self.merged(old_identities);
                    let epoch = next_epoch(&id, old_epoch)?;
                    let (written, persist_err) = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        self.ensure_writable(&id)?;
                        if let Some(existing) = self.ring.secret_key().await?
                            && existing.format().as_str() != staged.format().as_str()
                        {
                            continue 'open;
                        }
                        let sealed = self.sealed(&identities, epoch, pwd, staged)?;
                        let Some((written, persist_err)) = self.commit_key_file_with_intent(sealed, Some(version), epoch, pwd).await? else {
                            continue 'open;
                        };
                        init.committed_staged = Some(staged.format().to_string());
                        if let Err(e) = self.ring.record_committed_write(&id, self.forget_gen, epoch, pwd, self.settles_now(observed.settles)).await {
                            init.committed_staged = None;
                            return Err(e);
                        }
                        self.ring.commit_locked(&mut init, staged, None).await?;
                        (written, persist_err)
                    };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, &written, pwd, staged).await?;
                    let seen = observed.seen(epoch, written);
                    return Ok((staged.clone(), seen));
                }
                if let Some(ref k) = sk
                    && let Some((old_epoch, old_identities)) = read(&body, &k.combine_passphrase(&intent.pwd))?
                    && old_epoch == intent.epoch
                    && verified.is_none_or(|v| old_epoch >= v)
                {
                    // Persist the confirmed previous commit FIRST before staging
                    // the next write intent, so a CAS miss or network error on
                    // the new write cannot lose `(old_epoch, intent.pwd)`.
                    self.ring.record_committed_write(&id, self.forget_gen, old_epoch, &intent.pwd, self.settles_now(observed.settles)).await?;
                    let identities = self.merged(old_identities);
                    let epoch = next_epoch(&id, old_epoch)?;
                    let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version), observed.settles).await? else { continue 'open };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, &written, pwd, &sk).await?;
                    let seen = observed.seen(epoch, written);
                    return Ok((sk, seen));
                }
            }
            if let Some(previous) = pending_map.get(&id).cloned()
                && previous != pwd
            {
                // Recover a staged key sealed under the previous password (even
                // when `upgraded_2fa` is already set) without generating a new key.
                if sk.is_none()
                    && let Some(ref staged) = staged
                    && let Some((old_epoch, old_identities)) = read(&body, &staged.combine_passphrase(&previous))?
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    let identities = self.merged(old_identities);
                    let epoch = next_epoch(&id, old_epoch)?;
                    let (written, persist_err) = {
                        let mut init = self.ring.secret_key_init.lock().await;
                        self.ensure_writable(&id)?;
                        if let Some(existing) = self.ring.secret_key().await?
                            && existing.format().as_str() != staged.format().as_str()
                        {
                            continue;
                        }
                        let sealed = self.sealed(&identities, epoch, pwd, staged)?;
                        let Some((written, persist_err)) = self.commit_key_file_with_intent(sealed, Some(version), epoch, pwd).await? else {
                            continue;
                        };
                        init.committed_staged = Some(staged.format().to_string());
                        // The remote file is now committed under `(pwd, staged)`
                        // at `epoch`: persist the epoch and reconcile `pending`
                        // BEFORE `set_secret_key` so a later or concurrent
                        // `password_changed` matches `pwd` instead of keeping
                        // stale `previous`.
                        if let Err(e) = self.ring.record_committed_write(&id, self.forget_gen, epoch, pwd, self.settles_now(observed.settles)).await {
                            init.committed_staged = None;
                            return Err(e);
                        }
                        self.ring.commit_locked(&mut init, staged, None).await?;
                        (written, persist_err)
                    };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, &written, pwd, staged).await?;
                    let seen = observed.seen(epoch, written);
                    return Ok((staged.clone(), seen));
                }
                let old = match &sk {
                    Some(k) => match read(&body, &k.combine_passphrase(&previous))? {
                        Some(found) => Some(found),
                        // TODO(migration): fallback for legacy passphrase-only key files.
                        None if !upgraded_2fa => read(&body, &previous)?,
                        None => None,
                    },
                    None if !upgraded_2fa => read(&body, &previous)?,
                    None => None,
                };
                // Not if another device sealed it since this one last opened
                // it: that one's password is the remote's now.
                if let Some((old_epoch, old_identities)) = old
                    && verified.is_none_or(|v| v == old_epoch)
                {
                    let identities = self.merged(old_identities);
                    let epoch = next_epoch(&id, old_epoch)?;
                    let Some((written, sk, persist_err)) = self.write_with_secret_key(&identities, epoch, pwd, Some(version), observed.settles).await? else { continue };
                    self.use_identities(identities, true).await?;
                    if let Some(detail) = persist_err {
                        return Err(Error::Host(detail));
                    }
                    self.opened_at(epoch, &written, pwd, &sk).await?;
                    let seen = observed.seen(epoch, written);
                    return Ok((sk, seen));
                }
                // Keep `pending` when `sk` is missing so importing the secret
                // key later can still finish sealing the password change.
            }
            if sk.is_some() {
                // No intent opens the file [observed]: those past the window never
                // took effect there.
                self.ring.refused_password_for(&id, self.forget_gen, observed).await?;
            }
            if sk.is_none() && self.ring.secret_key().await?.is_some() {
                // Another remote or caller stored an active secret key while we
                // checked; retry immediately so the body can be opened with it.
                continue;
            }
            let missing_sk = sk.is_none();
            self.lock().refused = Some((tag, missing_sk));
            {
                let table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
                if table.is_current(&id, self) {
                    if missing_sk {
                        self.ring.said_missing(&id);
                    } else {
                        self.ring.said_mismatch(&id);
                    }
                }
            }
            if missing_sk {
                return Err(Error::SecretKeyMissing);
            }
            return Err(Error::PasswordMismatch(id));
        }
    }

    /// The keys the file holds taken, at [version]. One that lacks the key
    /// this device seals with (put there by a device that made its own at the
    /// same time, on a store that does not order writes) is written again
    /// with it, so the other devices read what it sealed; false when the file
    /// changed meanwhile.
    pub(super) async fn take(&self, epoch: i64, remote: Vec<String>, version: String, pwd: &str, sk: &SecretKey, observed: Read) -> Result<Option<Seen>> {
        let current = self.lock().identities.first().cloned();
        match current {
            Some(current) if !remote.contains(&current) => {
                // The file's newest stays first: every device then seals with it.
                let mut order = vec![remote[0].clone(), current];
                order.extend(remote.iter().skip(1).cloned());
                let identities = self.merged(order);
                #[cfg(test)]
                {
                    let hook = self.before_take_merge.lock().unwrap_or_else(|e| e.into_inner()).take();
                    if let Some(h) = hook {
                        h().await;
                    }
                }
                let (written, persist_err) = {
                    let _init = self.ring.secret_key_init.lock().await;
                    self.ensure_writable(&self.id())?;
                    let cur_sk = self.ring.secret_key().await?;
                    if cur_sk.as_ref().map(|k| k.format()) != Some(sk.format()) {
                        return Ok(None);
                    }
                    let Some(res) = self.commit_key_file(self.sealed(&identities, epoch, pwd, sk)?, Some(version)).await? else {
                        return Ok(None);
                    };
                    res
                };
                self.use_identities(identities, true).await?;
                if let Some(detail) = persist_err {
                    self.ring.record_committed_write(&self.id(), self.forget_gen, epoch, pwd, self.settles_now(observed.settles)).await?;
                    return Err(Error::Host(detail));
                }
                self.opened_at(epoch, &written, pwd, sk).await?;
                Ok(Some(observed.seen(epoch, written)))
            }
            _ => {
                self.use_identities(self.merged(remote), true).await?;
                self.opened_at(epoch, &version, pwd, sk).await?;
                Ok(Some(observed.seen(epoch, version)))
            }
        }
    }

    pub(super) async fn opened_at(&self, epoch: i64, version: &str, pwd: &str, sk: &SecretKey) -> Result<()> {
        let id = self.id();
        let tag = cred_tag(pwd, Some(sk));
        // Persist the 2FA epoch and marker BEFORE caching `s.opened`, so a
        // metadata persistence failure leaves the opening state uncached and
        // retryable.
        if let Err(e) = self.ring.set_epoch_2fa(&id, self.forget_gen, epoch).await {
            self.lock().opened = None;
            return Err(e);
        }
        // A settlement in progress checks `opened` under this lock: it is not
        // replaced by a newer open midway.
        let _settling = self.ring.pending_lock.lock().await;
        {
            let mut table = self.ring.keys.lock().unwrap_or_else(|e| e.into_inner());
            let mut s = self.lock();
            s.epoch = epoch;
            s.opened = Some((version.to_string(), tag));
            s.refused = None;
            drop(s);
            if table.is_current(&id, self) {
                table.bump_id(&id);
                self.ring.said_ok(&id);
            }
        }
        Ok(())
    }

}
