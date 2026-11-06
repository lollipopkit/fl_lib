//! What a device does with its teams once its account key is open.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::json;
use tokio::sync::Mutex as AsyncMutex;

use super::crypto::{self, InviteSecret, NO_KEY, TeamKey};
use super::identity::AccountKey;
use super::space::TeamSpace;
use super::trust::{Keeper, Trust};
use super::verify::{self, Keyring, raw32};
use super::{InviteLink, InviteTerms, Joined, Member, Reencrypted, TeamClient, TeamDetail, TeamError, b64, canonical, manages, team_bytes, user_segment};
use crate::session::Store;
use crate::sync::{self, Condition, SyncClient};

/// A member as the person is shown them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberView {
    pub user_id: String,
    pub name: String,
    pub role: String,
    pub approved: bool,
    /// Holds the current key.
    pub keyed: bool,
    /// What the person compares with the member's own
    /// ([crypto::fingerprint]); `None` before they published their key.
    pub fingerprint: Option<String>,
    /// Their keys are attested by a holder of the current key.
    pub attested: bool,
    /// Their signing key is not the one first met.
    pub changed: bool,
}

/// A team as this device sees it after checking its keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamStatus {
    pub epoch: i64,
    /// Every file and batch is of the current epoch.
    pub migrated: bool,
    /// A member holding the key left, or a member's account key was
    /// replaced: an admin's device rotates ([Teams::rotate]).
    pub rotation_needed: bool,
    /// This device's keys are wrapped to an older account key
    /// ([Teams::rewrap_teams]).
    pub stale_own: bool,
    /// This account may make the next epoch ([TeamError::PromotionNeeded]).
    pub may_commit: bool,
    pub members: Vec<MemberView>,
    /// Earlier epochs whose wrap did not check: their data is unread here.
    pub skipped_epochs: Vec<i64>,
}

fn fingerprint_of(m: &Member) -> Option<String> {
    let sk = raw32(m.signing_key.as_deref()?, "signing_key").ok()?;
    Some(crypto::fingerprint(&m.user_id, m.recipient.as_deref()?, &sk))
}

/// The account's teams, its key open: one per account per process.
pub struct Teams<S: Store, K: Keeper> {
    client: TeamClient<S>,
    key: AccountKey,
    /// Changed only once [keeper] wrote the change.
    trust: Arc<AsyncMutex<Trust>>,
    keeper: Arc<K>,
    /// Each team's keyring last checked.
    opened: Mutex<HashMap<String, Arc<Keyring>>>,
}

impl<S: Store, K: Keeper> Teams<S, K> {
    pub fn new(client: TeamClient<S>, key: AccountKey, trust: Trust, keeper: K) -> Self {
        Self { client, key, trust: Arc::new(AsyncMutex::new(trust)), keeper: Arc::new(keeper), opened: Mutex::new(HashMap::new()) }
    }

    /// The same teams under [key], the account's next: one trust between
    /// them, so neither writes over what the other learnt.
    pub fn with_key(&self, key: AccountKey) -> Result<Self, TeamError> {
        if key.user_id() != self.me() {
            return Err(TeamError::Invalid("an account key of another account".into()));
        }
        let client = TeamClient::new(self.client.session().clone());
        Ok(Self { client, key, trust: self.trust.clone(), keeper: self.keeper.clone(), opened: Mutex::new(HashMap::new()) })
    }

    pub fn client(&self) -> &TeamClient<S> {
        &self.client
    }

    pub fn key(&self) -> &AccountKey {
        &self.key
    }

    fn me(&self) -> &str {
        self.key.user_id()
    }

    /// [f] on a copy of the trust, kept (written first) only when it succeeds.
    async fn trusting<T>(&self, f: impl AsyncFnOnce(&mut Trust) -> Result<T, TeamError>) -> Result<T, TeamError> {
        let mut held = self.trust.lock().await;
        let mut trust = held.clone();
        let out = f(&mut trust).await?;
        if trust != *held {
            self.keeper.save(trust.to_json()).await.map_err(|e| TeamError::Invalid(format!("trust not kept: {e}")))?;
            *held = trust;
        }
        Ok(out)
    }

    /// [user_id]'s [signing_key] taken as theirs: the person compared it.
    pub async fn accept_signing_key(&self, user_id: &str, signing_key: &str) -> Result<(), TeamError> {
        self.trusting(async |t| {
            t.accept(user_id, signing_key);
            Ok(())
        })
        .await
    }

    /// Team [team] forgotten here: left, or deleted.
    pub async fn forget_team(&self, team: &str) -> Result<(), TeamError> {
        let team = canonical(team)?;
        self.opened.lock().unwrap_or_else(|e| e.into_inner()).remove(&team);
        self.trusting(async |t| {
            t.forget_team(&team);
            Ok(())
        })
        .await
    }

    /// Team [team]'s keys, read and checked again.
    pub async fn keyring(&self, team: &str) -> Result<Arc<Keyring>, TeamError> {
        Ok(self.checked(team).await?.0)
    }

    /// [keyring], with the team as homebase said it then.
    async fn checked(&self, team: &str) -> Result<(Arc<Keyring>, Arc<TeamDetail>), TeamError> {
        let (detail, state) = tokio::try_join!(self.client.detail(team), self.client.key_state(team))?;
        let ring = Arc::new(self.trusting(async |t| Keyring::verify(team, &self.key, &state, &detail.members, t)).await?);
        let detail = Arc::new(detail);
        self.opened.lock().unwrap_or_else(|e| e.into_inner()).insert(canonical(team)?, ring.clone());
        Ok((ring, detail))
    }

    /// The keyring last checked, else checked now.
    pub async fn ring(&self, team: &str) -> Result<Arc<Keyring>, TeamError> {
        if let Some(o) = self.opened.lock().unwrap_or_else(|e| e.into_inner()).get(&canonical(team)?) {
            return Ok(o.clone());
        }
        self.keyring(team).await
    }

    pub async fn status(&self, team: &str) -> Result<TeamStatus, TeamError> {
        let detail = self.client.detail(team).await?;
        if detail.membership.team.epoch == 0 {
            // No key yet: the members as homebase says, to be confirmed.
            let members = detail
                .members
                .iter()
                .map(|m| MemberView {
                    user_id: m.user_id.clone(),
                    name: m.name.clone(),
                    role: m.role.clone(),
                    approved: m.approved,
                    keyed: false,
                    fingerprint: fingerprint_of(m),
                    attested: false,
                    changed: false,
                })
                .collect();
            let may_commit = detail.membership.role.as_str() == "owner" || detail.membership.role.as_str() == "admin";
            return Ok(TeamStatus { epoch: 0, migrated: true, rotation_needed: false, stale_own: false, may_commit, members, skipped_epochs: vec![] });
        }
        let (ring, detail) = self.checked(team).await?;
        let members = detail
            .members
            .iter()
            .map(|m| MemberView {
                user_id: m.user_id.clone(),
                name: m.name.clone(),
                role: m.role.clone(),
                approved: m.approved,
                keyed: m.keyed,
                fingerprint: fingerprint_of(m),
                attested: m.approved && m.keyed && !ring.unattested().contains(&m.user_id),
                changed: ring.changed().contains(&m.user_id),
            })
            .collect();
        Ok(TeamStatus {
            epoch: ring.epoch(),
            migrated: ring.migrated(),
            rotation_needed: ring.rotation_needed(),
            stale_own: ring.stale_own(),
            may_commit: ring.may_commit(),
            members,
            skipped_epochs: ring.skipped().iter().map(|(e, _)| *e).collect(),
        })
    }

    /// The team's first key. Every other approved member is wrapped to as
    /// homebase says they are, so each must be [confirmed] (their
    /// fingerprints, as the person compared them). Answers the new epoch.
    pub async fn commit_first(&self, team: &str, confirmed: &[String]) -> Result<i64, TeamError> {
        let detail = Arc::new(self.client.detail(team).await?);
        self.commit_next(team, None, detail, confirmed).await
    }

    /// A new key in place of the current: after a member left, or a member's
    /// account key was replaced. One whose keys no holder of the current key
    /// attested must be [confirmed]. Answers the new epoch.
    pub async fn rotate(&self, team: &str, confirmed: &[String]) -> Result<i64, TeamError> {
        let (ring, detail) = self.checked(team).await?;
        self.commit_next(team, Some(&ring), detail, confirmed).await
    }

    async fn commit_next(&self, team: &str, ring: Option<&Keyring>, detail: Arc<TeamDetail>, confirmed: &[String]) -> Result<i64, TeamError> {
        let id = team_bytes(team)?;
        let me = self.me();
        let epoch = detail.membership.team.epoch;
        let held = match (epoch, ring) {
            (0, _) => None,
            (_, Some(ring)) if ring.epoch() == epoch => Some(ring.current()),
            _ => return Err(TeamError::StaleEpoch(epoch)),
        };
        // What the other members would refuse is never sent.
        if ring.is_some_and(|r| !r.may_commit()) {
            return Err(TeamError::PromotionNeeded);
        }
        let approved: Vec<&Member> = detail.members.iter().filter(|m| m.approved).collect();
        let missing: Vec<String> = approved.iter().filter(|m| m.recipient.is_none() || m.signing_key.is_none()).map(|m| m.user_id.clone()).collect();
        if !missing.is_empty() {
            return Err(TeamError::NoRecipient(missing));
        }
        let own = approved.iter().find(|m| m.user_id == me).ok_or(TeamError::Perm)?;
        if own.recipient.as_deref() != Some(&self.key.recipient()) || own.signing_key.as_deref() != Some(&self.key.signing_public()) {
            return Err(TeamError::AccountKeyReplaced);
        }
        let unconfirmed: Vec<String> = approved
            .iter()
            .filter(|m| m.user_id != me)
            .filter(|m| held.is_none_or(|k| !verify::attested(k, &id, epoch, m)))
            .filter(|m| fingerprint_of(m).is_none_or(|f| !confirmed.contains(&f)))
            .map(|m| m.user_id.clone())
            .collect();
        if !unconfirmed.is_empty() {
            return Err(TeamError::Unconfirmed(unconfirmed));
        }

        let next = TeamKey::generate();
        let new_epoch = epoch + 1;
        let key_id = next.id();
        let prev = held.map_or(NO_KEY, TeamKey::id);
        let mut members = Vec::with_capacity(approved.len());
        let mut wraps = Vec::with_capacity(approved.len());
        for m in &approved {
            let recipient = m.recipient.clone().expect("checked");
            let signing_key = raw32(m.signing_key.as_deref().expect("checked"), "signing_key")?;
            wraps.push(json!({
                "user_id": m.user_id,
                "recipient": recipient,
                "wrap": b64(&next.wrap(&recipient)?),
                "attestation": b64(&next.attest(&id, new_epoch, &m.user_id, &recipient, &signing_key)),
            }));
            members.push(crypto::Committed { user_id: m.user_id.clone(), role: m.role.clone(), recipient, signing_key });
        }
        let message = crypto::commit_message(&id, new_epoch, &key_id, &prev, me, &members);
        let body = json!({
            "epoch": epoch,
            "commit_mac": held.map(|k| b64(&k.commit_mac(&id, new_epoch, &key_id))),
            "key_id": b64(&key_id),
            "prev_key_id": b64(&prev),
            "signature": b64(&crypto::sign(self.key.signing(), &message)),
            "wraps": wraps,
        });
        let done = match self.client.post(&format!("/v2/teams/{team}/keys"), &body).await {
            // Another commit came first, or this device's view is behind:
            // read again, then the person decides again.
            Err(TeamError::Refused(r)) if r == "team_epoch_stale" || r == "team_key_chain" => {
                return Err(TeamError::StaleEpoch(self.keyring(team).await?.epoch()));
            }
            other => other?,
        };
        let epoch = done["epoch"].as_i64().ok_or_else(|| TeamError::Invalid("a commit without its epoch".into()))?;
        self.refreshed(team).await;
        Ok(epoch)
    }

    /// The current key to approved member [user_id], who joined without it,
    /// as the person saw them: [fingerprint], refused if homebase now says
    /// other keys.
    pub async fn grant(&self, team: &str, user_id: &str, fingerprint: &str) -> Result<(), TeamError> {
        let (ring, detail) = self.checked(team).await?;
        let member = detail.members.iter().find(|m| m.user_id == user_id && m.approved).ok_or(TeamError::NotFound)?;
        if fingerprint_of(member).as_deref() != Some(fingerprint) {
            return Err(TeamError::Untrusted(format!("{user_id}: keys other than the ones confirmed")));
        }
        let recipient = member.recipient.as_deref().expect("a fingerprint");
        let signing_key = raw32(member.signing_key.as_deref().expect("a fingerprint"), "signing_key")?;
        self.put_wrap(team, ring.epoch(), ring.current(), user_id, recipient, &signing_key).await?;
        self.refreshed(team).await;
        Ok(())
    }

    /// Approved member [user_id], whose [fingerprint] the person compared,
    /// made [role] (`admin`, or `member` again). A promotion is signed, so
    /// they may make the next epoch though they joined after this one's
    /// commit; the owner's.
    pub async fn set_role(&self, team: &str, user_id: &str, role: &str, fingerprint: &str) -> Result<(), TeamError> {
        if role == "owner" {
            return Err(TeamError::Invalid("ownership is transferred".into()));
        }
        let path = format!("/v2/teams/{team}/members/{}/role", user_segment(user_id)?);
        // Signed again once under an epoch committed meanwhile: the same
        // person, the same keys confirmed.
        for again in [true, false] {
            let body = self.promotion(team, user_id, role, fingerprint).await?;
            match self.client.put(&path, &body).await {
                Err(TeamError::Refused(r)) if again && r == "team_epoch_stale" => continue,
                other => other?,
            };
            break;
        }
        self.refreshed(team).await;
        Ok(())
    }

    /// The team handed to approved member [user_id], whose [fingerprint] the
    /// person compared: they become the owner, this account an admin.
    pub async fn transfer(&self, team: &str, user_id: &str, fingerprint: &str) -> Result<(), TeamError> {
        let path = format!("/v2/teams/{team}/transfer");
        for again in [true, false] {
            let mut body = self.promotion(team, user_id, "owner", fingerprint).await?;
            body["user_id"] = json!(user_id);
            match self.client.post(&path, &body).await {
                Err(TeamError::Refused(r)) if again && r == "team_epoch_stale" => continue,
                other => other?,
            };
            break;
        }
        self.refreshed(team).await;
        Ok(())
    }

    /// The body of a role change: a promotion signed under the current key's
    /// id ([crypto::role_message]); before the first key, the role alone.
    async fn promotion(&self, team: &str, user_id: &str, role: &str, fingerprint: &str) -> Result<serde_json::Value, TeamError> {
        let id = team_bytes(team)?;
        let detail = self.client.detail(team).await?;
        if detail.membership.team.epoch == 0 || !manages(role) {
            return Ok(json!({ "role": role }));
        }
        let (ring, detail) = self.checked(team).await?;
        let member = detail.members.iter().find(|m| m.user_id == user_id && m.approved).ok_or(TeamError::NotFound)?;
        if fingerprint_of(member).as_deref() != Some(fingerprint) {
            return Err(TeamError::Untrusted(format!("{user_id}: keys other than the ones confirmed")));
        }
        let key_id = ring.current().id();
        let signing_key = raw32(member.signing_key.as_deref().expect("a fingerprint"), "signing_key")?;
        let message = crypto::role_message(&id, ring.epoch(), &key_id, self.me(), user_id, role, &signing_key);
        Ok(json!({
            "role": role,
            "epoch": ring.epoch(),
            "key_id": b64(&key_id),
            "signing_key": b64(&signing_key),
            "signature": b64(&crypto::sign(self.key.signing(), &message)),
        }))
    }

    async fn put_wrap(&self, team: &str, epoch: i64, k: &TeamKey, user_id: &str, recipient: &str, signing_key: &[u8; 32]) -> Result<(), TeamError> {
        let id = team_bytes(team)?;
        let key_id = k.id();
        let message = crypto::grant_message(&id, epoch, &key_id, self.me(), user_id, recipient);
        let body = json!({
            "user_id": user_id,
            "recipient": recipient,
            "wrap": b64(&k.wrap(recipient)?),
            "attestation": b64(&k.attest(&id, epoch, user_id, recipient, signing_key)),
            "key_id": b64(&key_id),
            "signature": b64(&crypto::sign(self.key.signing(), &message)),
        });
        self.client.put(&format!("/v2/teams/{team}/keys/{epoch}"), &body).await.map(|_| ())
    }

    /// Every team whose keys this device holds wrapped to an older account
    /// key of this account's: asked for a new team key first (the old
    /// account key perhaps known), then rewrapped to the current. Each team
    /// on its own: answers those that failed, to run again; the done are left
    /// alone.
    pub async fn rewrap_teams(&self) -> Result<Vec<(String, TeamError)>, TeamError> {
        let mut failed = Vec::new();
        for t in self.client.list().await?.into_iter().filter(|t| t.approved && t.team.epoch > 0) {
            let id = t.team.id;
            if let Err(e) = self.rewrap(&id).await {
                failed.push((id, e));
            }
        }
        Ok(failed)
    }

    async fn rewrap(&self, team: &str) -> Result<(), TeamError> {
        let ring = match self.keyring(team).await {
            Ok(ring) if ring.stale_own() => ring,
            // Holding no key: nothing to rewrap.
            Ok(_) | Err(TeamError::Unkeyed) => return Ok(()),
            Err(e) => return Err(e),
        };
        self.client.request_rotation(team).await?;
        let (recipient, signing_key) = (self.key.recipient(), self.key.signing_raw());
        for (epoch, k) in ring.keys() {
            match self.put_wrap(team, epoch, k, self.me(), &recipient, &signing_key).await {
                // An epoch whose data went meanwhile: nothing to read.
                Err(TeamError::Refused(r)) if r == "team_epoch_stale" => {}
                other => other?,
            }
        }
        self.refreshed(team).await;
        Ok(())
    }

    /// The keyring read again after a write homebase took: the write stands
    /// whether or not this does, so a failure here is only logged.
    async fn refreshed(&self, team: &str) {
        let _ = self.keyring(team).await;
    }

    /// An invite as [terms] say; carrying the current key when [keyed], its
    /// secret and this account's signing key in the link's fragment.
    pub async fn create_invite(&self, team: &str, terms: &InviteTerms, keyed: bool) -> Result<InviteLink, TeamError> {
        let id = team_bytes(team)?;
        let role = terms.role.as_str();
        // An admin is made by a signed promotion, never by a link.
        if role != "member" {
            return Err(TeamError::Invalid("an invite lets in members only".into()));
        }
        let mut body = json!({ "role": role, "uses": terms.uses, "days": terms.days });
        let secret = if keyed {
            let ring = self.keyring(team).await?;
            let secret = InviteSecret::generate(self.key.signing_raw());
            let recipient = secret.recipient();
            let k = ring.current();
            let key_id = k.id();
            let message = crypto::invite_message(&id, ring.epoch(), &key_id, self.me(), role, &recipient);
            body["key"] = json!({
                "epoch": ring.epoch(),
                "recipient": recipient,
                "wrap": b64(&k.wrap(&recipient)?),
                "key_id": b64(&key_id),
                "signature": b64(&crypto::sign(self.key.signing(), &message)),
            });
            Some(secret.fragment())
        } else {
            None
        };
        let made = serde_json::from_value(self.client.post(&format!("/v2/teams/{team}/invites"), &body).await?).map_err(|e| TeamError::Invalid(format!("an invite: {e}")))?;
        Ok(InviteLink { made, secret })
    }

    /// Joins by invite [token]; with its link's [secret], taking the key it
    /// carries, wrapped to this account's key.
    pub async fn join(&self, token: &str, secret: Option<&str>) -> Result<Joined, TeamError> {
        let view = self.client.invite(token).await?;
        let me = self.me();
        let body = match (secret, &view.wrap) {
            (Some(secret), Some(_)) => {
                let secret = InviteSecret::parse(secret)?;
                let (epoch, k) = verify::invite_key(&view, &secret)?;
                let team = team_bytes(&view.team_id)?;
                let recipient = self.key.recipient();
                let message = crypto::grant_message(&team, epoch, &k.id(), me, me, &recipient);
                json!({ "key": {
                    "epoch": epoch,
                    "recipient": recipient,
                    "wrap": b64(&k.wrap(&recipient)?),
                    "attestation": b64(&k.attest(&team, epoch, me, &recipient, &self.key.signing_raw())),
                    "signature": b64(&crypto::sign(self.key.signing(), &message)),
                }})
            }
            _ => json!({}),
        };
        let joined = self.client.post(&format!("/v2/teams/invites/{token}/join"), &body).await?;
        serde_json::from_value(joined).map_err(|e| TeamError::Invalid(format!("a join: {e}")))
    }

    /// After a rotation: every file of [apps] in the team's space, and its
    /// log's snapshot, sealed again under the current key, then the epoch
    /// marked migrated.
    pub async fn reencrypt(&self, team: &str, apps: &[&str]) -> Result<Reencrypted, TeamError> {
        let ring = self.keyring(team).await?;
        let held: Vec<i64> = ring.keys().map(|(e, _)| e).collect();
        let mut unreadable = Vec::new();
        for app in apps {
            let sync = SyncClient::for_team(self.client.session().clone(), team, app, ring.epoch());
            for file in sync.list().await? {
                if file.epoch == Some(ring.epoch()) {
                    continue;
                }
                if file.epoch.is_some_and(|e| !held.contains(&e)) {
                    unreadable.push(format!("{app}/{}", file.name));
                    continue;
                }
                if file.name == SNAPSHOT {
                    reseal_snapshot(&sync, &ring).await?;
                } else {
                    reseal(&sync, &ring, &file.name).await?;
                }
            }
        }
        if !unreadable.is_empty() {
            return Ok(Reencrypted::Unreadable(unreadable));
        }
        match self.client.post(&format!("/v2/teams/{team}/keys/migrated"), &json!({ "epoch": ring.epoch() })).await {
            Ok(_) => {
                self.refreshed(team).await;
                Ok(Reencrypted::Migrated)
            }
            Err(TeamError::Refused(r)) if r == "team_unmigrated" => Ok(Reencrypted::SnapshotNeeded),
            Err(TeamError::Refused(r)) if r == "team_epoch_stale" => Err(TeamError::StaleEpoch(self.keyring(team).await?.epoch())),
            Err(e) => Err(e),
        }
    }

    /// [app]'s sealed files and log in team [team].
    pub async fn space(self: &Arc<Self>, team: &str, app: &str) -> Result<TeamSpace<S, K>, TeamError> {
        let ring = self.ring(team).await?;
        Ok(TeamSpace::new(self.clone(), team, app, ring))
    }
}

/// The log's snapshot as homebase lists it.
const SNAPSHOT: &str = ".snapshot";

/// The log's snapshot sealed again under the current key, at its own seq:
/// homebase takes that once, from a newer epoch. The batches after it are
/// the app's to cover ([Reencrypted::SnapshotNeeded]).
async fn reseal_snapshot<S: Store>(sync: &SyncClient<S>, ring: &Keyring) -> Result<(), TeamError> {
    let Some((snapshot, sealed)) = sync.download_snapshot_bytes().await? else { return Ok(()) };
    sync.put_snapshot_bytes(snapshot.seq, ring.seal(&ring.open(&sealed)?)?).await?;
    Ok(())
}

/// [name] read, opened with any key held, sealed with the current one and
/// written over the version read; read again when another wrote meanwhile.
async fn reseal<S: Store>(sync: &SyncClient<S>, ring: &Keyring, name: &str) -> Result<(), TeamError> {
    loop {
        let Some((sealed, etag)) = sync.download_bytes(name).await? else { return Ok(()) };
        match sync.upload_bytes(name, ring.seal(&ring.open(&sealed)?)?, Condition::Match(etag)).await {
            Ok(_) => return Ok(()),
            Err(e) if e.kind == sync::Kind::Changed => continue,
            Err(e) => return Err(e.into()),
        }
    }
}
