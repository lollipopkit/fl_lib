//! What a member's device believes of what homebase gives: the chain of
//! epoch records from the first to the current, held to the last one it
//! verified ([Trust]), every key it opens against its epoch's record, every
//! signature against its signer's key records ([Chain]) and the key trusted
//! of them.

use std::collections::BTreeMap;

use super::chain::{Chain, Chains};
use super::crypto::{self, InviteSecret, KEY_LEN, NO_KEY, TeamKey};
use super::identity::AccountKey;
use super::trust::{Seen, Trust};
use super::{EpochRecord, InviteView, KeyState, Member, TeamError, WireWrap, b64, canonical, manages, team_bytes, unb64};

pub(crate) fn raw32(s: &str, what: &str) -> Result<[u8; KEY_LEN], TeamError> {
    unb64(s, what)?.try_into().map_err(|_| TeamError::Invalid(format!("{what}: not 32 bytes")))
}

fn untrusted(epoch: i64, what: &str) -> TeamError {
    TeamError::Untrusted(format!("epoch {epoch}: {what}"))
}

/// [user_id]'s chain; none read is an empty one, which follows nothing.
pub(crate) fn chain_of<'a>(chains: &'a Chains, user_id: &str) -> &'a Chain {
    static EMPTY: std::sync::OnceLock<Chain> = std::sync::OnceLock::new();
    chains.get(user_id).unwrap_or_else(|| EMPTY.get_or_init(Chain::default))
}

/// The users whose key records a check of [state] reads: every committer,
/// promoter, granter and member named.
pub(crate) fn users_named(state: &KeyState, members: &[Member]) -> Vec<String> {
    let mut users: Vec<String> = members.iter().map(|m| m.user_id.clone()).collect();
    for r in &state.epochs {
        users.push(r.committed_by.clone());
        users.extend(r.members.iter().map(|m| m.user_id.clone()));
        users.extend(r.roles.iter().flat_map(|g| [g.user_id.clone(), g.signed_by.clone()]));
        users.extend(r.joins.iter().flat_map(|j| [j.user_id.clone(), j.signed_by.clone()]));
    }
    users.extend(state.wraps.iter().filter_map(|w| w.signed_by.clone()));
    users.sort();
    users.dedup();
    users
}

/// Who may commit the epoch after [prev], each bound to the signing key they
/// had there: those managing the team in [prev] (its record's), and those one
/// of them (or one so made) promoted during it (the promotion's), the
/// promoter signing under a key their chain reaches from theirs.
fn authorized<'a>(team: &[u8; 16], prev: &'a EpochRecord, chains: &Chains) -> Result<Vec<(&'a str, [u8; KEY_LEN])>, TeamError> {
    let key_id = raw32(&prev.key_id, "key_id")?;
    let mut authorized = Vec::new();
    for m in prev.members.iter().filter(|m| manages(&m.role)) {
        authorized.push((m.user_id.as_str(), raw32(&m.signing_key, "signing_key")?));
    }
    loop {
        let before = authorized.len();
        for r in &prev.roles {
            if authorized.iter().any(|(u, _)| *u == r.user_id) || r.signed_by == r.user_id || !manages(&r.role) {
                continue;
            }
            let Some((_, bound)) = authorized.iter().find(|(u, _)| *u == r.signed_by) else { continue };
            // One that does not check confers nothing, and stops nobody.
            let checks = (|| {
                let signer_key = raw32(&r.signer_key, "signer_key")?;
                if !chain_of(chains, &r.signed_by).follows(bound, &signer_key) {
                    return Err(untrusted(prev.epoch, "promoted under a key its promoter's chain does not reach"));
                }
                let named = raw32(&r.signing_key, "signing_key")?;
                let message = crypto::role_message(team, prev.epoch, &key_id, &r.signed_by, &r.user_id, &r.role, &named);
                crypto::verify(&signer_key, &message, &unb64(&r.signature, "signature")?, "a promotion signature")?;
                Ok::<_, TeamError>(named)
            })();
            if let Ok(named) = checks {
                authorized.push((&r.user_id, named));
            }
        }
        if authorized.len() == before {
            return Ok(authorized);
        }
    }
}

/// Whether [user_id], signing under [signing_key], may commit after [prev]:
/// [authorized], their key reached from the bound one by signed rotations.
fn may_commit_after(team: &[u8; 16], prev: &EpochRecord, user_id: &str, signing_key: &[u8; KEY_LEN], chains: &Chains) -> Result<bool, TeamError> {
    let chain = chain_of(chains, user_id);
    Ok(authorized(team, prev, chains)?.iter().any(|(u, bound)| *u == user_id && chain.follows(bound, signing_key)))
}

/// Who may write under [record]'s epoch, each bound to the signing key they
/// had in it: its members (the record's), and those who received its key
/// after the commit (a join's): by a grant one of them signed, or by a
/// keyed invite one of them made and their own grant.
pub(crate) fn writers(team: &[u8; 16], record: &EpochRecord, chains: &Chains) -> Result<Vec<(String, [u8; KEY_LEN])>, TeamError> {
    let key_id = raw32(&record.key_id, "key_id")?;
    let mut writers = Vec::new();
    for m in &record.members {
        writers.push((m.user_id.clone(), raw32(&m.signing_key, "signing_key")?));
    }
    let vouched = |writers: &[(String, [u8; KEY_LEN])], by: &str, key: &[u8; KEY_LEN]| {
        writers.iter().any(|(u, bound)| u == by && chain_of(chains, by).follows(bound, key))
    };
    loop {
        let before = writers.len();
        for j in &record.joins {
            if writers.iter().any(|(u, _)| *u == j.user_id) {
                continue;
            }
            // One that does not check admits nobody, and stops nobody.
            let checks = (|| {
                let signing_key = raw32(&j.signing_key, "signing_key")?;
                let signer_key = raw32(&j.signer_key, "signer_key")?;
                let grant = crypto::grant_message(team, record.epoch, &key_id, &j.signed_by, &j.user_id, &j.recipient);
                crypto::verify(&signer_key, &grant, &unb64(&j.signature, "signature")?, "a grant signature")?;
                let ok = match (j.via.as_str(), &j.invite) {
                    ("grant", _) => j.signed_by != j.user_id && vouched(&writers, &j.signed_by, &signer_key),
                    ("invite", Some(inv)) => {
                        let inviter = raw32(&inv.signer_key, "signer_key")?;
                        let message = crypto::invite_message(team, record.epoch, &key_id, &inv.signed_by, &inv.role, &inv.recipient);
                        crypto::verify(&inviter, &message, &unb64(&inv.signature, "signature")?, "an invite signature")?;
                        j.signed_by == j.user_id && signer_key == signing_key && vouched(&writers, &inv.signed_by, &inviter)
                    }
                    _ => false,
                };
                Ok::<_, TeamError>(ok.then_some(signing_key))
            })();
            if let Ok(Some(key)) = checks {
                writers.push((j.user_id.clone(), key));
            }
        }
        if writers.len() == before {
            return Ok(writers);
        }
    }
}

/// Whether [user_id], under [signing_key], may write under [record]'s epoch.
pub(crate) fn may_write(team: &[u8; 16], record: &EpochRecord, user_id: &str, signing_key: &[u8; KEY_LEN], chains: &Chains) -> Result<bool, TeamError> {
    let chain = chain_of(chains, user_id);
    Ok(writers(team, record, chains)?.iter().any(|(u, bound)| u == user_id && chain.follows(bound, signing_key)))
}

/// What [record]'s commit signs.
pub(crate) fn commit_bytes(team: &[u8; 16], record: &EpochRecord) -> Result<Vec<u8>, TeamError> {
    let members = record
        .members
        .iter()
        .map(|m| Ok(crypto::Committed { user_id: m.user_id.clone(), role: m.role.clone(), recipient: m.recipient.clone(), signing_key: raw32(&m.signing_key, "signing_key")? }))
        .collect::<Result<Vec<_>, TeamError>>()?;
    Ok(crypto::commit_message(team, record.epoch, &raw32(&record.key_id, "key_id")?, &raw32(&record.prev_key_id, "prev_key_id")?, &record.committed_by, &members))
}

/// [record]'s signature checked: following [prev] (the record before; none
/// for the first), committed by one [authorized] after [prev], managing the
/// team in [record], signed under the signing key [record] names for them,
/// one [trust] holds of them; a commit MAC after the first. A recovery epoch
/// follows nothing, so is taken only once the person accepted it.
fn check_record(team: &[u8; 16], team_id: &str, record: &EpochRecord, prev: Option<&EpochRecord>, chains: &Chains, trust: &mut Trust) -> Result<[u8; KEY_LEN], TeamError> {
    let key_id = raw32(&record.key_id, "key_id")?;
    let prev_id = raw32(&record.prev_key_id, "prev_key_id")?;
    let signing_key = raw32(&record.signing_key, "signing_key")?;
    if record.recovery {
        if prev_id != NO_KEY {
            return Err(untrusted(record.epoch, "a recovery following a key"));
        }
        // Only the owner of the epoch before starts anew.
        if !prev.is_some_and(|p| p.members.iter().any(|m| m.user_id == record.committed_by && m.role == "owner")) {
            return Err(untrusted(record.epoch, "a recovery by one not owning the team before"));
        }
        if !trust.recovery_accepted(team_id, record.epoch, &record.signing_key) {
            let recipient = record.members.iter().find(|m| m.user_id == record.committed_by).map(|m| m.recipient.as_str());
            return Err(TeamError::RecoveryEpoch {
                epoch: record.epoch,
                committed_by: record.committed_by.clone(),
                signing_key: record.signing_key.clone(),
                fingerprint: recipient.map(|r| crypto::fingerprint(&record.committed_by, r, &signing_key)),
            });
        }
    } else {
        match prev {
            None if prev_id != NO_KEY => return Err(untrusted(record.epoch, "the first, following a key")),
            None => {}
            Some(p) => {
                if raw32(&p.key_id, "key_id")? != prev_id {
                    return Err(untrusted(record.epoch, "not following the epoch before"));
                }
                if !may_commit_after(team, p, &record.committed_by, &signing_key, chains)? {
                    return Err(untrusted(record.epoch, "committed by one not managing the epoch before"));
                }
                if record.commit_mac.is_none() {
                    return Err(untrusted(record.epoch, "no commit MAC"));
                }
            }
        }
    }
    let signer = record.members.iter().find(|m| m.user_id == record.committed_by);
    if !signer.is_some_and(|m| manages(&m.role) && m.signing_key == record.signing_key) {
        return Err(untrusted(record.epoch, "committed by one not managing the team"));
    }
    trust.check(&record.committed_by, chain_of(chains, &record.committed_by), &signing_key)?;
    crypto::verify(&signing_key, &commit_bytes(team, record)?, &unb64(&record.signature, "signature")?, "a commit signature")?;
    Ok(key_id)
}

/// The keys of a team this device holds, by epoch, each checked.
pub struct Keyring {
    team: [u8; 16],
    epoch: i64,
    migrated_epoch: i64,
    keys: BTreeMap<i64, TeamKey>,
    /// [keys]' identities, the newest first: what [Keyring::open] tries.
    identities: Vec<age::x25519::Identity>,
    /// Every epoch's record, checked: who may write under it.
    records: BTreeMap<i64, EpochRecord>,
    unkeyed: Vec<String>,
    unattested: Vec<String>,
    changed: Vec<String>,
    skipped: Vec<(i64, String)>,
    stale_own: bool,
    /// This account may make the next epoch ([authorized]).
    may_commit: bool,
    rotation_needed: bool,
}

/// [w]'s key, if every check holds (see [Keyring::verify]).
fn checked_wrap(team: &[u8; 16], key: &AccountKey, (record, key_id): (&EpochRecord, &[u8; KEY_LEN]), w: &WireWrap, members: &[Member], chains: &Chains, trust: &mut Trust) -> Result<TeamKey, TeamError> {
    let me = key.user_id();
    let k = TeamKey::unwrap(&unb64(&w.wrap, "wrap")?, &key.identities())?;
    if &k.id() != key_id {
        return Err(untrusted(w.epoch, "a key other than the signed one"));
    }
    match (&w.signed_by, &w.signing_key, &w.signature) {
        (None, None, None) => {
            if !record.members.iter().any(|m| m.user_id == me && m.recipient == w.recipient) {
                return Err(untrusted(w.epoch, "a commit's wrap the commit does not name"));
            }
        }
        (Some(by), Some(signing_key), Some(signature)) => {
            // The key is the signed one whoever wraps it: a grant only says
            // who did, one of the epoch's or now a member.
            let member = record.members.iter().any(|m| &m.user_id == by) || members.iter().any(|m| &m.user_id == by && m.approved);
            if by != me && !member {
                return Err(untrusted(w.epoch, "granted by one not of the team"));
            }
            let signing_key = raw32(signing_key, "signing_key")?;
            if by != me {
                trust.check(by, chain_of(chains, by), &signing_key)?;
            }
            let message = crypto::grant_message(team, w.epoch, key_id, by, me, &w.recipient);
            crypto::verify(&signing_key, &message, &unb64(signature, "signature")?, "a grant signature")?;
        }
        _ => return Err(TeamError::Invalid(format!("epoch {}: a wrap partly signed", w.epoch))),
    }
    Ok(k)
}

/// Whether [m]'s recipient and signing key are attested under [k], the key
/// of [epoch].
pub(crate) fn attested(k: &TeamKey, team: &[u8; 16], epoch: i64, m: &Member) -> bool {
    let (Some(r), Some(a), Some(sk)) = (&m.recipient, &m.attestation, &m.signing_key) else { return false };
    let (Ok(a), Ok(sk)) = (unb64(a, "attestation"), raw32(sk, "signing_key")) else { return false };
    m.keyed && k.verify_attestation(team, epoch, &m.user_id, r, &sk, &a).is_ok()
}

/// Whether [m]'s published keys are the head of their [chain], one [trust]
/// holds of them (or first met): what a key may be wrapped to without the
/// person comparing. [TeamError::SigningKeyChanged] when their chain broke.
pub(crate) fn member_head(m: &Member, chains: &Chains, trust: &mut Trust) -> Result<bool, TeamError> {
    let (Some(recipient), Some(signing_key)) = (&m.recipient, &m.signing_key) else { return Ok(false) };
    let chain = chain_of(chains, &m.user_id);
    let signing_key = raw32(signing_key, "signing_key")?;
    let is_head = chain.head().is_some_and(|h| &h.recipient == recipient && h.signing_key == signing_key);
    trust.check(&m.user_id, chain, &signing_key)?;
    Ok(is_head)
}

impl Keyring {
    /// [state]'s chain of records (all of them, from the first), then each
    /// of its wraps for [key]'s account, trusted only if:
    /// - each record follows the one before (`prev_key_id`), is committed by
    ///   one [authorized] after the epoch before, under a key their [chains]
    ///   reach from the bound one by signed rotations, signed under the key it
    ///   names, which [trust] holds of them; a commit MAC after the first; the
    ///   chain reaches the last epoch verified at its key id, and goes no
    ///   lower; a recovery epoch only once the person accepted it;
    /// - a wrap's key is the one its epoch's record names, and the wrap the
    ///   commit's to this account's recipient in it, or a grant signed by one
    ///   of the epoch's or a member now;
    /// - each commit MAC verifies under the epoch before, where that is held.
    ///
    /// The current epoch's failing is the error; an earlier one's wrap is
    /// left out ([Keyring::skipped]). [trust] learns what was checked.
    pub fn verify(team_id: &str, key: &AccountKey, state: &KeyState, members: &[Member], chains: &Chains, trust: &mut Trust) -> Result<Self, TeamError> {
        let team = team_bytes(team_id)?;
        let me = key.user_id();
        // This account's own keys, the current pinned.
        let own: Vec<String> = key.signing_history().collect();
        for k in own.iter().rev() {
            trust.accept(me, k);
        }
        if let Some(m) = members.iter().find(|m| m.user_id == me)
            && m.recipient.as_deref().is_some_and(|r| !key.holds(r))
        {
            return Err(TeamError::AccountKeyReplaced);
        }
        let canonical = canonical(team_id)?;
        let seen = trust.seen(&canonical).cloned();
        if seen.as_ref().is_some_and(|s| state.epoch < s.epoch) {
            return Err(untrusted(state.epoch, "below the last verified"));
        }

        let mut records: Vec<&EpochRecord> = state.epochs.iter().collect();
        records.sort_by_key(|r| r.epoch);
        let complete = records.first().map(|r| r.epoch) == Some(1) && records.last().map(|r| r.epoch) == Some(state.epoch) && records.windows(2).all(|w| w[1].epoch == w[0].epoch + 1);
        if !complete {
            return Err(untrusted(state.epoch, "a chain with a gap"));
        }
        let mut ids = BTreeMap::new();
        for (i, record) in records.iter().enumerate() {
            let key_id = check_record(&team, &canonical, record, i.checked_sub(1).map(|p| records[p]), chains, trust)?;
            if let Some(s) = &seen
                && record.epoch == s.epoch
                && b64(&key_id) != s.key_id
            {
                return Err(untrusted(record.epoch, "another key than the one verified"));
            }
            ids.insert(record.epoch, (key_id, *record));
        }

        let mut keys = BTreeMap::new();
        let mut skipped = Vec::new();
        let mut wraps: Vec<_> = state.wraps.iter().collect();
        wraps.sort_by_key(|w| w.epoch);
        for w in wraps {
            let checked = match ids.get(&w.epoch) {
                Some((key_id, record)) => checked_wrap(&team, key, (record, key_id), w, members, chains, trust),
                None => Err(untrusted(w.epoch, "no signed record")),
            };
            match checked {
                Ok(k) => {
                    keys.insert(w.epoch, k);
                }
                Err(e) if w.epoch == state.epoch => return Err(e),
                Err(e) => skipped.push((w.epoch, e.to_string())),
            }
        }
        // Each commit MAC under the key before it, where both are held.
        for (epoch, (_, record)) in &ids {
            if record.recovery {
                continue;
            }
            if let (Some(prev), Some(_)) = (keys.get(&(epoch - 1)), keys.get(epoch)) {
                let mac = record.commit_mac.as_deref().ok_or_else(|| untrusted(*epoch, "no commit MAC"))?;
                prev.verify_commit_mac(&commit_bytes(&team, record)?, &unb64(mac, "commit_mac")?)?;
            }
        }
        let Some(current) = keys.get(&state.epoch) else {
            // Approved without the key: an admin's grant is awaited.
            if members.iter().any(|m| m.user_id == me && !m.keyed) && !state.wraps.iter().any(|w| w.epoch == state.epoch) {
                return Err(TeamError::Unkeyed);
            }
            return Err(untrusted(state.epoch, "no key of the current epoch"));
        };
        let (mut unkeyed, mut unattested, mut changed) = (Vec::new(), Vec::new(), Vec::new());
        for m in members.iter().filter(|m| m.approved && m.user_id != me) {
            // One who published no key yet has none to have changed.
            match m.signing_key.as_ref().map(|_| member_head(m, chains, trust)) {
                None | Some(Ok(true)) => {}
                Some(Ok(false) | Err(TeamError::SigningKeyChanged { .. })) => changed.push(m.user_id.clone()),
                Some(Err(e)) => return Err(e),
            }
            if !m.keyed {
                unkeyed.push(m.user_id.clone());
            } else if !attested(current, &team, state.epoch, m) {
                unattested.push(m.user_id.clone());
            }
        }
        let (key_id, record) = ids[&state.epoch];
        let may_commit = may_commit_after(&team, record, me, &key.signing_raw(), chains)?;
        trust.see(&canonical, Seen { epoch: state.epoch, key_id: b64(&key_id) });
        let recipient = key.recipient();
        let stale_own = state.wraps.iter().any(|w| keys.contains_key(&w.epoch) && w.recipient != recipient);
        let identities = keys.values().rev().map(TeamKey::identity).collect();
        let records = ids.values().map(|(_, r)| (r.epoch, (*r).clone())).collect();
        Ok(Self {
            team,
            epoch: state.epoch,
            migrated_epoch: state.migrated_epoch,
            keys,
            identities,
            records,
            unkeyed,
            unattested,
            changed,
            skipped,
            stale_own,
            may_commit,
            rotation_needed: state.rotation_needed,
        })
    }

    /// Epoch [epoch]'s record, checked.
    pub fn record(&self, epoch: i64) -> Option<&EpochRecord> {
        self.records.get(&epoch)
    }

    pub fn epoch(&self) -> i64 {
        self.epoch
    }

    /// Every file and batch of the space is of the current epoch.
    pub fn migrated(&self) -> bool {
        self.migrated_epoch == self.epoch
    }

    /// The epoch every file was sealed again under: none is older.
    pub fn migrated_epoch(&self) -> i64 {
        self.migrated_epoch
    }

    pub fn current(&self) -> &TeamKey {
        &self.keys[&self.epoch]
    }

    pub fn keys(&self) -> impl Iterator<Item = (i64, &TeamKey)> {
        self.keys.iter().map(|(e, k)| (*e, k))
    }

    pub fn team(&self) -> &[u8; 16] {
        &self.team
    }

    /// Approved members holding no current key, to be granted one.
    pub fn unkeyed(&self) -> &[String] {
        &self.unkeyed
    }

    /// Members said to hold the current key whose keys no holder attested:
    /// homebase's word alone.
    pub fn unattested(&self) -> &[String] {
        &self.unattested
    }

    /// Members whose signing key is not the one pinned for them.
    pub fn changed(&self) -> &[String] {
        &self.changed
    }

    /// Earlier epochs whose wrap did not check, so not taken.
    pub fn skipped(&self) -> &[(i64, String)] {
        &self.skipped
    }

    /// A key held is wrapped to an older recipient of this account's.
    pub fn stale_own(&self) -> bool {
        self.stale_own
    }

    /// This account may make the next epoch: of the current one's members,
    /// or promoted during it by a signed promotion.
    pub fn may_commit(&self) -> bool {
        self.may_commit
    }

    pub fn rotation_needed(&self) -> bool {
        self.rotation_needed
    }

    /// [plain] sealed under the current key.
    pub fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, TeamError> {
        Ok(self.current().seal(plain)?)
    }

    /// [sealed] opened with whichever key held it is sealed under.
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, TeamError> {
        let refs: Vec<&dyn age::Identity> = self.identities.iter().map(|i| i as &dyn age::Identity).collect();
        Ok(crypto::open_with(sealed, &refs)?.to_vec())
    }
}

/// The key a keyed invite carries, opened with its link's [secret]: the one
/// its signature names, under the signing key the link carries (the link is
/// the channel apart from homebase), which homebase must name too. Pins
/// nothing: whose that key is, is the epoch's record's word, checked by the
/// first [Keyring::verify] once a member.
pub(super) fn invite_key(view: &InviteView, secret: &InviteSecret) -> Result<(i64, TeamKey), TeamError> {
    let team = team_bytes(&view.team_id)?;
    let bad = |what: &str| TeamError::Untrusted(format!("invite: {what}"));
    let (Some(wrap), Some(by), Some(signing_key), Some(signature), Some(key_id)) = (&view.wrap, &view.signed_by, &view.signing_key, &view.signature, &view.key_id) else {
        return Err(bad("not signed"));
    };
    if raw32(signing_key, "signing_key")? != secret.signer {
        return Err(bad("signed under a key other than the link's"));
    }
    let key_id = raw32(key_id, "key_id")?;
    let recipient = secret.recipient();
    if view.recipient.as_deref() != Some(&recipient) {
        return Err(bad("not wrapped to this link"));
    }
    let message = crypto::invite_message(&team, view.epoch, &key_id, by, &view.role, &recipient);
    crypto::verify(&secret.signer, &message, &unb64(signature, "signature")?, "an invite signature")?;
    let k = TeamKey::unwrap(&unb64(wrap, "wrap")?, &[&secret.identity()])?;
    if k.id() != key_id {
        return Err(bad("a key other than the signed one"));
    }
    // Nothing pinned from here: homebase alone says whose the link's key
    // is. The epoch's record, checked once a member, says it.
    Ok((view.epoch, k))
}
