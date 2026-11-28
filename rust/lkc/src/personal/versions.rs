//! [PersonalVersions]: the signing watermarks kept between runs.

use super::*;

impl Default for PersonalVersions {
    fn default() -> Self {
        Self {
            v: VERSIONS_FORMAT,
            files: BTreeMap::new(),
            signed_apps: BTreeSet::new(),
            signed_blobs: BTreeSet::new(),
            signed_log_from: BTreeMap::new(),
            signed_log_ids: BTreeMap::new(),
            signed_snapshots: BTreeSet::new(),
        }
    }
}

impl PersonalVersions {
    pub fn from_json(json: &str) -> Result<Self, Error> {
        if json.trim().is_empty() {
            return Ok(Self::default());
        }
        let stored: Stored = serde_json::from_str(json).map_err(|e| Error::new(Kind::Invalid, format!("personal versions: {e}")))?;
        if stored.v != 1 && stored.v != VERSIONS_FORMAT {
            return Err(Error::new(Kind::Invalid, format!("personal versions: unsupported version {}", stored.v)));
        }
        let mut out = Self {
            v: VERSIONS_FORMAT,
            files: BTreeMap::new(),
            signed_apps: stored.signed_apps,
            signed_blobs: stored.signed_blobs,
            signed_log_from: stored.signed_log_from,
            signed_log_ids: stored.signed_log_ids,
            signed_snapshots: stored.signed_snapshots,
        };
        if stored.v == 1 {
            // TODO(migration): drop v1 migration branch once devices have saved v2.
            for (key, version) in stored.files {
                out.take_legacy_file(key, version);
            }
            for key in stored.signed_files {
                out.take_legacy_file(key, 0);
            }
        } else {
            out.files = stored.files;
        }
        for app in stored.signed_logs {
            let from = out.signed_log_from.entry(app).or_insert(1);
            *from = (*from).min(1);
        }
        out.signed_snapshots.extend(stored.snapshots.into_keys());
        Ok(out)
    }

    /// An entry of a v1 build's `files` or `signed_files`, which did not
    /// separate write-once log blobs from ordinary mutable files.
    // TODO(migration): remove once v1 personal versions JSON is no longer present.
    fn take_legacy_file(&mut self, key: String, version: i64) {
        if !self.files.contains_key(&key)
            && let Some((app, name)) = key.split_once('/')
            && name.starts_with(LEGACY_BLOB_PREFIX)
            && matches!(classify_legacy_op_file(name, version), LegacyOpKind::Blob)
        {
            self.signed_blobs.insert(app.to_string());
            return;
        }
        let entry = self.files.entry(key).or_insert(0);
        *entry = (*entry).max(version);
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("plain JSON")
    }

    pub fn file_version(&self, app: &str, name: &str) -> i64 {
        self.files.get(&file_key(app, name)).copied().unwrap_or(0)
    }

    /// Whether an unsigned answer for ordinary mutable file [name] of [app] is
    /// refused here; with no [name], for the app's files in general.
    pub fn requires_signature(&self, app: &str, name: Option<&str>) -> bool {
        let Some(name) = name else {
            return self.signed_apps.contains(app);
        };
        // Signing the sync key file or a log blob does not lock out the
        // app's earlier unsigned backups, while a signed app file locks out
        // every unsigned one.
        self.signed_apps.contains(app) || self.files.contains_key(&file_key(app, name))
    }

    /// Whether an unsigned answer on the write-once log-blob path of [app] is
    /// refused here.
    pub fn blob_requires_signature(&self, app: &str) -> bool {
        self.signed_apps.contains(app) || self.signed_blobs.contains(app)
    }

    /// Ordinary mutable file [name] of [app] seen or written signed, at
    /// [version] (0: only in its history, which leaves the highest where it is).
    pub(super) fn saw_file(&mut self, app: &str, name: &str, version: i64) {
        // The sync key file signed during migration must not lock out the
        // app's earlier unsigned backups; an app file does.
        if name != KEY_FILE {
            self.signed_apps.insert(app.to_string());
        }
        let entry = self.files.entry(file_key(app, name)).or_insert(0);
        *entry = (*entry).max(version);
    }

    /// A write-once log blob of [app] seen or written signed: skips per-file
    /// version watermarks so `files` stays bounded.
    pub(super) fn saw_blob(&mut self, app: &str) {
        self.signed_blobs.insert(app.to_string());
    }

    pub(super) fn log_signed_from(&self, app: &str) -> Option<i64> {
        self.signed_log_from.get(app).copied()
    }

    /// A signed batch or snapshot at [seq] of [log] (`None`: the log the
    /// last one was of).
    pub(super) fn mark_log_signed_at(&mut self, app: &str, log: Option<&str>, seq: i64) {
        let entry = self.signed_log_from.entry(app.to_string()).or_insert(seq);
        *entry = (*entry).min(seq);
        let Some(log) = log else { return };
        match self.signed_log_ids.get(app) {
            Some(known) if known == log => {}
            // Made anew since signing began: nothing in it is legacy.
            Some(_) => {
                self.signed_log_from.insert(app.to_string(), 1);
                self.signed_log_ids.insert(app.to_string(), log.to_string());
            }
            None => {
                self.signed_log_ids.insert(app.to_string(), log.to_string());
            }
        }
    }

    /// Whether an unsigned batch or snapshot at [seq] of [log] is refused.
    pub(super) fn log_requires_signature(&self, app: &str, log: Option<&str>, seq: i64) -> bool {
        let Some(from) = self.log_signed_from(app) else { return false };
        // Below the floor only on the log it was recorded for, named so.
        let other_log = self.signed_log_ids.get(app).is_some_and(|known| log != Some(known.as_str()));
        seq >= from || other_log
    }

    pub(super) fn saw_snapshot(&mut self, app: &str, log: Option<&str>, seq: i64) {
        self.mark_log_signed_at(app, log, seq);
        self.signed_snapshots.insert(app.to_string());
    }

    pub(super) fn snapshot_requires_signature(&self, app: &str, log: &str, seq: i64) -> bool {
        self.signed_snapshots.contains(app) || self.log_requires_signature(app, Some(log), seq)
    }
}
