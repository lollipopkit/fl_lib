//! Checking what homebase answers against the watermarks and signatures.

use super::*;

impl PersonalAuth {
    /// Verifies a downloaded file's signature and monotonic version.
    ///
    /// When `enforce_monotonic` is false (explicitly fetching an older version
    /// from history via `download_version`), the signature is still verified
    /// against this account's own key history and recorded as signed without
    /// failing on an older version number or moving the current highest.
    pub async fn verify_file(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        self.verify_file_digest(app, name, &digest(body), signed, enforce_monotonic).await
    }

    /// Verifies a downloaded write-once log blob's signature without recording
    /// a per-file version watermark.
    pub async fn verify_blob(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>) -> Result<(), Error> {
        self.verify_blob_digest(app, name, &digest(body), signed).await
    }

    /// Verifies a downloaded write-once log blob bound to a pre-signing
    /// reference retained by a batch or snapshot: permits an unsigned response
    /// only when [name] has never been seen or written signed (whatever
    /// [app]'s `signed_apps` / `signed_blobs` policy) and its bytes hold
    /// [binding].
    pub async fn verify_retained_blob(&self, app: &str, name: &str, body: &[u8], signed: Option<&Signed>, binding: RetainedBinding<'_>) -> Result<(), Error> {
        self.verify_blob_digest_inner(app, name, &digest(body), signed, Some((binding, body))).await
    }

    /// Streaming variant of [`Self::verify_blob`] taking a precomputed blake3 digest.
    pub async fn verify_blob_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>) -> Result<(), Error> {
        self.verify_blob_digest_inner(app, name, body_digest, signed, None).await
    }

    /// [retained]: the binding and bytes of a retained answer; `None` on the
    /// strict path.
    async fn verify_blob_digest_inner(
        &self,
        app: &str,
        name: &str,
        body_digest: &[u8; KEY_LEN],
        signed: Option<&Signed>,
        retained: Option<(RetainedBinding<'_>, &[u8])>,
    ) -> Result<(), Error> {
        let key = file_key(app, name);
        let Some(s) = signed else {
            // TODO(migration): reject unsigned personal blobs unconditionally
            // once pre-signing uploads are no longer present.
            // A retained answer is bound to the digest a verified container
            // gives (signed, or an unsigned one accepted below the signing
            // floor) or to the caller's own content, so only a name seen signed
            // refuses it; `signed_apps` must not strand pre-signing blobs
            // before they are migrated.
            let refuses = |held: &VersionState| {
                held.seen_signed_blobs.contains(&key)
                    || held.data.files.contains_key(&key)
                    || (retained.is_none() && held.data.blob_requires_signature(app))
            };
            let stripped = || untrusted(format!("{app}/{name}: server stripped signature"));
            let mut held = self.versions.lock().await;
            if refuses(&held) {
                return Err(stripped());
            }
            if let Some((binding, body)) = retained {
                // Checked unlocked: a content binding opens and parses the bytes.
                drop(held);
                if !binding.holds(body) {
                    return Err(untrusted(format!("{app}/{name}: {RETAINED_MISMATCH}")));
                }
                held = self.versions.lock().await;
                // Seen signed meanwhile.
                if refuses(&held) {
                    return Err(stripped());
                }
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let version = s.version.ok_or_else(|| untrusted(format!("{app}/{name}: signed file missing version")))?;
        if version <= 0 {
            return Err(untrusted(format!("{app}/{name}: invalid version {version}")));
        }
        let owner = self.verify_own_key(s, &format!("{app}/{name}")).await?;
        let msg = crypto::sync_file_message(&owner, app, name, 0, version, body_digest);
        verify_sig(s, &msg, &format!("{app}/{name}"))?;
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        next.saw_blob(app);
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        held.seen_signed_blobs.insert(key);
        Ok(())
    }

    /// Streaming variant of [`Self::verify_file`] taking a precomputed blake3 digest.
    pub async fn verify_file_digest(&self, app: &str, name: &str, body_digest: &[u8; KEY_LEN], signed: Option<&Signed>, enforce_monotonic: bool) -> Result<(), Error> {
        let Some(s) = signed else {
            // Checked under the versions lock against concurrent signed
            // writes and reads.
            // TODO(migration): reject unsigned personal files unconditionally
            // once pre-signing uploads are no longer present.
            let mut held = self.versions.lock().await;
            if held.data.requires_signature(app, Some(name)) {
                let seen = held.data.file_version(app, name);
                return Err(untrusted(format!("{app}/{name}: server stripped signature (expected version >= {seen})")));
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let version = s.version.ok_or_else(|| untrusted(format!("{app}/{name}: signed file missing version")))?;
        if version <= 0 {
            return Err(untrusted(format!("{app}/{name}: invalid version {version}")));
        }
        let owner = self.verify_own_key(s, &format!("{app}/{name}")).await?;
        let msg = crypto::sync_file_message(&owner, app, name, 0, version, body_digest);
        verify_sig(s, &msg, &format!("{app}/{name}"))?;
        self.persist_checked(|v| {
            if !enforce_monotonic {
                v.saw_file(app, name, 0);
                return Ok(());
            }
            let seen = v.file_version(app, name);
            if version < seen {
                return Err(untrusted(format!("{app}/{name}: version rollback ({version} < {seen})")));
            }
            v.saw_file(app, name, version);
            Ok(())
        })
        .await
    }

    /// Verifies a page of log batches and persists the log's signing marker
    /// in a single [`VersionKeeper::save`] call.
    pub async fn verify_batches(&self, app: &str, log: Option<&str>, batches: &[Batch]) -> Result<(), Error> {
        let mut first_signed: Option<i64> = None;
        let mut unsigned: Vec<i64> = Vec::new();
        for batch in batches {
            let what = format!("{app}/log batch {}", batch.seq);
            let Some(s) = batch.signed.as_ref() else {
                unsigned.push(batch.seq);
                continue;
            };
            let idem = batch.idempotency_key.as_deref().ok_or_else(|| untrusted(format!("{what}: missing idempotency key")))?;
            let owner = self.verify_own_key(s, &what).await?;
            let msg = crypto::sync_batch_message(&owner, app, 0, &digest(&batch.body), idem);
            verify_sig(s, &msg, &what)?;
            first_signed = Some(first_signed.map_or(batch.seq, |f| f.min(batch.seq)));
        }
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        if let Some(seq) = first_signed {
            next.mark_log_signed_at(app, log, seq);
        }
        if let Some(seq) = unsigned.iter().find(|&&seq| next.log_requires_signature(app, log, seq)) {
            return Err(untrusted(format!("{app}/log batch {seq}: server stripped signature")));
        }
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        if first_signed.is_some()
            && let Some(l) = log
        {
            held.recorded_log_ids.insert(app.to_string(), l.to_string());
        }
        Ok(())
    }

    /// Verifies a log snapshot's signature.
    pub async fn verify_snapshot(&self, app: &str, snapshot: &Snapshot, body: &[u8]) -> Result<(), Error> {
        self.verify_snapshot_digest(app, snapshot, &digest(body)).await
    }

    /// Verifies a signed snapshot's cryptographic signature without advancing
    /// persisted state; rejects unsigned snapshots.
    pub async fn verify_snapshot_signature_only(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let s = snapshot.signed.as_ref().ok_or_else(|| untrusted(format!("{what}: server stripped signature")))?;
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_snapshot_message(&owner, app, 0, snapshot.seq, body_digest);
        verify_sig(s, &msg, &what)
    }

    /// Verifies a signed snapshot for detached recovery and records its log
    /// binding unless a different log was recorded under this
    /// [`PersonalAuth`] instance or [observer] saw one, also while the binding
    /// is saved. Returns `false` in that case, recording only
    /// `signed_snapshots[app]`.
    pub async fn verify_snapshot_digest_for_detached(
        &self,
        app: &str,
        snapshot: &Snapshot,
        body_digest: &[u8; KEY_LEN],
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        self.verify_snapshot_signature_only(app, snapshot, body_digest).await?;
        let mut held = self.versions.lock().await;
        let superseded = held.recorded_log_ids.get(app).is_some_and(|existing| existing != &snapshot.log);
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, Some(&snapshot.log), snapshot.seq, superseded, observer).await
    }

    /// [`Self::verify_snapshot_digest`] ordered against [observer]: a signed
    /// snapshot on a log other than the one observed, or than the one this
    /// instance recorded while not the one observed, is refused (`Ok(false)`)
    /// before it changes the signing binding or floor; its signed-snapshot
    /// marker is recorded either way.
    pub async fn verify_snapshot_digest_observed(
        &self,
        app: &str,
        snapshot: &Snapshot,
        body_digest: &[u8; KEY_LEN],
        observer: &impl LogObserver,
    ) -> Result<bool, Error> {
        if snapshot.signed.is_none() {
            return self.verify_snapshot_digest(app, snapshot, body_digest).await.map(|()| true);
        }
        self.verify_snapshot_signature_only(app, snapshot, body_digest).await?;
        let mut held = self.versions.lock().await;
        // A log observed live since takes the place of the one recorded.
        let superseded = held.recorded_log_ids.get(app).is_some_and(|known| known != &snapshot.log) && !observer.confirm(&snapshot.log)?;
        Self::record_snapshot_ordered(&self.keeper, &mut held, app, Some(&snapshot.log), snapshot.seq, superseded, observer).await
    }

    /// Streaming variant of [`Self::verify_snapshot`] taking a precomputed blake3 digest.
    pub async fn verify_snapshot_digest(&self, app: &str, snapshot: &Snapshot, body_digest: &[u8; KEY_LEN]) -> Result<(), Error> {
        let what = format!("{app}/snapshot seq {}", snapshot.seq);
        let Some(s) = snapshot.signed.as_ref() else {
            // TODO(migration): reject unsigned personal snapshots
            // unconditionally once pre-signing snapshots are replaced.
            let mut held = self.versions.lock().await;
            if held.data.snapshot_requires_signature(app, &snapshot.log, snapshot.seq) {
                return Err(untrusted(format!("{what}: server stripped signature")));
            }
            return Self::flush(&self.keeper, &mut held).await;
        };
        let owner = self.verify_own_key(s, &what).await?;
        let msg = crypto::sync_snapshot_message(&owner, app, 0, snapshot.seq, body_digest);
        verify_sig(s, &msg, &what)?;
        let mut held = self.versions.lock().await;
        let mut next = held.data.clone();
        next.saw_snapshot(app, Some(&snapshot.log), snapshot.seq);
        if next != held.data || held.dirty {
            self.keeper.save(next.to_json()).await.map_err(not_saved)?;
            held.data = next;
            held.dirty = false;
        }
        held.recorded_log_ids.insert(app.to_string(), snapshot.log.clone());
        Ok(())
    }
}

fn verify_sig(s: &Signed, msg: &[u8], what: &str) -> Result<(), Error> {
    let pk = BASE64.decode(&s.signing_key).map_err(|_| untrusted(format!("{what}: signing key not base64")))?;
    let sig = BASE64.decode(&s.signature).map_err(|_| untrusted(format!("{what}: signature not base64")))?;
    crypto::verify(&pk, msg, &sig, "a personal sync write").map_err(|e| untrusted(format!("{what}: {e}")))
}
