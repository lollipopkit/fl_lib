//! Homebase's teams for real, as one person: signs in with a device code
//! (approve it in a browser), opens the account key with the LK Cloud key
//! password (`LKC_KEY_PASSPHRASE`; made and published on the first run),
//! then in the team kept for this (`LKC_E2E_TEAM`, else the account's team
//! named [`TEAM_NAME`], made if there is none) checks the keys, writes,
//! rotates, re-encrypts, writes under the replaced key and makes a keyed
//! invite (revoked again). The kept team needs `team.sync` (a benefit
//! override for `team:{id}`): the run waits for it. Also makes and deletes a
//! team of its own. With `LKC_KEY_PASSPHRASE_2`, a second account (signed in
//! the same way) joins by a keyed invite and is promoted, rotates, is handed
//! the team and hands it back, then is demoted and removed. With
//! `LKC_E2E_RECREATE` set, the kept team is deleted and made anew first.
//! Never prints a
//! token or a password:
//! `LKC_KEY_PASSPHRASE=$(op read op://Dev/lkc-key-password/password) cargo run -p fl_lkc --example team_e2e` (from `rust/`).

use std::sync::Arc;
use std::time::Duration;

use fl_lkc::sync::{Condition, Kind};
use fl_lkc::team::identity::AccountKeyFile;
use fl_lkc::team::{InviteTerms, Keeper, Reencrypted, TeamClient, TeamError, Teams, Trust};
use fl_lkc::{Client, DevicePoll, Failure, Session, Store, Stored};

struct Memory;

impl Store for Memory {
    async fn save(&self, _: Option<Stored>) -> Result<(), String> {
        Ok(())
    }
}

/// Kept in memory: each run starts from the first record again.
struct Forget;

impl Keeper for Forget {
    async fn save(&self, _: String) -> Result<(), String> {
        Ok(())
    }
}

const APP: &str = "fl-lkc-e2e";
const TEAM_NAME: &str = "lkc-e2e";
/// How long the run waits for the kept team's `team.sync`.
const SYNC_WAIT: Duration = Duration::from_secs(600);

/// A session of its own, signed in with a device code.
async fn signed_in(who: &str) -> (Arc<Session<Memory>>, String) {
    let client = Arc::new(Client::new("serverbox").expect("client"));
    println!("Sign in as {who}:");
    let mut device = client.start_device().await.expect("device code");
    println!("Open {}", device.verification_uri_complete.as_deref().unwrap_or(&device.verification_uri));
    println!("Code: {}", device.user_code);
    let tokens = loop {
        tokio::time::sleep(Duration::from_secs(device.interval_secs)).await;
        match client.poll_device(&device).await {
            Ok(DevicePoll::Pending) => {}
            Ok(DevicePoll::SlowDown(secs)) => device.interval_secs = secs,
            Ok(DevicePoll::Done(tokens)) => break tokens,
            Err(e) if e.failure == Failure::Unreachable => eprintln!("retrying: {e}"),
            Err(e) => panic!("poll: {e}"),
        }
    };
    let me = client.user(&tokens.access).await.expect("user").id;
    let session = Arc::new(Session::restore(client, Memory, None).await);
    session.sign_in(tokens).await.expect("session");
    (session, me)
}

#[tokio::main]
async fn main() {
    let passphrase = std::env::var("LKC_KEY_PASSPHRASE").expect("LKC_KEY_PASSPHRASE");
    let second = std::env::var("LKC_KEY_PASSPHRASE_2").ok();
    let (session, me) = signed_in("the first account").await;
    let result = tokio::spawn(run(session.clone(), me, passphrase, second)).await;
    session.sign_out("the e2e run ended".into()).await;
    println!("signed out");
    if let Err(e) = result {
        std::panic::resume_unwind(e.into_panic());
    }
    println!("all passed");
}

async fn run(session: Arc<Session<Memory>>, me: String, passphrase: String, second: Option<String>) {
    let api = TeamClient::new(session.clone());
    let throwaway = api.create(&format!("lkc-e2e-tmp-{}", fl_lkc::now_ms())).await.expect("create a team").id;
    api.delete(&throwaway).await.expect("delete it");
    println!("a team made and deleted");

    let key = AccountKeyFile::new(session.clone(), &me).load_or_create(&passphrase).await.expect("the account key");
    api.publish(&key).await.expect("publish it");
    println!("account key open and published");

    let team = match std::env::var("LKC_E2E_TEAM") {
        Ok(id) => id,
        Err(_) => match api.list().await.unwrap().into_iter().find(|t| t.team.name == TEAM_NAME && t.role == "owner") {
            // `LKC_E2E_RECREATE`: one homebase or this client can no longer
            // open, deleted and made anew (its overrides then moved to it).
            Some(t) if std::env::var("LKC_E2E_RECREATE").is_ok() => {
                api.delete(&t.team.id).await.expect("delete the kept team");
                println!("deleted the kept team {}", t.team.id);
                api.create(TEAM_NAME).await.expect("the kept team").id
            }
            Some(t) => t.team.id,
            None => api.create(TEAM_NAME).await.expect("the kept team").id,
        },
    };
    println!("team {team}");
    let teams = Arc::new(Teams::new(api, key, Trust::default(), Forget));
    if teams.status(&team).await.expect("status").epoch == 0 {
        assert_eq!(teams.commit_first(&team, &[]).await.expect("first key"), 1);
    }
    let space = teams.space(&team, APP).await.expect("the space");
    println!("keys checked, epoch {}", space.ring().await.epoch());

    let started = std::time::Instant::now();
    let etag = loop {
        let current = space.read("f").await.expect("a read").map(|(_, e)| e);
        let condition = current.map_or(Condition::Absent, Condition::Match);
        match space.write("f", b"team e2e", condition).await {
            Ok(etag) => break etag,
            Err(TeamError::Sync(Kind::Refused(r), _)) if r == "team_sync_unavailable" && started.elapsed() < SYNC_WAIT => {
                if started.elapsed() < Duration::from_secs(10) {
                    println!("waiting for team.sync on team:{team}");
                }
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
            Err(e) => panic!("a team write: {e}"),
        }
    };
    let before = space.ring().await.epoch();
    println!("written under epoch {before}");

    assert_eq!(teams.rotate(&team, &[]).await.expect("rotate"), before + 1);
    assert_eq!(teams.reencrypt(&team, &[APP]).await.expect("re-encrypt"), Reencrypted::Migrated);
    // The space still names the epoch before: refused, sealed again, sent again.
    let (plain, etag2) = space.read("f").await.unwrap().expect("the file");
    assert_eq!(plain, b"team e2e");
    assert_ne!(etag2, etag);
    space.write("f", b"again", Condition::Match(etag2)).await.expect("a write after the rotation");
    assert_eq!(space.ring().await.epoch(), before + 1);
    assert!(space.list().await.unwrap().iter().all(|f| f.epoch == Some(before + 1)));
    println!("rotated, re-encrypted, migrated, written under epoch {}", before + 1);

    let terms = InviteTerms { role: "member".into(), uses: 1, days: 1 };
    let link = teams.create_invite(&team, &terms, true).await.expect("a keyed invite");
    let view = teams.client().invite(&link.made.token).await.expect("the invite");
    assert!(view.wrap.is_some() && view.signature.is_some());
    teams.client().revoke_invite(&team, &link.made.invite.id).await.expect("revoke it");
    println!("keyed invite made and revoked");
    let status = teams.status(&team).await.expect("status");
    assert!(status.migrated && !status.stale_own && status.may_commit);

    if let Some(passphrase) = second {
        roles(&teams, &team, passphrase).await;
    }
}

/// A second account joins, is promoted, rotates, is handed the team and
/// hands it back, then is demoted and removed.
async fn roles(teams: &Arc<Teams<Memory, Forget>>, team: &str, passphrase: String) {
    let (session, other) = signed_in("the second account").await;
    let (teams, team, signed) = (teams.clone(), team.to_string(), session.clone());
    let result = async move {
        let (session, team) = (signed, team.as_str());
        let key = AccountKeyFile::new(session.clone(), &other).load_or_create(&passphrase).await.expect("its account key");
        let api = TeamClient::new(session.clone());
        api.publish(&key).await.expect("publish it");
        let fingerprint = fl_lkc::team::crypto::fingerprint(&other, &key.recipient(), &key.signing_raw());
        let them = Arc::new(Teams::new(api, key, Trust::default(), Forget));

        let terms = InviteTerms { role: "member".into(), uses: 1, days: 1 };
        let link = teams.create_invite(team, &terms, true).await.expect("a keyed invite");
        them.join(&link.made.token, link.secret.as_deref()).await.expect("join");
        let seen = teams.status(team).await.expect("status");
        let m = seen.members.iter().find(|m| m.user_id == other).expect("the second account a member");
        assert_eq!(m.fingerprint.as_deref(), Some(fingerprint.as_str()), "fingerprints agree");
        assert!(!them.status(team).await.expect("its status").may_commit);
        assert_eq!(them.rotate(team, &[]).await, Err(TeamError::PromotionNeeded));
        println!("joined by a keyed invite; may not commit yet");

        teams.set_role(team, &other, "admin", &fingerprint).await.expect("promote");
        let epoch = them.rotate(team, &[]).await.expect("its rotation");
        assert_eq!(teams.keyring(team).await.expect("checked here").epoch(), epoch);
        println!("promoted, rotated to epoch {epoch}, checked by the first account");

        let first = teams.key();
        let mine = fl_lkc::team::crypto::fingerprint(first.user_id(), &first.recipient(), &first.signing_raw());
        teams.transfer(team, &other, &fingerprint).await.expect("hand the team over");
        them.transfer(team, first.user_id(), &mine).await.expect("hand it back");
        println!("handed over and back");

        teams.set_role(team, &other, "member", "").await.expect("demote");
        teams.client().remove_member(team, &other).await.expect("remove");
        let epoch = teams.rotate(team, &[]).await.expect("rotate after removing");
        assert_eq!(teams.reencrypt(team, &[APP]).await.expect("re-encrypt"), Reencrypted::Migrated);
        println!("demoted, removed, rotated to epoch {epoch}");
    };
    let result = tokio::spawn(result).await;
    session.sign_out("the e2e run ended".into()).await;
    if let Err(e) = result {
        std::panic::resume_unwind(e.into_panic());
    }
}
