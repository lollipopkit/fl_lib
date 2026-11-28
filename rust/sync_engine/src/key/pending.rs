//! Write intents and pending passwords: what a key-file write that may have
//! landed leaves behind, and when a read settles it.

use super::*;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct WriteIntent {
    pub(super) epoch: i64,
    pub(super) pwd: String,
}

impl WriteIntent {
    fn json(&self) -> serde_json::Value {
        serde_json::json!({ "epoch": self.epoch, "pwd": self.pwd })
    }

    pub(super) fn of(v: &serde_json::Value) -> Option<Self> {
        let epoch = v["epoch"].as_i64()?;
        let pwd = v["pwd"].as_str()?.to_string();
        (!pwd.is_empty()).then_some(Self { epoch, pwd })
    }

    pub(super) fn is(&self, epoch: i64, pwd: &str) -> bool {
        self.epoch == epoch && self.pwd == pwd
    }

    /// Process-salted digest of `(epoch, pwd)`, which stands for it in memory.
    pub(super) fn tag(&self) -> [u8; 32] {
        let mut h = blake3::Hasher::new_keyed(process_salt());
        h.update(&self.epoch.to_be_bytes());
        h.update(self.pwd.as_bytes());
        *h.finalize().as_bytes()
    }

    /// The unresolved attempts on [id], oldest first.
    pub(super) fn all_of(pending: &HashMap<String, String>, id: &str) -> Vec<Self> {
        pending
            .get(&write_intent_key(id))
            .and_then(|raw| serde_json::from_str::<Vec<serde_json::Value>>(raw).ok())
            .map(|list| list.iter().filter_map(Self::of).collect())
            .unwrap_or_default()
    }

    /// Stores [intents] as [id]'s, answering whether `pending` changed.
    fn put_all(pending: &mut HashMap<String, String>, id: &str, intents: &[Self]) -> bool {
        let key = write_intent_key(id);
        let next = (!intents.is_empty()).then(|| serde_json::Value::from(intents.iter().map(Self::json).collect::<Vec<_>>()).to_string());
        if pending.get(&key) == next.as_ref() {
            return false;
        }
        match next {
            Some(raw) => pending.insert(key, raw),
            None => pending.remove(&key),
        };
        true
    }
}

/// A write intent as staged by one attempt: [added] when that attempt put it
/// there (an equal one from an earlier attempt that may have committed stays
/// that one's). Attempts on one ring are serialized by `secret_key_init`.
pub(super) struct StagedIntent {
    pub(super) intent: WriteIntent,
    added: bool,
}

/// The secret key an external account-key intent protects, whatever its
/// provenance.
pub(super) fn external_intent_secret_key(raw: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    Some(SecretKey::parse(v["pwd"].as_str()?).ok()?.format().to_string())
}

/// An external account-key intent: only one carrying explicit provenance
/// (`owners`, each account's unresolved writes counted) counts, whatever its
/// `pwd` parses as.
pub(super) fn decode_external_intent(raw: &str) -> Option<RecoveredExternal> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    let _epoch = v["epoch"].as_i64()?;
    let key = SecretKey::parse(v["pwd"].as_str()?).ok()?.format().to_string();
    let count = |n: &serde_json::Value| n.as_u64().and_then(|n| u32::try_from(n).ok()).filter(|n| *n > 0);
    let owners: BTreeMap<String, u32> = v
        .get("owners")?
        .as_object()?
        .iter()
        .filter(|(uid, _)| !uid.is_empty())
        .filter_map(|(uid, n)| Some((uid.clone(), count(n)?)))
        .collect();
    let unowned = v.get("unowned").and_then(count).unwrap_or(0);
    let rec = RecoveredExternal { key, owners, unowned };
    (!rec.is_empty()).then_some(rec)
}

pub(super) fn encode_external_intent(rec: &RecoveredExternal) -> String {
    serde_json::json!({ "epoch": 0, "pwd": rec.key, "owners": rec.owners, "unowned": rec.unowned }).to_string()
}

/// What one open verified there: the file's version and the epoch it holds,
/// by the [read] it came from.
pub(super) struct Seen {
    pub(super) epoch: i64,
    pub(super) version: String,
    pub(super) read: Read,
}

/// How a verified file settles the write attempts on its store.
#[derive(Clone, Copy)]
pub(super) struct Settles {
    /// [KeyFile::orders_writes].
    pub(super) ordered: bool,
    /// [KeyFile::settle_window].
    pub(super) window: Duration,
}

impl Settles {
    pub(super) fn of(file: &dyn KeyFile) -> Self {
        Self { ordered: file.orders_writes(), window: file.settle_window() }
    }

    /// What settles under both: ordered only where both are, the longer window.
    pub(super) fn and(self, other: Self) -> Self {
        Self { ordered: self.ordered && other.ordered, window: self.window.max(other.window) }
    }
}

/// One read of a key file: when it began, and how the file read settles
/// attempts (taken with it, so a file bound since changes neither).
#[derive(Clone, Copy)]
pub(super) struct Read {
    pub(super) began: MonoInstant,
    pub(super) settles: Settles,
}

impl Read {
    pub(super) fn of(file: &dyn KeyFile) -> Self {
        Self { began: MonoInstant::now(), settles: Settles::of(file) }
    }

    pub(super) fn seen(self, epoch: i64, version: String) -> Seen {
        Seen { epoch, version, read: self }
    }
}

/// A write verified on the remote: at [epoch] under [pwd], on a store that
/// [settles] attempts so; by a read that began at [read], or (None) by that
/// write's own acknowledgement, which settles no other attempt by its window.
#[derive(Clone, Copy)]
struct Settled<'a> {
    epoch: i64,
    pwd: &'a str,
    read: Option<MonoInstant>,
    settles: Settles,
}

#[derive(Default)]
pub(super) struct PendingState {
    /// Previous passwords announced via [`KeyRing::password_changed`] per
    /// remote that have not yet been superseded by a newer password opening or
    /// committing the remote, preventing reconciliation from dropping an
    /// outstanding notification sent before the stored password updates.
    pub(super) notified: HashMap<String, Vec<String>>,
    /// When each write intent's latest attempt was dispatched by this
    /// process, or, for one left by an earlier process, when this one first
    /// met it. Keyed by remote and [WriteIntent::tag], no password kept. Only
    /// a process that runs a window past meeting one settles it so; one never
    /// held still goes once a verified epoch floor passes it, and an attempt
    /// staged again adds none.
    pub(super) since: HashMap<(String, [u8; 32]), MonoInstant>,
}

impl PendingState {
    fn since_key(id: &str, intent: &WriteIntent) -> (String, [u8; 32]) {
        (id.to_string(), intent.tag())
    }

    /// Whether [intent]'s attempt was over before a read that began at
    /// [began] and does not hold it.
    fn over_by(&mut self, id: &str, intent: &WriteIntent, began: MonoInstant, window: Duration) -> bool {
        let since = *self.since.entry(Self::since_key(id, intent)).or_insert_with(MonoInstant::now);
        since.checked_add(window).is_some_and(|end| end <= began)
    }

    /// Keeps the dispatch times of [id]'s [intents] only.
    fn keep_since(&mut self, id: &str, intents: &[WriteIntent]) {
        let tags: Vec<_> = intents.iter().map(WriteIntent::tag).collect();
        self.since.retain(|(of, tag), _| of != id || tags.contains(tag));
    }
}

impl RingInner {
    pub(super) fn ensure_not_forgotten(&self, id: &str, expected_forget_gen: u64) -> Result<()> {
        let table = self.keys.lock().unwrap_or_else(|e| e.into_inner());
        if table.forget_gen_of(id) != expected_forget_gen {
            return Err(Error::SignedOut);
        }
        Ok(())
    }

    pub(super) async fn set_epoch_2fa(&self, id: &str, expected_forget_gen: u64, epoch: i64) -> Result<()> {
        validate_remote_id(id)?;
        let _guard = self.epochs_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        let mut all = self.secrets.epochs().await?;
        if let Some(floor) = all.get(id).copied()
            && epoch < floor
        {
            return Err(Error::Untrusted(format!("{id}: key file epoch rollback ({epoch} < {floor})")));
        }
        let marker = two_fa_key(id);
        if all.get(id).copied() == Some(epoch) && all.get(&marker).copied() == Some(1) {
            return Ok(());
        }
        all.insert(id.to_string(), epoch);
        all.insert(marker, 1);
        self.secrets.set_epochs(all).await
    }

    pub(super) async fn clear_epoch(&self, id: &str) -> Result<()> {
        validate_remote_id(id)?;
        let _guard = self.epochs_lock.lock().await;
        let mut all = self.secrets.epochs().await?;
        let removed_epoch = all.remove(id).is_some();
        let removed_marker = all.remove(&two_fa_key(id)).is_some();
        if !removed_epoch && !removed_marker {
            return Ok(());
        }
        self.secrets.set_epochs(all).await
    }

    pub(super) async fn clear_all_pending(&self, id: &str) -> Result<()> {
        let mut st = self.pending_lock.lock().await;
        let mut all = self.secrets.pending().await?;
        let removed_pwd = all.remove(id).is_some();
        let removed_intent = all.remove(&write_intent_key(id)).is_some();
        if removed_pwd || removed_intent {
            self.secrets.set_pending(all).await?;
        }
        st.notified.remove(id);
        st.keep_since(id, &[]);
        Ok(())
    }

    /// Once [read] found a file that neither this password nor any write
    /// intent's opens: drops `pending[id]`, and the intents dispatched longer than the settle
    /// window before it began, which never took effect there. A more recent
    /// one stays: it may still land.
    pub(super) async fn refused_password_for(&self, id: &str, expected_forget_gen: u64, read: Read) -> Result<()> {
        self.settle_unheld(id, expected_forget_gen, read, true).await
    }

    /// Once [read] found no file on a store that orders its writes, so none
    /// may only not have arrived: the intents dispatched longer than the settle window before it
    /// began never landed. `pending[id]` stays: a device may still put a file
    /// there sealed under it.
    pub(super) async fn absent_for(&self, id: &str, expected_forget_gen: u64, read: Read) -> Result<()> {
        self.settle_unheld(id, expected_forget_gen, read, false).await
    }

    async fn settle_unheld(&self, id: &str, expected_forget_gen: u64, read: Read, refused: bool) -> Result<()> {
        let mut st = self.pending_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        let mut all = self.secrets.pending().await?;
        let removed_pwd = refused && all.remove(id).is_some();
        let mut intents = WriteIntent::all_of(&all, id);
        intents.retain(|i| !st.over_by(id, i, read.began, read.settles.window));
        st.keep_since(id, &intents);
        if WriteIntent::put_all(&mut all, id, &intents) || removed_pwd {
            self.secrets.set_pending(all).await?;
        }
        if refused {
            st.notified.remove(id);
        }
        Ok(())
    }

    /// Adds the pre-CAS write intent for one attempt on [id], beside those of
    /// earlier attempts that may still have committed; an equal one already
    /// there covers it too.
    pub(super) async fn stage_write_intent(&self, id: &str, expected_forget_gen: u64, epoch: i64, pwd: &str) -> Result<StagedIntent> {
        let mut st = self.pending_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        let mut all = self.secrets.pending().await?;
        let intent = WriteIntent { epoch, pwd: pwd.to_string() };
        // Its window starts anew under this lock, so no read settles it
        // before it is dispatched ([Self::dispatching] starts it once more).
        st.since.insert(PendingState::since_key(id, &intent), MonoInstant::now());
        let mut intents = WriteIntent::all_of(&all, id);
        let added = !intents.contains(&intent);
        if added {
            intents.push(intent.clone());
            WriteIntent::put_all(&mut all, id, &intents);
            self.secrets.set_pending(all).await?;
        }
        Ok(StagedIntent { intent, added })
    }

    /// Starts [intent]'s settle window anew: its attempt is dispatched now.
    pub(super) async fn dispatching(&self, id: &str, intent: &WriteIntent) {
        let mut st = self.pending_lock.lock().await;
        st.since.insert(PendingState::since_key(id, intent), MonoInstant::now());
    }

    /// Removes [staged]'s intent when that attempt added it and its write is
    /// known not to have committed; every other attempt's stays.
    pub(super) async fn rollback_write_intent(&self, id: &str, expected_forget_gen: u64, staged: &StagedIntent) -> Result<()> {
        if !staged.added {
            return Ok(());
        }
        let mut st = self.pending_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        let mut all = self.secrets.pending().await?;
        let mut intents = WriteIntent::all_of(&all, id);
        let Some(at) = intents.iter().position(|i| *i == staged.intent) else {
            return Ok(());
        };
        intents.remove(at);
        st.keep_since(id, &intents);
        WriteIntent::put_all(&mut all, id, &intents);
        self.secrets.set_pending(all).await
    }

    /// Settles `pending[id]` for the remote [settled] verified at its epoch
    /// under its password, that epoch already durable. That write's
    /// own intent goes, and those below the verified epoch floor, which
    /// recovery never matches again (it takes an intent's epoch only at or
    /// above it). On a store that orders its writes, every other attempt at
    /// that epoch lost its condition and goes too. Any other attempt goes once
    /// dispatched longer than the store's settle window before the read that
    /// verified the file without it began; until then it may still land.
    async fn reconcile_pending_locked(
        &self,
        st: &mut PendingState,
        id: &str,
        settled: Settled<'_>,
        preserve_same_pending: bool,
    ) -> Result<()> {
        let Settled { epoch: settled_epoch, pwd: settled_pwd, read, settles } = settled;
        let floor = self.secrets.epochs().await?.get(id).copied();
        let mut all = self.secrets.pending().await?;
        let current = self.secrets.password().await?;
        let notified = st.notified.get(id).is_some_and(|v| v.iter().any(|p| p == settled_pwd));
        let next = match current.as_deref().filter(|p| !p.is_empty()) {
            Some(cur) if cur != settled_pwd => Some(settled_pwd.to_string()),
            _ if notified || (preserve_same_pending && all.get(id).map(String::as_str) == Some(settled_pwd)) => {
                Some(settled_pwd.to_string())
            }
            _ => None,
        };
        let mut intents = WriteIntent::all_of(&all, id);
        intents.retain(|i| {
            !i.is(settled_epoch, settled_pwd)
                && !(settles.ordered && i.epoch == settled_epoch)
                && floor.is_none_or(|f| i.epoch >= f)
                && read.is_none_or(|began| !st.over_by(id, i, began, settles.window))
        });
        st.keep_since(id, &intents);
        let removed_intent = WriteIntent::put_all(&mut all, id, &intents);
        let pwd_changed = all.get(id) != next.as_ref();
        if removed_intent || pwd_changed {
            match &next {
                Some(p) => all.insert(id.to_string(), p.clone()),
                None => all.remove(id),
            };
            self.secrets.set_pending(all).await?;
        }
        match next {
            Some(_) => {
                if let Some(list) = st.notified.get_mut(id) {
                    list.retain(|p| p == settled_pwd);
                    if list.is_empty() {
                        st.notified.remove(id);
                    }
                }
            }
            None => {
                st.notified.remove(id);
            }
        }
        Ok(())
    }

    /// Records that [id]'s remote key file committed at [epoch] sealed under
    /// `(committed_pwd, sk)`, persisting the 2FA epoch and reconciling
    /// `pending[id]` + clearing the pre-CAS write intent only once both are
    /// durable, without losing a concurrent `password_changed`.
    pub(super) async fn record_committed_write(&self, id: &str, expected_forget_gen: u64, epoch: i64, committed_pwd: &str, settles: Settles) -> Result<()> {
        self.set_epoch_2fa(id, expected_forget_gen, epoch).await?;
        let mut st = self.pending_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        let settled = Settled { epoch, pwd: committed_pwd, read: None, settles };
        self.reconcile_pending_locked(&mut st, id, settled, true).await
    }

    /// Settles what [seen] resolved after [id] opened cleanly under
    /// [opened_pwd] (its epoch durable), unless a `password_changed`
    /// notification for [opened_pwd] or a newer stored password is already
    /// outstanding. Nothing goes, answering false, when [current] says [seen]
    /// was superseded meanwhile: the caller opens again.
    pub(super) async fn clear_pending_if_settled(
        &self,
        id: &str,
        expected_forget_gen: u64,
        seen: &Seen,
        opened_pwd: &str,
        current: impl Fn() -> bool,
    ) -> Result<bool> {
        let mut st = self.pending_lock.lock().await;
        self.ensure_not_forgotten(id, expected_forget_gen)?;
        if !current() {
            return Ok(false);
        }
        let settled = Settled { epoch: seen.epoch, pwd: opened_pwd, read: Some(seen.read.began), settles: seen.read.settles };
        self.reconcile_pending_locked(&mut st, id, settled, false).await?;
        Ok(true)
    }
}

impl KeyRing {
    /// When the attempt behind [id]'s write intent `(epoch, pwd)` starts its
    /// settle window.
    #[cfg(test)]
    pub(crate) async fn intent_since(&self, id: &str, epoch: i64, pwd: &str) -> Option<MonoInstant> {
        let intent = WriteIntent { epoch, pwd: pwd.to_string() };
        self.0.pending_lock.lock().await.since.get(&PendingState::since_key(id, &intent)).copied()
    }

}
