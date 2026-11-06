//! What a member's device believes of what homebase gives: the chain of
//! epoch records from the first to the current, held to the last one it
//! verified ([Trust]), every key it opens against its epoch's record, every
//! signature against the signing key pinned for its signer.

use std::collections::BTreeMap;

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

/// Who may commit the epoch after [prev], each with the signing key they
/// must sign under when a promotion named it (`None`: [trust]'s word): those
/// managing the team in [prev], and those one of them (or one so made)
/// promoted during it, under the key that promotion named for them.
fn authorized<'a>(team: &[u8; 16], prev: &'a EpochRecord, trust: &mut Trust) -> Result<Vec<(&'a str, Option<&'a str>)>, TeamError> {
    let key_id = raw32(&prev.key_id, "key_id")?;
    let mut authorized: Vec<(&str, Option<&str>)> = prev.members.iter().filter(|m| manages(&m.role)).map(|m| (m.user_id.as_str(), None)).collect();
    loop {
        let before = authorized.len();
        for r in &prev.roles {
            if authorized.iter().any(|(u, _)| *u == r.user_id) || r.signed_by == r.user_id || !manages(&r.role) {
                continue;
            }
            // The signer: authorized, under the key a promotion named for
            // them, else one [trust] holds for them.
            let Some((_, named)) = authorized.iter().find(|(u, _)| *u == r.signed_by) else { continue };
            let signer_ok = match named {
                Some(k) => *k == r.signer_key,
                None => trust.check_known(&r.signed_by, &r.signer_key).is_ok(),
            };
            // One that does not check confers nothing, and stops nobody.
            let checks = (|| {
                let message = crypto::role_message(team, prev.epoch, &key_id, &r.signed_by, &r.user_id, &r.role, &raw32(&r.signing_key, "signing_key")?);
                crypto::verify(&unb64(&r.signer_key, "signer_key")?, &message, &unb64(&r.signature, "signature")?, "a promotion signature")?;
                Ok::<_, TeamError>(())
            })();
            if signer_ok && checks.is_ok() {
                authorized.push((&r.user_id, Some(&r.signing_key)));
            }
        }
        if authorized.len() == before {
            return Ok(authorized);
        }
    }
}

/// Whether [user_id], signing under [signing_key], may commit after [prev].
fn may_commit_after(team: &[u8; 16], prev: &EpochRecord, user_id: &str, signing_key: &str, trust: &mut Trust) -> Result<bool, TeamError> {
    Ok(authorized(team, prev, trust)?.iter().any(|(u, named)| *u == user_id && named.is_none_or(|k| k == signing_key)))
}

/// [record]'s signature checked: following [prev] (the record before; none
/// for the first), committed by one [authorized] after [prev], managing the
/// team in [record], signed under the signing key [record] names for them.
fn check_record(team: &[u8; 16], record: &EpochRecord, prev: Option<&EpochRecord>, trust: &mut Trust) -> Result<[u8; KEY_LEN], TeamError> {
    let key_id = raw32(&record.key_id, "key_id")?;
    let prev_id = raw32(&record.prev_key_id, "prev_key_id")?;
    match prev {
        None if prev_id != NO_KEY => return Err(untrusted(record.epoch, "the first, following a key")),
        None => {}
        Some(p) => {
            if raw32(&p.key_id, "key_id")? != prev_id {
                return Err(untrusted(record.epoch, "not following the epoch before"));
            }
            // The keys a trusted committer listed are pinned for whom they name.
            for m in &p.members {
                trust.note(&m.user_id, &m.signing_key);
            }
            if !may_commit_after(team, p, &record.committed_by, &record.signing_key, trust)? {
                return Err(untrusted(record.epoch, "committed by one not managing the epoch before"));
            }
        }
    }
    let signer = record.members.iter().find(|m| m.user_id == record.committed_by);
    if !signer.is_some_and(|m| manages(&m.role) && m.signing_key == record.signing_key) {
        return Err(untrusted(record.epoch, "committed by one not managing the team"));
    }
    let members = record
        .members
        .iter()
        .map(|m| Ok(crypto::Committed { user_id: m.user_id.clone(), role: m.role.clone(), recipient: m.recipient.clone(), signing_key: raw32(&m.signing_key, "signing_key")? }))
        .collect::<Result<Vec<_>, TeamError>>()?;
    let message = crypto::commit_message(team, record.epoch, &key_id, &prev_id, &record.committed_by, &members);
    crypto::verify(&unb64(&record.signing_key, "signing_key")?, &message, &unb64(&record.signature, "signature")?, "a commit signature")?;
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
fn checked_wrap(team: &[u8; 16], key: &AccountKey, record: &EpochRecord, key_id: &[u8; KEY_LEN], w: &WireWrap, members: &[Member], trust: &mut Trust) -> Result<TeamKey, TeamError> {
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
            trust.check_known(by, signing_key)?;
            let message = crypto::grant_message(team, w.epoch, key_id, by, me, &w.recipient);
            crypto::verify(&unb64(signing_key, "signing_key")?, &message, &unb64(signature, "signature")?, "a grant signature")?;
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

impl Keyring {
    /// [state]'s chain of records (all of them, from the first), then each
    /// of its wraps for [key]'s account, trusted only if:
    /// - each record follows the one before (`prev_key_id`), is committed by
    ///   one of the epoch before managing the team in it, signed under the
    ///   signing key it names, which [trust] holds for them, never one they
    ///   replaced after a later one signed; the chain reaches the last epoch
    ///   verified at its key id, and goes no lower;
    /// - a wrap's key is the one its epoch's record names, and the wrap the
    ///   commit's to this account's recipient in it, or a grant signed by one
    ///   of the epoch's or a member now;
    /// - each commit MAC verifies under the epoch before, where that is held.
    ///
    /// The current epoch's failing is the error; an earlier one's wrap is
    /// left out ([Keyring::skipped]). [trust] learns what was checked.
    pub fn verify(team_id: &str, key: &AccountKey, state: &KeyState, members: &[Member], trust: &mut Trust) -> Result<Self, TeamError> {
        let team = team_bytes(team_id)?;
        let me = key.user_id();
        let mut own: Vec<String> = key.signing_history().collect();
        own.reverse();
        for signing_key in own {
            trust.accept(me, &signing_key);
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
        // Each committer's signing key by its place among theirs: along the
        // chain it never goes back to one they replaced.
        let mut used: BTreeMap<&str, usize> = BTreeMap::new();
        for (i, record) in records.iter().enumerate() {
            let key_id = check_record(&team, record, i.checked_sub(1).map(|p| records[p]), trust)?;
            let by = record.committed_by.as_str();
            let place = trust.place(by, &record.signing_key)?;
            if used.get(by).is_some_and(|u| place < *u) {
                return Err(untrusted(record.epoch, "signed with a key its committer replaced"));
            }
            used.insert(by, place);
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
                Some((key_id, record)) => checked_wrap(&team, key, record, key_id, w, members, trust),
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
        for (epoch, (key_id, record)) in &ids {
            if let (Some(prev), Some(_)) = (keys.get(&(epoch - 1)), keys.get(epoch)) {
                let mac = record.commit_mac.as_deref().ok_or_else(|| untrusted(*epoch, "no commit MAC"))?;
                prev.verify_commit_mac(&team, *epoch, key_id, &unb64(mac, "commit_mac")?)?;
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
        for m in members.iter().filter(|m| m.approved) {
            if let Some(sk) = &m.signing_key
                && !trust.note(&m.user_id, sk)
            {
                changed.push(m.user_id.clone());
            }
            if !m.keyed {
                unkeyed.push(m.user_id.clone());
            } else if !attested(current, &team, state.epoch, m) {
                unattested.push(m.user_id.clone());
            }
        }
        let (key_id, record) = ids[&state.epoch];
        let may_commit = may_commit_after(&team, record, me, &key.signing_public(), trust)?;
        trust.see(&canonical, Seen { epoch: state.epoch, key_id: b64(&key_id) });
        let recipient = key.recipient();
        let stale_own = state.wraps.iter().any(|w| keys.contains_key(&w.epoch) && w.recipient != recipient);
        let identities = keys.values().rev().map(TeamKey::identity).collect();
        Ok(Self {
            team,
            epoch: state.epoch,
            migrated_epoch: state.migrated_epoch,
            keys,
            identities,
            unkeyed,
            unattested,
            changed,
            skipped,
            stale_own,
            may_commit,
            rotation_needed: state.rotation_needed,
        })
    }

    pub fn epoch(&self) -> i64 {
        self.epoch
    }

    /// Every file and batch of the space is of the current epoch.
    pub fn migrated(&self) -> bool {
        self.migrated_epoch == self.epoch
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
