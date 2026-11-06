//! Homebase's teams for real, as one person: signs in with a device code
//! (approve it in a browser), opens the account key with the LK Cloud key
//! password (`LKC_KEY_PASSPHRASE`; made and published on the first run),
//! then in the team kept for this (`LKC_E2E_TEAM`, else the account's team
//! named [`TEAM_NAME`], made if there is none) checks the keys, writes,
//! rotates, re-encrypts, writes under the replaced key and makes a keyed
//! invite (revoked again). The kept team needs `team.sync` (a benefit
//! override for `team:{id}`): the run waits for it. Also makes and deletes a
//! team of its own. Never prints a token or the password:
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

#[tokio::main]
async fn main() {
    let passphrase = std::env::var("LKC_KEY_PASSPHRASE").expect("LKC_KEY_PASSPHRASE");
    let client = Arc::new(Client::new("serverbox").expect("client"));
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
    let result = tokio::spawn(run(session.clone(), me, passphrase)).await;
    session.sign_out("the e2e run ended".into()).await;
    println!("signed out");
    if let Err(e) = result {
        std::panic::resume_unwind(e.into_panic());
    }
    println!("all passed");
}

async fn run(session: Arc<Session<Memory>>, me: String, passphrase: String) {
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
}
