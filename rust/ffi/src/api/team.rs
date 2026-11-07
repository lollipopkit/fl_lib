//! LK Cloud's teams for Dart (`fl_lkc::team`): the account key, and once it
//! is open ([LkcTeams::open]) every team's checked keys, the admin flows,
//! and each team's sealed files and log ([LkcTeamSpace]). Nothing here grants
//! or confirms on its own: the app shows the person fingerprints
//! ([LkcMember::fingerprint]) and asks ([LkcTeamErrorKind::Unconfirmed],
//! [LkcTeamErrorKind::SigningKeyChanged]).

use std::sync::{Arc, Mutex};

use flutter_rust_bridge::{BaseAsyncRuntime, DartFnFuture, frb};
use futures_util::stream::select;
use fl_lkc::Session;
use fl_lkc::sync::{Condition, Kind};
use fl_lkc::team::identity::{AccountKey, AccountKeyFile};
use fl_lkc::team::{self, InviteTerms, Reencrypted, TeamClient, TeamError, TeamLog, TeamSpace, Teams, Trust};
use tokio::sync::watch;

use crate::api::lkc::{LkcAppended, LkcBatch, LkcSession, LkcSyncEvent, LkcSyncFile};
use crate::frb_generated::{FLUTTER_RUST_BRIDGE_HANDLER, StreamSink};
use crate::lkc_bridge::{DartKeeper, DartStore, forward_events};

pub enum LkcTeamErrorKind {
    /// Homebase's `reason` in [LkcTeamError::reason].
    Refused,
    NotFound,
    Perm,
    SignedOut,
    Unreachable,
    Invalid,
    /// The LK Cloud key password does not open the account key.
    WrongPassphrase,
    Crypto,
    /// What homebase gave does not hold together.
    Untrusted,
    /// [LkcTeamError::users]' first has a signing key other than the newest
    /// pinned ([LkcTeamError::signing_key]): the person compares it and
    /// accepts it ([LkcTeamKeys::accept_signing_key]), or not.
    SigningKeyChanged,
    /// [LkcTeamError::users]' keys no key holder attested: the person
    /// compares their fingerprints, then commits again naming them.
    Unconfirmed,
    /// [LkcTeamError::users] published no key yet.
    NoRecipient,
    /// Another device replaced the account key: opened again from LK Cloud.
    AccountKeyReplaced,
    /// The team's key moved on: [LkcTeamError::epoch] now.
    StaleEpoch,
    /// Approved, holding no key yet: an admin's device grants one.
    Unkeyed,
    /// Joined after the current epoch's commit: the next is made by one of
    /// its members, or after the owner's signed promotion.
    PromotionNeeded,
    /// Epoch [LkcTeamError::epoch] starts the team's keys anew, made by its
    /// owner ([LkcTeamError::users]) who lost theirs: taken once the person
    /// accepts it ([LkcTeamKeys::accept_recovery]).
    RecoveryEpoch,
    /// A sync request of the space failed ([LkcTeamError::reason]: its kind).
    Sync,
}

impl std::fmt::Debug for LkcTeamErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Refused => "Refused",
            Self::NotFound => "NotFound",
            Self::Perm => "Perm",
            Self::SignedOut => "SignedOut",
            Self::Unreachable => "Unreachable",
            Self::Invalid => "Invalid",
            Self::WrongPassphrase => "WrongPassphrase",
            Self::Crypto => "Crypto",
            Self::Untrusted => "Untrusted",
            Self::SigningKeyChanged => "SigningKeyChanged",
            Self::Unconfirmed => "Unconfirmed",
            Self::NoRecipient => "NoRecipient",
            Self::AccountKeyReplaced => "AccountKeyReplaced",
            Self::StaleEpoch => "StaleEpoch",
            Self::Unkeyed => "Unkeyed",
            Self::PromotionNeeded => "PromotionNeeded",
            Self::RecoveryEpoch => "RecoveryEpoch",
            Self::Sync => "Sync",
        })
    }
}

#[derive(Debug)]
pub struct LkcTeamError {
    pub kind: LkcTeamErrorKind,
    pub reason: Option<String>,
    pub users: Vec<String>,
    pub signing_key: Option<String>,
    /// [signing_key]'s fingerprint to compare, when known.
    pub fingerprint: Option<String>,
    pub epoch: Option<i64>,
    pub detail: String,
}

impl From<TeamError> for LkcTeamError {
    fn from(e: TeamError) -> Self {
        use LkcTeamErrorKind as K;
        let detail = e.to_string();
        let mut out = Self { kind: K::Invalid, reason: None, users: vec![], signing_key: None, fingerprint: None, epoch: None, detail };
        out.kind = match e {
            TeamError::Refused(r) => {
                out.reason = Some(r);
                K::Refused
            }
            TeamError::NotFound => K::NotFound,
            TeamError::Perm => K::Perm,
            TeamError::SignedOut => K::SignedOut,
            TeamError::Unreachable(_) => K::Unreachable,
            TeamError::Invalid(_) => K::Invalid,
            TeamError::WrongPassphrase => K::WrongPassphrase,
            TeamError::Crypto(_) => K::Crypto,
            TeamError::Untrusted(_) => K::Untrusted,
            TeamError::SigningKeyChanged { user_id, signing_key, fingerprint } => {
                out.users = vec![user_id];
                out.signing_key = Some(signing_key);
                out.fingerprint = fingerprint;
                K::SigningKeyChanged
            }
            TeamError::Unconfirmed(users) => {
                out.users = users;
                K::Unconfirmed
            }
            TeamError::NoRecipient(users) => {
                out.users = users;
                K::NoRecipient
            }
            TeamError::AccountKeyReplaced => K::AccountKeyReplaced,
            TeamError::StaleEpoch(epoch) => {
                out.epoch = Some(epoch);
                K::StaleEpoch
            }
            TeamError::Unkeyed => K::Unkeyed,
            TeamError::PromotionNeeded => K::PromotionNeeded,
            TeamError::RecoveryEpoch { epoch, committed_by, signing_key, fingerprint } => {
                out.epoch = Some(epoch);
                out.users = vec![committed_by];
                out.signing_key = Some(signing_key);
                out.fingerprint = fingerprint;
                K::RecoveryEpoch
            }
            TeamError::Sync(kind, _) => {
                if let Kind::StaleEpoch(epoch) = kind {
                    out.epoch = Some(epoch);
                }
                out.reason = Some(format!("{kind:?}"));
                K::Sync
            }
        };
        out
    }
}

/// The account's own key, every app's: its text is what a device keeps in
/// its keychain once read.
#[frb(opaque)]
pub struct LkcAccountKey(AccountKey);

impl LkcAccountKey {
    #[frb(sync)]
    pub fn from_text(text: String) -> Result<LkcAccountKey, LkcTeamError> {
        Ok(Self(AccountKey::from_text(&text).map_err(TeamError::from)?))
    }

    #[frb(sync)]
    pub fn to_text(&self) -> String {
        self.0.to_text().to_string()
    }

    #[frb(sync)]
    pub fn user_id(&self) -> String {
        self.0.user_id().to_string()
    }

    /// What this account's members compare ([LkcMember::fingerprint]).
    #[frb(sync)]
    pub fn fingerprint(&self) -> String {
        team::crypto::fingerprint(self.0.user_id(), &self.0.recipient(), &self.0.signing_raw())
    }
}

pub struct LkcTeam {
    pub id: String,
    pub name: String,
    pub epoch: i64,
    pub migrated_epoch: i64,
    pub rotation_needed: bool,
    pub approval_required: bool,
    pub role: String,
    pub approved: bool,
    pub member_count: i64,
}

impl From<team::Membership> for LkcTeam {
    fn from(m: team::Membership) -> Self {
        Self {
            id: m.team.id,
            name: m.team.name,
            epoch: m.team.epoch,
            migrated_epoch: m.team.migrated_epoch,
            rotation_needed: m.team.rotation_needed,
            approval_required: m.team.approval_required,
            role: m.role,
            approved: m.approved,
            member_count: m.member_count,
        }
    }
}

pub struct LkcMember {
    pub user_id: String,
    pub name: String,
    pub role: String,
    pub approved: bool,
    pub keyed: bool,
    /// What the person compares with the member's own; `None` before they
    /// published their key.
    pub fingerprint: Option<String>,
    /// Their keys are attested by a holder of the current key.
    pub attested: bool,
    /// Their signing key is not the one first met.
    pub changed: bool,
    /// Base64: what [LkcTeamKeys::accept_signing_key] takes when [changed].
    pub signing_key: Option<String>,
    /// The person compared [fingerprint] with them.
    pub compared: bool,
    /// The fingerprint the person compared before, when it is not this one.
    pub previous_fingerprint: Option<String>,
}

pub struct LkcTeamStatus {
    pub name: String,
    /// This account's: `owner`, `admin` or `member`.
    pub role: String,
    pub epoch: i64,
    pub migrated: bool,
    pub rotation_needed: bool,
    /// This device's keys are wrapped to an older account key
    /// ([LkcTeamKeys::rewrap_teams]).
    pub stale_own: bool,
    /// This account may make the next epoch.
    pub may_commit: bool,
    pub members: Vec<LkcMember>,
    pub skipped_epochs: Vec<i64>,
}

pub struct LkcInviteLink {
    pub id: String,
    pub token: String,
    /// The whole link to send, its secret in the fragment when it carries one.
    pub url: String,
    /// The link's fragment (after `#`) when it carries the key.
    pub secret: Option<String>,
    pub expires_at: String,
}

pub struct LkcInviteView {
    pub team_id: String,
    pub team_name: String,
    pub approval_required: bool,
    pub keyed: bool,
}

pub struct LkcJoined {
    pub team_id: String,
    pub approved: bool,
}

pub enum LkcReencrypted {
    Migrated,
    /// [LkcReencryption::unreadable] are sealed under an epoch this device
    /// holds no key of: another admin's device re-encrypts them.
    Unreadable,
    /// The log is not yet: the app writes a snapshot up to the head
    /// ([LkcTeamSpace::put_snapshot]), then asks again.
    SnapshotNeeded,
}

pub struct LkcReencryption {
    pub outcome: LkcReencrypted,
    /// `app/name` of each file left, when [LkcReencrypted::Unreadable].
    pub unreadable: Vec<String>,
}

/// The signed-in account's teams, before its key is open.
#[frb(opaque)]
pub struct LkcTeams {
    client: Arc<Session<DartStore>>,
    files: AccountKeyFile<DartStore>,
}

impl LkcTeams {
    /// Account [user_id]'s.
    #[frb(sync)]
    pub fn new(session: &LkcSession, user_id: String) -> LkcTeams {
        Self { client: session.0.clone(), files: AccountKeyFile::new(session.0.clone(), &user_id) }
    }

    fn api(&self) -> TeamClient<DartStore> {
        TeamClient::new(self.client.clone())
    }

    /// Whether a device of the account made its key: asked for, not set.
    pub async fn has_account_key(&self) -> Result<bool, LkcTeamError> {
        Ok(self.files.exists().await?)
    }

    /// The account key opened with the LK Cloud key password; `None` before
    /// any device made one.
    pub async fn fetch_account_key(&self, passphrase: String) -> Result<Option<LkcAccountKey>, LkcTeamError> {
        Ok(self.files.fetch(&passphrase).await?.map(|(k, _)| LkcAccountKey(k)))
    }

    /// The account key, made now if no device has, and published.
    pub async fn account_key(&self, passphrase: String) -> Result<LkcAccountKey, LkcTeamError> {
        let key = self.files.load_or_create(&passphrase).await?;
        self.api().publish(&key).await?;
        Ok(LkcAccountKey(key))
    }

    /// New account keys in place of these, written and published: a device
    /// lost trust. Then open them and [LkcTeamKeys::rewrap_teams].
    pub async fn rotate_account_key(&self, passphrase: String) -> Result<LkcAccountKey, LkcTeamError> {
        let (old, etag) = self.files.fetch(&passphrase).await?.ok_or(TeamError::NotFound)?;
        let next = self.files.rotate(&old, &etag, &passphrase).await?;
        self.api().publish(&next).await?;
        Ok(LkcAccountKey(next))
    }

    pub async fn change_key_passphrase(&self, old: String, new: String) -> Result<(), LkcTeamError> {
        Ok(self.files.change_passphrase(&old, &new).await?)
    }

    pub async fn list(&self) -> Result<Vec<LkcTeam>, LkcTeamError> {
        Ok(self.api().list().await?.into_iter().map(Into::into).collect())
    }

    pub async fn create(&self, name: String) -> Result<String, LkcTeamError> {
        Ok(self.api().create(&name).await?.id)
    }

    pub async fn delete(&self, id: String) -> Result<(), LkcTeamError> {
        Ok(self.api().delete(&id).await?)
    }

    pub async fn invite(&self, token: String) -> Result<LkcInviteView, LkcTeamError> {
        let v = self.api().invite(&token).await?;
        Ok(LkcInviteView { team_id: v.team_id, team_name: v.team_name, approval_required: v.approval_required, keyed: v.wrap.is_some() })
    }

    /// [key] open for every team: [trust] as last kept (empty the first
    /// time), each change of it handed to [save] (the keychain) before use.
    pub async fn open(
        &self,
        key: &LkcAccountKey,
        trust: String,
        save: impl Fn(String) -> DartFnFuture<bool> + Send + Sync + 'static,
    ) -> Result<LkcTeamKeys, LkcTeamError> {
        let key = key.0.clone();
        let teams = Teams::new(self.api(), key, Trust::from_json(&trust)?, DartKeeper { save: Arc::new(save) });
        Ok(LkcTeamKeys(Arc::new(teams)))
    }
}

/// The account's teams with its key open.
#[frb(opaque)]
pub struct LkcTeamKeys(Arc<Teams<DartStore, DartKeeper>>);

impl LkcTeamKeys {
    pub async fn status(&self, team: String) -> Result<LkcTeamStatus, LkcTeamError> {
        let s = self.0.status(&team).await?;
        Ok(LkcTeamStatus {
            name: s.name,
            role: s.role,
            epoch: s.epoch,
            migrated: s.migrated,
            rotation_needed: s.rotation_needed,
            stale_own: s.stale_own,
            may_commit: s.may_commit,
            members: s
                .members
                .into_iter()
                .map(|m| LkcMember {
                    user_id: m.user_id,
                    name: m.name,
                    role: m.role,
                    approved: m.approved,
                    keyed: m.keyed,
                    fingerprint: m.fingerprint,
                    attested: m.attested,
                    changed: m.changed,
                    signing_key: m.signing_key,
                    compared: m.compared,
                    previous_fingerprint: m.previous_fingerprint,
                })
                .collect(),
            skipped_epochs: s.skipped_epochs,
        })
    }

    /// The team's first key; [confirmed]: the fingerprints the person
    /// compared. Answers the new epoch.
    pub async fn commit_first(&self, team: String, confirmed: Vec<String>) -> Result<i64, LkcTeamError> {
        Ok(self.0.commit_first(&team, &confirmed).await?)
    }

    /// A new key in place of the current. Answers the new epoch.
    pub async fn rotate(&self, team: String, confirmed: Vec<String>) -> Result<i64, LkcTeamError> {
        Ok(self.0.rotate(&team, &confirmed).await?)
    }

    /// The current key to [user_id], whose [fingerprint] the person compared.
    pub async fn grant(&self, team: String, user_id: String, fingerprint: String) -> Result<(), LkcTeamError> {
        Ok(self.0.grant(&team, &user_id, &fingerprint).await?)
    }

    /// Approved member [user_id], whose [fingerprint] the person compared,
    /// made [role] (`admin`, or `member` again): the owner's.
    pub async fn set_role(&self, team: String, user_id: String, role: String, fingerprint: String) -> Result<(), LkcTeamError> {
        Ok(self.0.set_role(&team, &user_id, &role, &fingerprint).await?)
    }

    /// The team handed to [user_id], whose [fingerprint] the person compared.
    pub async fn transfer(&self, team: String, user_id: String, fingerprint: String) -> Result<(), LkcTeamError> {
        Ok(self.0.transfer(&team, &user_id, &fingerprint).await?)
    }

    /// Every team whose keys are wrapped to an older account key of this
    /// account's, asked for a new key and rewrapped. Answers those that
    /// failed, to run again.
    pub async fn rewrap_teams(&self) -> Result<Vec<LkcTeamFailure>, LkcTeamError> {
        Ok(self.0.rewrap_teams().await?.into_iter().map(|(team, e)| LkcTeamFailure { team, error: e.into() }).collect())
    }

    /// The same teams under [key], the account's next (after
    /// [LkcTeams::rotate_account_key]): one trust between them.
    #[frb(sync)]
    pub fn with_key(&self, key: &LkcAccountKey) -> Result<LkcTeamKeys, LkcTeamError> {
        let key = key.0.clone();
        Ok(LkcTeamKeys(Arc::new(self.0.with_key(key)?)))
    }

    pub async fn create_invite(&self, team: String, uses: i32, days: i64, keyed: bool) -> Result<LkcInviteLink, LkcTeamError> {
        let link = self.0.create_invite(&team, &InviteTerms { uses, days }, keyed).await?;
        let url = self.0.client().invite_url(&link.made.token, link.secret.as_deref());
        Ok(LkcInviteLink { id: link.made.invite.id, token: link.made.token, url, secret: link.secret, expires_at: link.made.invite.expires_at })
    }

    /// Joins by [token]; with the link's [secret], taking the key it carries.
    pub async fn join(&self, token: String, secret: Option<String>) -> Result<LkcJoined, LkcTeamError> {
        let j = self.0.join(&token, secret.as_deref()).await?;
        Ok(LkcJoined { team_id: j.team_id, approved: j.approved })
    }

    pub async fn reencrypt(&self, team: String) -> Result<LkcReencryption, LkcTeamError> {
        let (outcome, unreadable) = match self.0.reencrypt(&team).await? {
            Reencrypted::Migrated => (LkcReencrypted::Migrated, vec![]),
            Reencrypted::Unreadable(files) => (LkcReencrypted::Unreadable, files),
            Reencrypted::SnapshotNeeded => (LkcReencrypted::SnapshotNeeded, vec![]),
        };
        Ok(LkcReencryption { outcome, unreadable })
    }

    /// [signing_key] as [user_id]'s: the person compared it.
    pub async fn accept_signing_key(&self, user_id: String, signing_key: String) -> Result<(), LkcTeamError> {
        Ok(self.0.accept_signing_key(&user_id, &signing_key).await?)
    }

    /// [fingerprint] compared with [user_id] by the person.
    pub async fn mark_compared(&self, team: String, user_id: String, fingerprint: String) -> Result<(), LkcTeamError> {
        Ok(self.0.mark_compared(&team, &user_id, &fingerprint).await?)
    }

    /// Recovery epoch [epoch] of [team] taken: the person accepted the
    /// owner's new start ([LkcTeamErrorKind::RecoveryEpoch]).
    pub async fn accept_recovery(&self, team: String, epoch: i64, user_id: String, signing_key: String) -> Result<(), LkcTeamError> {
        Ok(self.0.accept_recovery(&team, epoch, &user_id, &signing_key).await?)
    }

    /// Lets in [user_id], waiting since they joined.
    pub async fn approve(&self, team: String, user_id: String) -> Result<(), LkcTeamError> {
        Ok(self.0.approve(&team, &user_id).await?)
    }

    /// Removes [user_id]: the team then needs a new key.
    pub async fn remove_member(&self, team: String, user_id: String) -> Result<(), LkcTeamError> {
        Ok(self.0.remove_member(&team, &user_id).await?)
    }

    pub async fn leave(&self, team: String) -> Result<(), LkcTeamError> {
        Ok(self.0.leave(&team).await?)
    }

    /// Team [team] forgotten here: left, or deleted.
    pub async fn forget_team(&self, team: String) -> Result<(), LkcTeamError> {
        Ok(self.0.forget_team(&team).await?)
    }

    pub async fn space(&self, team: String, app: String) -> Result<LkcTeamSpace, LkcTeamError> {
        Ok(LkcTeamSpace { space: self.0.space(&team, &app).await?, listening: Mutex::new(None) })
    }
}

pub struct LkcTeamFailure {
    pub team: String,
    pub error: LkcTeamError,
}

/// A read of a team's log ([LkcLogRead], opened): [unreadable] the seqs of
/// batches sealed under an epoch this device holds no key of, passed.
pub struct LkcTeamLog {
    pub compacted: bool,
    pub log: Option<String>,
    pub batches: Vec<LkcBatch>,
    pub unreadable: Vec<i64>,
    pub head: i64,
    pub snapshot_seq: i64,
    pub more: bool,
}

pub struct LkcTeamFile {
    pub plain: Vec<u8>,
    pub etag: String,
}

pub struct LkcTeamSnapshot {
    pub log: String,
    pub seq: i64,
    pub plain: Vec<u8>,
}

/// One app's files and log in a team's space, sealed and opened in Rust.
#[frb(opaque)]
pub struct LkcTeamSpace {
    space: TeamSpace<DartStore, DartKeeper>,
    listening: Mutex<Option<watch::Sender<bool>>>,
}

impl LkcTeamSpace {
    pub async fn epoch(&self) -> i64 {
        self.space.ring().await.epoch()
    }

    /// The keys read and checked again: after a `team` event. Answers the
    /// epoch.
    pub async fn refresh(&self) -> Result<i64, LkcTeamError> {
        Ok(self.space.refresh().await?.epoch())
    }

    pub async fn list(&self) -> Result<Vec<LkcSyncFile>, LkcTeamError> {
        Ok(self
            .space
            .list()
            .await?
            .into_iter()
            .map(|f| LkcSyncFile { name: f.name, etag: f.etag, size: f.size, updated_at: f.updated_at, epoch: f.epoch })
            .collect())
    }

    pub async fn read(&self, name: String) -> Result<Option<LkcTeamFile>, LkcTeamError> {
        Ok(self.space.read(&name).await?.map(|(plain, etag)| LkcTeamFile { plain, etag }))
    }

    /// [plain] as [name]'s new version: if it is at [if_match], or, `None`,
    /// if there is none. Answers the new version.
    pub async fn write(&self, name: String, plain: Vec<u8>, if_match: Option<String>) -> Result<String, LkcTeamError> {
        Ok(self.space.write(&name, &plain, if_match.map_or(Condition::Absent, Condition::Match)).await?)
    }

    pub async fn delete(&self, name: String, if_match: Option<String>) -> Result<bool, LkcTeamError> {
        Ok(self.space.delete(&name, if_match.as_deref()).await?)
    }

    pub async fn append(&self, key: String, plain: Vec<u8>) -> Result<LkcAppended, LkcTeamError> {
        let a = self.space.append(&key, &plain).await?;
        Ok(LkcAppended { log: a.log, seq: a.seq, live_batches: a.live.batches, live_bytes: a.live.bytes, compact: a.compact })
    }

    /// The log's batches after [after] of [log], opened.
    pub async fn read_log(&self, after: i64, log: Option<String>, limit: Option<u32>) -> Result<LkcTeamLog, LkcTeamError> {
        Ok(match self.space.read_log(after, log.as_deref(), limit).await? {
            TeamLog::Page { log, batches, unreadable, head, snapshot_seq, more } => LkcTeamLog {
                compacted: false,
                log,
                batches: batches.into_iter().map(|b| LkcBatch { seq: b.seq, body: b.body, epoch: b.epoch }).collect(),
                unreadable,
                head,
                snapshot_seq,
                more,
            },
            TeamLog::Compacted { log, snapshot_seq } => {
                LkcTeamLog { compacted: true, log, batches: vec![], unreadable: vec![], head: snapshot_seq, snapshot_seq, more: false }
            }
        })
    }

    pub async fn put_snapshot(&self, seq: i64, plain: Vec<u8>) -> Result<String, LkcTeamError> {
        Ok(self.space.put_snapshot(seq, &plain).await?)
    }

    pub async fn snapshot(&self) -> Result<Option<LkcTeamSnapshot>, LkcTeamError> {
        Ok(self.space.snapshot().await?.map(|(s, plain)| LkcTeamSnapshot { log: s.log, seq: s.seq, plain }))
    }

    /// Other devices' writes to this space, and the team's changes
    /// ([LkcSyncEvent::team_change], then [LkcTeamSpace::refresh]), until
    /// [LkcTeamSpace::stop_listening].
    #[frb(sync)]
    pub fn listen(&self, sink: StreamSink<LkcSyncEvent>) {
        let (stop, stopped) = watch::channel(false);
        if let Some(previous) = self.listening.lock().unwrap_or_else(|e| e.into_inner()).replace(stop) {
            let _ = previous.send(true);
        }
        let sync = self.space.sync().clone();
        let events = select(sync.clone().events(), sync.team_events());
        FLUTTER_RUST_BRIDGE_HANDLER.async_runtime().spawn(forward_events(events, sink, stopped));
    }

    #[frb(sync)]
    pub fn stop_listening(&self) {
        if let Some(stop) = self.listening.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = stop.send(true);
        }
    }
}

impl Drop for LkcTeamSpace {
    fn drop(&mut self) {
        self.stop_listening();
    }
}
