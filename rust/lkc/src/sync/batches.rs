//! The app's log: appending batches and reading from a cursor.

use super::*;

impl<S: Store> SyncClient<S> {
    /// Appends [body] (an age file, up to [`BATCH_MAX`]) to the log, once per
    /// [key] (16 to 64 of `[A-Za-z0-9_-]`): a retry is answered the seq given.
    pub async fn append(&self, key: &str, body: Vec<u8>) -> Result<Appended, Error> {
        const MAX_CACHE_FLUSH_RETRIES: usize = 4;
        let Some((auth_gen, auth)) = self.personal_auth_with_gen() else {
            return self.append_signed(key, body, None).await;
        };
        // Each attempt, retries too, goes under the session and auth it began with.
        let bound = Some((self.session.identity().ok_or_else(|| Error::new(Kind::SignedOut, "signed out"))?, auth_gen, true));
        let body = bytes::Bytes::from(body);
        let commit_key = (key.to_string(), *blake3::hash(&body).as_bytes());
        let mut expected_id = {
            let guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
            (guard.generation == auth_gen)
                .then(|| guard.batches.get(&commit_key).map(|(id, _)| *id))
                .flatten()
        };
        if expected_id.is_some() {
            for _ in 0..MAX_CACHE_FLUSH_RETRIES {
                let Some(entry_id) = expected_id else { break };
                let flushed = auth.flush_pending_versions().await;
                let current_log = auth.signed_log_id(&self.app).await;
                match flushed {
                    Ok(()) => {
                        enum CacheCheck {
                            Hit(Appended),
                            Replaced(u64),
                            Gone,
                        }
                        let check = {
                            let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                            if slot.generation == auth_gen {
                                let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                                if guard.generation == auth_gen {
                                    match guard.batches.get(&commit_key) {
                                        Some((cur_id, appended))
                                            if *cur_id == entry_id && current_log.as_deref() == Some(appended.log.as_str()) =>
                                        {
                                            let (_, appended) = guard.batches.remove(&commit_key).expect("entry present");
                                            CacheCheck::Hit(appended)
                                        }
                                        Some((cur_id, appended))
                                            if current_log.as_deref() == Some(appended.log.as_str()) =>
                                        {
                                            CacheCheck::Replaced(*cur_id)
                                        }
                                        Some((cur_id, _)) if *cur_id == entry_id => {
                                            guard.batches.remove(&commit_key);
                                            CacheCheck::Gone
                                        }
                                        _ => CacheCheck::Gone,
                                    }
                                } else {
                                    CacheCheck::Gone
                                }
                            } else {
                                CacheCheck::Gone
                            }
                        };
                        match check {
                            CacheCheck::Hit(appended) => return Ok(appended),
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
                                        match guard.batches.get(&commit_key) {
                                            Some((cur_id, appended))
                                                if *cur_id == entry_id && current_log.as_deref() == Some(appended.log.as_str()) =>
                                            {
                                                Some(appended.clone())
                                            }
                                            Some((cur_id, _)) if *cur_id == entry_id => {
                                                guard.batches.remove(&commit_key);
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
                            if let Some(appended) = still_valid {
                                return Err(e.with_committed(Committed::Batch(appended)));
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
        let sig = auth.sign_batch(&self.app, key, &body).await;
        let ticket = self.observation_ticket(auth_gen);
        let res = match self.append_signed_bytes(bound, key, body.clone(), Some(&sig)).await {
            Err(e) if matches!(&e.kind, Kind::Refused(r) if r == "sync_signing_key") => {
                self.ensure_personal_gen(auth_gen)?;
                auth.ensure_published(&self.session, true).await?;
                self.ensure_personal_gen(auth_gen)?;
                let sig = auth.sign_batch(&self.app, key, &body).await;
                self.append_signed_bytes(bound, key, body, Some(&sig)).await?
            }
            other => other?,
        };
        // Answered on a log another observation replaced meanwhile: it stays
        // that one's, its state and binding untouched.
        if !self.retain_log_commits(auth_gen, Some(&res.log), ticket) {
            return Ok(res);
        }
        if let Err(e) = auth.record_batch_written(&self.app, &res.log, res.seq).await {
            if e.kind == Kind::Invalid {
                let slot = self.personal.lock().unwrap_or_else(|e| e.into_inner());
                if slot.generation == auth_gen {
                    let mut guard = self.pending_commits.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.generation == auth_gen {
                        let id = guard.next_id();
                        guard.batches.insert(commit_key, (id, res.clone()));
                    }
                }
                return Err(e.with_committed(Committed::Batch(res)));
            }
            return Err(e);
        }
        Ok(res)
    }

    /// [append], signed by its writer ([sig], no version).
    pub async fn append_signed(&self, key: &str, body: Vec<u8>, sig: Option<&WriteSig>) -> Result<Appended, Error> {
        self.append_signed_bytes(None, key, bytes::Bytes::from(body), sig).await
    }

    async fn append_signed_bytes(
        &self,
        bound: Option<(u64, u64, bool)>,
        key: &str,
        body: bytes::Bytes,
        sig: Option<&WriteSig>,
    ) -> Result<Appended, Error> {
        if !(16..=64).contains(&key.len()) || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err(Error::new(Kind::Invalid, "not an idempotency key"));
        }
        if body.len() > BATCH_MAX {
            return Err(Error::new(Kind::TooLarge, format!("{} bytes", body.len())));
        }
        let path = format!("{}/log", self.app_path()?);
        let response = self
            .send_for(bound, Method::POST, &path, |r| {
                signed_by(r, sig)
                    .header("idempotency-key", key)
                    .header(header::CONTENT_TYPE, "application/octet-stream")
                    .header(header::CONTENT_LENGTH, body.len())
                    .body(body.clone())
            })
            .await?;
        let appended: Appended = self.json_for(bound.map(|(s, _, _)| s), response, MAX_JSON).await?;
        if !valid_log_id(&appended.log) {
            return Err(Error::new(Kind::Invalid, "a malformed log id"));
        }
        Ok(appended)
    }

    /// The log's batches after [after] of [log] (needed past 0), up to
    /// [limit] (homebase's default when `None`).
    pub async fn read_log(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<LogRead, Error> {
        self.read_log_checked(after, log, limit).await.map(|(read, _)| read)
    }

    /// Like [`Self::read_log`], also answering whether personal auth verified
    /// this read's batch signatures.
    pub async fn read_log_checked(&self, after: i64, log: Option<&str>, limit: Option<u32>) -> Result<(LogRead, bool), Error> {
        let mut query = format!("after={after}");
        if let Some(log) = log {
            if !valid_log_id(log) {
                return Err(Error::new(Kind::Invalid, "not a log id"));
            }
            query.push_str(&format!("&log={log}"));
        }
        if let Some(limit) = limit {
            query.push_str(&format!("&limit={limit}"));
        }
        let auth = self.personal_auth_with_gen();
        let ticket = auth.as_ref().map_or(0, |(auth_gen, _)| self.observation_ticket(*auth_gen));
        let response = self.send(Method::GET, &format!("{}/log?{query}", self.app_path()?), |r| r).await?;
        if response.status() == StatusCode::GONE {
            // Validated before anything is invalidated: a malformed 410 must
            // not drop recovery entries.
            let compacted_log = header_non_empty(&response, "sync-log");
            if compacted_log.as_deref().is_some_and(|l| !valid_log_id(l)) {
                return Err(Error::new(Kind::Invalid, "a 410 with a malformed Sync-Log"));
            }
            let snapshot_seq = header_non_empty(&response, "sync-snapshot-seq")
                .and_then(|v| v.parse::<i64>().ok())
                .filter(|seq| *seq >= 0)
                .ok_or_else(|| Error::new(Kind::Invalid, "a 410 without a valid Sync-Snapshot-Seq"))?;
            if let Some((auth_gen, auth)) = &auth {
                self.ensure_personal_gen(*auth_gen)?;
                if let Some(ref log_id) = compacted_log {
                    self.retain_log_commits(*auth_gen, Some(log_id), ticket);
                }
                auth.flush_pending_versions().await?;
                self.ensure_personal_gen(*auth_gen)?;
            }
            return Ok((LogRead::Compacted { log: compacted_log, snapshot_seq }, auth.is_some()));
        }
        let mut page: WirePage = self.json_within(response, MAX_LOG_PAGE).await?;
        page.log = answered_log(page.log)?;
        let mut batches = Vec::with_capacity(page.batches.len());
        for b in page.batches {
            let body = BASE64.decode(&b.body).map_err(|e| Error::new(Kind::Invalid, format!("batch {}: {e}", b.seq)))?;
            if blake3::hash(&body).to_hex().as_str() != b.digest {
                return Err(Error::new(Kind::Invalid, format!("batch {}: digest mismatch", b.seq)));
            }
            batches.push(Batch { seq: b.seq, body, epoch: b.epoch, idempotency_key: b.idempotency_key, signed: b.signed });
        }
        if let Some((auth_gen, auth)) = &auth {
            self.ensure_personal_gen(*auth_gen)?;
            auth.verify_batches(&self.app, page.log.as_deref(), &batches).await?;
            self.ensure_personal_gen(*auth_gen)?;
            self.retain_log_commits(*auth_gen, page.log.as_deref(), ticket);
        }
        Ok((LogRead::Page { log: page.log, batches, head: page.head, snapshot_seq: page.snapshot_seq, more: page.more }, auth.is_some()))
    }
}
