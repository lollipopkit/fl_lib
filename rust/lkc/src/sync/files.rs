//! An app's files: reads, conditional writes, deletes and listings.

use super::*;

impl<S: Store> SyncClient<S> {
    /// [name]'s version, `None` when there is no such file.
    pub async fn head(&self, name: &str) -> Result<Option<String>, Error> {
        let response = self.send(Method::HEAD, &self.file_path(name)?, |r| r).await?;
        match response.status() {
            StatusCode::OK => match self.etag(&response) {
                Some(etag) => Ok(Some(etag)),
                None => Err(self.without_version().await),
            },
            StatusCode::NOT_FOUND => Ok(None),
            _ => Err(refusal(response).await),
        }
    }

    /// [name] written to [to], unless its version is [known].
    pub async fn download(&self, name: &str, to: &Path, known: Option<&str>) -> Result<Fetched, Error> {
        self.fetch_file(&self.file_path(name)?, name, to, known, true).await
    }

    /// [name]'s bytes, version and its writer's signature (when signed);
    /// `None` when there is no such file.
    pub async fn download_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        self.download_bytes_inner(name, DownloadVerify::File).await.0
    }

    /// Write-once log blob variant of [`Self::download_bytes`]: verifies the
    /// signature without recording a per-file version watermark.
    pub async fn download_blob_bytes(&self, name: &str) -> Result<Option<(Vec<u8>, String, Option<Signed>)>, Error> {
        self.download_bytes_inner(name, DownloadVerify::BlobStrict).await.0
    }

    /// Like [`Self::download_blob_bytes`], also returning whether personal auth
    /// was attached and verified this download.
    pub async fn download_blob_bytes_checked(&self, name: &str) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        self.download_bytes_inner(name, DownloadVerify::BlobStrict).await
    }

    /// Like [`Self::download_blob_bytes_checked`] for a blob bound to a
    /// pre-signing reference retained by a batch or snapshot: allows an
    /// unsigned response only when [name] was never previously seen or written
    /// signed and its bytes hold [binding].
    pub async fn download_retained_blob_bytes_checked(&self, name: &str, binding: RetainedBinding<'_>) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        self.download_bytes_inner(name, DownloadVerify::BlobRetained(binding)).await
    }

    async fn download_bytes_inner(&self, name: &str, verify: DownloadVerify<'_>) -> (Result<Option<(Vec<u8>, String, Option<Signed>)>, Error>, bool) {
        let auth = self.personal_auth_with_gen();
        let has_auth = auth.is_some();
        let res = async {
            let mut body = Vec::new();
            let mut signed = None;
            match self.fetch_with(&self.file_path(name)?, Target::Memory(&mut body), None, |r| signed = Signed::of(r)).await? {
                Fetched::Saved(etag) => {
                    if let Some((auth_gen, auth)) = auth {
                        self.ensure_personal_gen(auth_gen)?;
                        match verify {
                            DownloadVerify::File => auth.verify_file(&self.app, name, &body, signed.as_ref(), true).await?,
                            DownloadVerify::BlobStrict => auth.verify_blob(&self.app, name, &body, signed.as_ref()).await?,
                            DownloadVerify::BlobRetained(binding) => auth.verify_retained_blob(&self.app, name, &body, signed.as_ref(), binding).await?,
                        }
                        self.ensure_personal_gen(auth_gen)?;
                    } else if let DownloadVerify::BlobRetained(binding) = verify
                        && !binding.holds(&body)
                    {
                        // Unverified, so whatever it carries is unsigned.
                        return Err(Error::new(Kind::Untrusted, format!("{}/{name}: {RETAINED_MISMATCH}", self.app)));
                    }
                    Ok(Some((body, etag, signed)))
                }
                Fetched::Missing => {
                    if let Some((auth_gen, _)) = auth {
                        self.ensure_personal_gen(auth_gen)?;
                    }
                    Ok(None)
                }
                Fetched::Unchanged => Err(Error::new(Kind::Invalid, "a file answered 304")),
            }
        }
        .await;
        (res, has_auth)
    }

    /// A kept version of [name] ([`SyncClient::versions`]) written to [to].
    pub async fn download_version(&self, name: &str, etag: &str, to: &Path) -> Result<Fetched, Error> {
        if !etag.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::new(Kind::Invalid, "not a version"));
        }
        self.fetch_file(&format!("{}/versions/{etag}", self.file_path(name)?), name, to, None, false).await
    }

    /// [from] as [name]'s new version, if [condition] still holds. Answers the
    /// new version.
    pub async fn upload(&self, name: &str, from: &Path, condition: Condition) -> Result<String, Error> {
        self.upload_bytes(name, read_file(from).await?, condition).await
    }

    /// [body] as [name]'s new version, if [condition] still holds.
    /// When personal signing is attached, signs the write and advances the
    /// monotonic file version automatically.
    pub async fn upload_bytes(&self, name: &str, body: Vec<u8>, condition: Condition) -> Result<String, Error> {
        self.upload_bytes_inner(name, body, condition, false).await.0
    }

    /// Write-once log blob upload (`Condition::Absent`): signs the write when
    /// personal signing is attached, and records blob signing without adding a
    /// per-file version watermark.
    pub async fn upload_blob_bytes(&self, name: &str, body: Vec<u8>) -> Result<String, Error> {
        self.upload_bytes_inner(name, body, Condition::Absent, true).await.0
    }

    /// Like [`Self::upload_blob_bytes`], also returning whether personal
    /// signing was attached for this upload attempt.
    pub async fn upload_blob_bytes_checked(&self, name: &str, body: Vec<u8>) -> (Result<String, Error>, bool) {
        self.upload_bytes_inner(name, body, Condition::Absent, true).await
    }

    async fn upload_bytes_inner(&self, name: &str, body: Vec<u8>, condition: Condition, write_once_blob: bool) -> (Result<String, Error>, bool) {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return (self.upload_signed(name, body, condition, None).await, false);
        };
        let res = async {
            let body = bytes::Bytes::from(body);
            let mode = if write_once_blob { UploadMode::Blob } else { UploadMode::File };
            let commit_key = (name.to_string(), condition.clone(), *blake3::hash(&body).as_bytes(), mode);
            let mut expected_id = {
                let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                (guard.generation == auth_gen)
                    .then(|| guard.files.get(&commit_key).map(|(id, _, _)| *id))
                    .flatten()
            };
            if expected_id.is_some() {
                for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                    let Some(entry_id) = expected_id else { break };
                    let flushed = auth.flush_pending_versions().await;
                    let lock = self.file_lock(name);
                    let _file_guard = lock.lock().await;
                    match flushed {
                        Ok(()) => {
                            enum CacheCheck {
                                Hit(String),
                                Replaced(u64),
                                Gone,
                            }
                            let check = {
                                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                if slot.generation == auth_gen {
                                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                    if guard.generation == auth_gen {
                                        match guard.files.get(&commit_key) {
                                            Some((cur_id, _, _)) if *cur_id == entry_id => {
                                                let (_, etag, _) = guard.files.remove(&commit_key).expect("entry present");
                                                CacheCheck::Hit(etag)
                                            }
                                            Some((cur_id, _, _)) => CacheCheck::Replaced(*cur_id),
                                            None => CacheCheck::Gone,
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
                                        let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                        (guard.generation == auth_gen)
                                            .then(|| {
                                                guard.files.get(&commit_key).and_then(|(cur_id, etag, version)| {
                                                    (*cur_id == entry_id).then(|| (etag.clone(), *version))
                                                })
                                            })
                                            .flatten()
                                    } else {
                                        None
                                    }
                                };
                                if let Some((etag, version)) = still_valid {
                                    return Err(e.with_committed(Committed::File { etag, version }));
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
            auth.ensure_published(&self.session, false).await?;
            self.ensure_personal_gen(auth_gen)?;
            let mut version = if write_once_blob { 1 } else { auth.next_file_version(&self.app, name).await? };
            let mut republished = false;
            let mut version_retried = false;
            loop {
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_file(&self.app, name, version, &body).await;
                match self.upload_signed_bytes(name, body.clone(), condition.clone(), Some(&sig), auth_gen, true).await {
                    Ok((etag, recovery)) => {
                        let recorded = if write_once_blob {
                            auth.record_named_blob_written(&self.app, name).await
                        } else {
                            auth.record_file_version(&self.app, name, version).await
                        };
                        if let Err(e) = recorded {
                            if e.kind == Kind::Invalid {
                                if let Some(ref token) = recovery {
                                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                                    if slot.generation == auth_gen {
                                        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                        if guard.generation == auth_gen
                                            && guard.file_mutations.get(name).map(|m| m.seq) == Some(token.seq)
                                        {
                                            let id = guard.next_id();
                                            guard.files.insert(commit_key, (id, etag.clone(), version));
                                        }
                                    }
                                }
                                return Err(e.with_committed(Committed::File { etag, version }));
                            }
                            return Err(e);
                        }
                        if !write_once_blob {
                            self.note_verified(auth_gen, name, &etag, version);
                        }
                        return Ok(etag);
                    }
                    Err(e) if !version_retried && matches!(e.kind, Kind::Version(_)) => {
                        let Kind::Version(highest) = e.kind else { unreachable!() };
                        if highest < version {
                            return Err(Error::new(Kind::Untrusted, format!("server sync_version {highest} is below attempted {version}")));
                        }
                        version = highest.checked_add(1).ok_or_else(|| Error::new(Kind::Untrusted, "server sync_version overflow"))?;
                        version_retried = true;
                    }
                    Err(e) if !republished && matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                        self.ensure_personal_gen(auth_gen)?;
                        auth.ensure_published(&self.session, true).await?;
                        republished = true;
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        .await;
        (res, true)
    }

    /// [upload_bytes], signed by its writer ([sig]): a team's every write is.
    pub async fn upload_signed(&self, name: &str, body: Vec<u8>, condition: Condition, sig: Option<&WriteSig>) -> Result<String, Error> {
        let start_gen = self.personal_generation();
        self.upload_signed_bytes(name, bytes::Bytes::from(body), condition, sig, start_gen, false).await.map(|(etag, _)| etag)
    }

    pub(super) async fn upload_signed_bytes(
        &self,
        name: &str,
        bytes: bytes::Bytes,
        condition: Condition,
        sig: Option<&WriteSig>,
        expected_gen: u64,
        track_recovery: bool,
    ) -> Result<(String, Option<FileRecoveryToken<'_>>), Error> {
        let path = self.file_path(name)?;
        let size = bytes.len() as u64;
        if size > MAX_BYTES {
            return Err(Error::new(Kind::TooLarge, format!("{size} bytes")));
        }
        let start_session = self
            .session
            .identity()
            .ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?;
        let (start_gen, start_personal_attached) = if track_recovery {
            (expected_gen, true)
        } else {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            (slot.generation, slot.auth.is_some())
        };
        #[cfg(test)]
        if let Some(notify) = self.before_file_lock.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            notify.notify_one();
        }
        let lock = self.file_lock(name);
        let _file_guard = lock.lock().await;
        if self.session.identity() != Some(start_session) {
            return Err(Error::new(Kind::SignedOut, "session changed before upload"));
        }
        let (active_gen, active_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if start_personal_attached && (slot.generation != start_gen || slot.auth.is_none()) {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed before upload"));
            }
            (slot.generation, slot.auth.is_some())
        };
        let bound = Some((start_session, active_gen, active_personal_attached));
        let etag = if size <= DIRECT_MAX {
            let response = self
                .send_for(bound, Method::PUT, &path, |r| {
                    signed_by(condition_on(r, &condition), sig)
                        .header(header::CONTENT_TYPE, "application/octet-stream")
                        .header(header::CONTENT_LENGTH, size)
                        .body(bytes.clone())
                })
                .await?;
            self.written_version_for(Some(start_session), response).await?
        } else {
            let response = self
                .send_for(bound, Method::POST, &format!("{path}/uploads"), |r| {
                    signed_by(condition_on(r, &condition), sig).json(&serde_json::json!({ "size": size }))
                })
                .await?;
            let begun: Begun = self.json_for(Some(start_session), response, MAX_JSON).await?;
            if self.session.identity() != Some(start_session)
                || (active_personal_attached && self.personal_generation() != active_gen)
            {
                return Err(Error::new(Kind::SignedOut, "session changed during multipart upload"));
            }
            self.store_upload(&begun.url, bytes).await?;
            self.complete_for(bound, &path, &begun.id).await?
        };
        let recovery = if self.session.identity() == Some(start_session) {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if slot.generation == active_gen {
                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                let token = if guard.generation == active_gen {
                    guard.files.retain(|(file_name, _, _, _), _| file_name != name);
                    if track_recovery {
                        guard.next_mutation_seq = guard.next_mutation_seq.wrapping_add(1);
                        let seq = guard.next_mutation_seq;
                        let entry = guard.file_mutations.entry(name.to_string()).or_insert(FileMutationTracker { seq: 0, active: 0 });
                        entry.seq = seq;
                        entry.active += 1;
                        Some(FileRecoveryToken { pending: &self.pending_commits, name: name.to_string(), auth_gen: active_gen, seq })
                    } else {
                        guard.bump_if_tracked(name);
                        None
                    }
                } else {
                    None
                };
                drop(guard);
                self.written.lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), etag.clone());
                token
            } else {
                None
            }
        } else {
            None
        };
        Ok((etag, recovery))
    }

    /// [bytes] to an upload's presigned [url]: the store's own address, so no
    /// token goes there.
    pub(super) async fn store_upload(&self, url: &str, bytes: bytes::Bytes) -> Result<(), Error> {
        let put = self
            .session
            .client()
            .transfer()
            .put(url)
            .header(header::CONTENT_LENGTH, bytes.len())
            .body(bytes)
            .send()
            .await
            .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
        if !put.status().is_success() {
            return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", put.status())));
        }
        Ok(())
    }

    /// Records an upload, asked again while the store has not seen it.
    /// Completing twice is answered alike, so a completion whose answer was
    /// lost is simply asked again.
    async fn complete_for(&self, bound: Option<(u64, u64, bool)>, path: &str, id: &str) -> Result<String, Error> {
        self.complete_with_log_for(bound, path, id).await.map(|(etag, _)| etag)
    }

    pub(super) async fn complete_with_log_for(&self, bound: Option<(u64, u64, bool)>, path: &str, id: &str) -> Result<(String, Option<String>), Error> {
        let mut wait = Duration::from_millis(500);
        for _ in 0..COMPLETE_TRIES {
            let response = self.send_for(bound, Method::POST, &format!("{path}/uploads/{id}/complete"), |r| r).await?;
            // A bare `409` is the store not showing the upload yet; one with a
            // reason (a snapshot gone stale) is a refusal.
            if response.status() == StatusCode::CONFLICT {
                if let Some(current) = stale_epoch(&response, self.epoch()) {
                    return Err(Error::new(Kind::StaleEpoch(current), "HTTP 409 team_epoch_stale"));
                }
                let highest_version = response.headers().get("x-sync-version").and_then(|v| v.to_str().ok()).and_then(|s| s.parse::<i64>().ok());
                let body = read_limited(response, MAX_JSON).await?;
                if let Some(reason) = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["reason"].as_str().map(str::to_string)) {
                    if reason == "sync_version"
                        && let Some(highest) = highest_version
                    {
                        return Err(Error::new(Kind::Version(highest), format!("HTTP 409 sync_version {highest}")));
                    }
                    return Err(Error::new(Kind::Refused(reason.clone()), format!("HTTP 409 {reason}")));
                }
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(Duration::from_secs(8));
                continue;
            }
            let sync_log = answered_log(header_non_empty(&response, "sync-log"))?;
            return self.written_version_for(bound.map(|(s, _, _)| s), response).await.map(|etag| (etag, sync_log));
        }
        Err(Error::new(Kind::Unreachable, "the store never showed the upload"))
    }

    /// Removes [name], if [if_match] (when given) is its version. `false`
    /// when there was no such file.
    pub async fn delete(&self, name: &str, if_match: Option<&str>) -> Result<bool, Error> {
        let path = self.file_path(name)?;
        let start_session = self
            .session
            .identity()
            .ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?;
        let (start_gen, start_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            (slot.generation, slot.auth.is_some())
        };
        #[cfg(test)]
        if let Some(notify) = self.before_file_lock.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            notify.notify_one();
        }
        let lock = self.file_lock(name);
        let _file_guard = lock.lock().await;
        if self.session.identity() != Some(start_session) {
            return Err(Error::new(Kind::SignedOut, "session changed before delete"));
        }
        let (active_gen, active_personal_attached) = {
            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
            if start_personal_attached && slot.generation != start_gen {
                return Err(Error::new(Kind::SignedOut, "personal signing auth changed before delete"));
            }
            (slot.generation, slot.auth.is_some())
        };
        let response = self
            .send_for(
                Some((start_session, active_gen, active_personal_attached)),
                Method::DELETE,
                &path,
                |r| match if_match {
                    Some(etag) => r.header(header::IF_MATCH, quote(etag)),
                    None => r,
                },
            )
            .await?;
        match response.status() {
            StatusCode::NO_CONTENT | StatusCode::NOT_FOUND => {
                if self.session.identity() == Some(start_session) {
                    let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                    if slot.generation == active_gen {
                        let mut pending = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                        if pending.generation == active_gen {
                            pending.files.retain(|(file_name, _, _, _), _| file_name != name);
                            pending.verified_files.remove(name);
                            pending.bump_if_tracked(name);
                        }
                        drop(pending);
                        self.written.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                    }
                }
                Ok(response.status() == StatusCode::NO_CONTENT)
            }
            StatusCode::OK => Err(self.json_for::<Value>(Some(start_session), response, MAX_JSON).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a delete answered 200"))),
            _ => Err(refusal(response).await),
        }
    }

    pub async fn list(&self) -> Result<Vec<File>, Error> {
        let response = self.send(Method::GET, &self.app_path()?, |r| r).await?;
        self.json(response).await
    }

    /// [name]'s kept versions, the newest first.
    pub async fn versions(&self, name: &str) -> Result<Vec<Version>, Error> {
        let response = self.send(Method::GET, &format!("{}/versions", self.file_path(name)?), |r| r).await?;
        self.json(response).await
    }

    async fn fetch_file(&self, path: &str, name: &str, to: &Path, known: Option<&str>, enforce_monotonic: bool) -> Result<Fetched, Error> {
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.fetch_with(path, Target::File(to), known, |_| {}).await;
        };
        let lock = self.dest_lock(to);
        let _guard = lock.lock().await;
        // A version held there stands only when verified here at or above the
        // file's watermark (none before one is seen signed); otherwise the file
        // is read and verified again.
        let known = match known {
            Some(etag) if enforce_monotonic => {
                let floor = auth.file_version(&self.app, name).await;
                (floor == 0 || self.verified_version(auth_gen, name, etag).is_some_and(|v| v >= floor)).then_some(etag)
            }
            other => other,
        };
        let mut part = None;
        let mut signed = None;
        let mut digest = [0u8; 32];
        let fetched = self.fetch_with(path, Target::FileHashed(to, &mut part, &mut digest), known, |r| signed = Signed::of(r)).await?;
        self.ensure_personal_gen(auth_gen)?;
        if let Fetched::Saved(etag) = &fetched {
            auth.verify_file_digest(&self.app, name, &digest, signed.as_ref(), enforce_monotonic).await?;
            self.ensure_personal_gen(auth_gen)?;
            if enforce_monotonic && let Some(version) = signed.as_ref().and_then(|s| s.version) {
                self.note_verified(auth_gen, name, etag, version);
            }
            #[cfg(test)]
            {
                let hook = self.after_verify_before_rename.lock().unwrap_or_else(|e| e.into_inner()).clone();
                if let Some(h) = hook {
                    h().await;
                }
            }
            let staged = part.ok_or_else(|| Error::new(Kind::Invalid, "missing staged file"))?;
            self.publish_verified(auth_gen, staged, to)?;
        }
        Ok(fetched)
    }

    /// Puts [staged], verified under [auth_gen], in [to]'s place. Checked and
    /// renamed under the personal slot's lock, the one `set_personal` takes
    /// (after the destination's, taken by the caller): no auth replaced
    /// meanwhile sees it published. `set_personal` is synchronous, so the
    /// slot is a std mutex and the rename (one metadata write beside the
    /// file) is made synchronously under it: neither an await nor
    /// `block_in_place` (which a current-thread runtime refuses) fits there.
    pub(super) fn publish_verified(&self, auth_gen: u64, mut staged: PartGuard, to: &Path) -> Result<(), Error> {
        let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
        if slot.generation != auth_gen || slot.auth.is_none() {
            return Err(Error::new(Kind::SignedOut, "personal signing auth changed during download"));
        }
        std::fs::rename(staged.path(), to).map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", to.display())))?;
        drop(slot);
        staged.disarm();
        Ok(())
    }

    /// Records [etag] as [name]'s version verified signed at [version].
    fn note_verified(&self, auth_gen: u64, name: &str, etag: &str, version: i64) {
        let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        if guard.generation == auth_gen {
            guard.verified_files.insert(name.to_string(), (etag.to_string(), version));
        }
    }

    /// The signed version [etag] was verified at as [name]'s, if it was.
    fn verified_version(&self, auth_gen: u64, name: &str, etag: &str) -> Option<i64> {
        let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
        (guard.generation == auth_gen)
            .then(|| guard.verified_files.get(name).filter(|(e, _)| e == etag).map(|(_, v)| *v))
            .flatten()
    }

    /// [fetch_file], [answered] shown homebase's answer before its body is read.
    pub(super) async fn fetch_with(&self, path: &str, into: Target<'_>, known: Option<&str>, answered: impl FnOnce(&reqwest::Response)) -> Result<Fetched, Error> {
        let response = self
            .send(Method::GET, path, |r| match known {
                Some(etag) => r.header(header::IF_NONE_MATCH, quote(etag)),
                None => r,
            })
            .await?;
        let status = response.status();
        if status == StatusCode::NOT_MODIFIED {
            return Ok(Fetched::Unchanged);
        }
        if status == StatusCode::NOT_FOUND {
            return Ok(Fetched::Missing);
        }
        if status != StatusCode::OK && status != StatusCode::FOUND {
            return Err(refusal(response).await);
        }
        let Some(etag) = self.etag(&response) else {
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "a file without its version")));
        };
        answered(&response);
        let body = if status == StatusCode::FOUND {
            let location = response
                .headers()
                .get(header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| Error::new(Kind::Invalid, "a redirect without Location"))?
                .to_string();
            // The store's own address: no token goes there.
            let stored = self
                .session
                .client()
                .transfer()
                .get(&location)
                .send()
                .await
                .map_err(|e| Error::new(Kind::Unreachable, unreachable("the store", e).detail))?;
            if !stored.status().is_success() {
                return Err(Error::new(Kind::Unreachable, format!("the store: HTTP {}", stored.status())));
            }
            stored
        } else {
            response
        };
        match into {
            Target::File(to) => {
                let lock = self.dest_lock(to);
                let _guard = lock.lock().await;
                save(body, to).await?
            }
            Target::FileHashed(to, part, digest) => {
                let (file, guard) = create_part(to).await?;
                let part_path = guard.path().to_path_buf();
                *part = Some(guard);
                *digest = save_hashed(body, file, &part_path).await?;
            }
            Target::HashOnly(digest) => *digest = hash_stream(body).await?,
            Target::Memory(buffer) => *buffer = read_limited(body, MAX_READ as usize).await?,
        }
        Ok(Fetched::Saved(etag))
    }
}

/// Exclusively creates a unique temporary file in [to]'s directory and arms a
/// [`PartGuard`] only after creation succeeds.
async fn create_part(to: &Path) -> Result<(tokio::fs::File, PartGuard), Error> {
    let dir = to.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    let base = to.file_name().and_then(|n| n.to_str()).unwrap_or("download");
    for _ in 0..16 {
        let mut rnd = [0u8; 8];
        getrandom::fill(&mut rnd).map_err(|e| Error::new(Kind::Invalid, format!("random temp name: {e}")))?;
        let mut suffix = String::with_capacity(16);
        for b in rnd {
            use std::fmt::Write as _;
            let _ = write!(suffix, "{b:02x}");
        }
        let path = dir.join(format!(".{base}.{suffix}.part"));
        match tokio::fs::OpenOptions::new().write(true).create_new(true).open(&path).await {
            Ok(file) => return Ok((file, PartGuard::new(path))),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(Error::new(Kind::Invalid, format!("{}: {e}", path.display()))),
        }
    }
    Err(Error::new(Kind::Invalid, format!("{}: could not allocate unique temp file", to.display())))
}

pub(super) async fn read_file(from: &Path) -> Result<Vec<u8>, Error> {
    tokio::fs::read(from).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", from.display())))
}

pub(super) async fn read_limited(mut response: reqwest::Response, max: usize) -> Result<Vec<u8>, Error> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))? {
        body.extend_from_slice(&chunk);
        if body.len() > max {
            return Err(Error::new(Kind::Invalid, "answer too large"));
        }
    }
    Ok(body)
}

/// Removes an exclusively created temporary file on drop (error or
/// cancellation) unless disarmed after its atomic rename succeeds.
pub(super) struct PartGuard(Option<PathBuf>);

impl PartGuard {
    pub(super) fn new(path: PathBuf) -> Self {
        Self(Some(path))
    }

    pub(super) fn path(&self) -> &Path {
        self.0.as_deref().expect("part guard armed")
    }

    pub(super) fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for PartGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// [response]'s body into [to], through a unique file beside it renamed into
/// place: a download cut short leaves the old file and removes the temp file.
pub(super) async fn save(response: reqwest::Response, to: &Path) -> Result<(), Error> {
    let (file, mut part) = create_part(to).await?;
    let part_path = part.path().to_path_buf();
    save_hashed(response, file, &part_path).await?;
    tokio::fs::rename(part.path(), to).await.map_err(|e| Error::new(Kind::Invalid, format!("{}: {e}", to.display())))?;
    part.disarm();
    Ok(())
}

/// Streams [response]'s body into an already-created [file] at [part] and
/// returns its blake3 digest.
async fn save_hashed(response: reqwest::Response, mut file: tokio::fs::File, part: &Path) -> Result<[u8; 32], Error> {
    let io = |e: std::io::Error| Error::new(Kind::Invalid, format!("{}: {e}", part.display()));
    let mut stream = response.bytes_stream();
    let mut hasher = blake3::Hasher::new();
    let mut written = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))?;
        written += chunk.len() as u64;
        if written > MAX_READ {
            return Err(Error::new(Kind::TooLarge, "the file outgrew homebase's limit"));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await.map_err(io)?;
    }
    file.flush().await.map_err(io)?;
    Ok(*hasher.finalize().as_bytes())
}

async fn hash_stream(response: reqwest::Response) -> Result<[u8; 32], Error> {
    let mut stream = response.bytes_stream();
    let mut hasher = blake3::Hasher::new();
    let mut read_bytes = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| Error::new(Kind::Unreachable, e.to_string()))?;
        read_bytes += chunk.len() as u64;
        if read_bytes > MAX_READ {
            return Err(Error::new(Kind::TooLarge, "the file outgrew homebase's limit"));
        }
        hasher.update(&chunk);
    }
    Ok(*hasher.finalize().as_bytes())
}
