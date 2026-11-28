//! Team reads and log batches, checked and never older.

use super::*;

/// What a member reads is signed by one who could write under its epoch,
/// over these bytes, and never older than what this device saw of it.
#[tokio::test]
async fn a_team_read_is_checked_signed_and_never_older() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let space = bob.teams.space(TEAM, "serverbox").await.unwrap();
    let etag = space.write("servers", b"one", Condition::Absent).await.unwrap();
    let first = state.lock().unwrap().files["servers"].clone();
    space.write("servers", b"two", Condition::Match(etag)).await.unwrap();
    assert_eq!(space.read("servers").await.unwrap().unwrap().0, b"two");

    // Homebase serves the version before.
    let second = state.lock().unwrap().files.insert("servers".into(), first).unwrap();
    assert!(matches!(space.read("servers").await, Err(TeamError::Untrusted(e)) if e.contains("older")));

    // Other bytes under the signature.
    let mut tampered = second.clone();
    tampered.1 = space.ring().await.seal(b"three").unwrap();
    state.lock().unwrap().files.insert("servers".into(), tampered);
    assert!(matches!(space.read("servers").await, Err(TeamError::Untrusted(e)) if e.contains("does not verify")));

    // Signed rightly by one not of the team.
    let eve = person(&fake, "eve").await;
    let sealed = space.ring().await.seal(b"eve's").unwrap();
    let message = crypto::sync_file_message(&format!("team:{TEAM}"), "serverbox", "servers", 1, 9, blake3::hash(&sealed).as_bytes());
    let sig = json!({ "signer": "eve", "signing_key": eve.key().signing_public(), "signature": b64(&crypto::sign(eve.key().signing(), &message)), "version": 9 });
    state.lock().unwrap().files.insert("servers".into(), ("e".into(), sealed, 1, sig));
    assert!(matches!(space.read("servers").await, Err(TeamError::Untrusted(e)) if e.contains("could not write")));

    // A version another device wrote past this one's: written after it.
    state.lock().unwrap().files.insert("servers".into(), second);
    state.lock().unwrap().versions.insert("servers".into(), 40);
    let etag = space.read("servers").await.unwrap().unwrap().1;
    space.write("servers", b"four", Condition::Match(etag)).await.unwrap();
    assert_eq!(state.lock().unwrap().versions["servers"], 41);
}

/// Carol joined by a keyed invite after the commit: her writes are hers to
/// make, and each batch of the log is checked on its own.
#[tokio::test]
async fn a_log_batch_is_checked_on_its_own() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    let mine = carol.teams.space(TEAM, "serverbox").await.unwrap();
    mine.append("0000019a3f2b1c000000000000000001", b"a").await.unwrap();
    mine.append("0000019a3f2b1c000000000000000002", b"b").await.unwrap();
    mine.append("0000019a3f2b1c000000000000000003", b"c").await.unwrap();
    let other = mine.ring().await.seal(b"x").unwrap();
    {
        let mut s = state.lock().unwrap();
        s.log[1].1 = other;
        s.log[2].3 = "0000019a3f2b1c000000000000000009".into();
    }
    let space = bob.teams.space(TEAM, "serverbox").await.unwrap();
    let TeamLog::Page { batches, unreadable, .. } = space.read_log(0, None, None).await.unwrap() else { panic!("a page") };
    assert_eq!(batches.iter().map(|b| (b.seq, b.body.as_slice())).collect::<Vec<_>>(), [(1, b"a".as_slice())]);
    assert_eq!(unreadable, [2, 3]);

    // The first shown again after: a replay.
    {
        let mut s = state.lock().unwrap();
        let mut again = s.log[0].clone();
        again.0 = 4;
        s.log.push(again);
    }
    let TeamLog::Page { batches, unreadable, .. } = space.read_log(3, Some(LOG), None).await.unwrap() else { panic!("a page") };
    assert!(batches.is_empty());
    assert_eq!(unreadable, [4]);
}

/// An owner who lost every key starts the chain anew: taken only once the
/// person accepts it.
#[tokio::test]
async fn a_recovery_epoch_waits_for_the_person() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    bob.teams.keyring(TEAM).await.unwrap();
    let next = TeamKey::generate();
    {
        let mut s = state.lock().unwrap();
        let members = [alice.committed("owner"), bob.committed("member")];
        let mut r = record(2, next.id(), NO_KEY, "alice", alice.key(), &members, None);
        r["recovery"] = json!(true);
        s.epochs.insert(2, r);
        s.wraps.insert((2, "bob".into()), W { recipient: bob.key().recipient(), wrap: b64(&next.wrap(&bob.key().recipient()).unwrap()), signed: None });
        s.epoch = 2;
    }
    // Made by one not owning the team before: refused outright.
    let by_owner = state.lock().unwrap().epochs[&2].clone();
    let mut by_bob = record(2, next.id(), NO_KEY, "bob", bob.key(), &[alice.committed("member"), bob.committed("owner")], None);
    by_bob["recovery"] = json!(true);
    state.lock().unwrap().epochs.insert(2, by_bob);
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(e)) if e.contains("not owning")));
    state.lock().unwrap().epochs.insert(2, by_owner);
    let Some(TeamError::RecoveryEpoch { epoch: 2, committed_by, signing_key, fingerprint }) = bob.teams.keyring(TEAM).await.err() else { panic!("a recovery") };
    assert_eq!((committed_by.as_str(), fingerprint), ("alice", Some(alice.fingerprint())));
    bob.teams.accept_recovery(TEAM, 2, &committed_by, &signing_key).await.unwrap();
    assert_eq!(bob.teams.keyring(TEAM).await.unwrap().epoch(), 2);
}

/// Carol's device meets bob first in epoch 1's signed record: a key
/// homebase puts in his place after (with a reset record of its own) is
/// shown changed, not taken on first sight.
#[tokio::test]
async fn a_member_is_first_met_in_a_signed_record() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    let mallory = AccountKey::generate("bob");
    {
        let mut s = state.lock().unwrap();
        let seq = s.records["bob"].len() as i64 + 1;
        let tail = raw(&s.keys["bob"].1);
        let message = crypto::user_key_message("bob", seq, &mallory.recipient(), &mallory.signing_raw(), &tail);
        let record = json!({
            "seq": seq, "recipient": mallory.recipient(), "signing_key": mallory.signing_public(), "prev_signing_key": b64(&tail),
            "self_signature": b64(&crypto::sign(mallory.signing(), &message)), "prev_signature": null, "reset": true, "legacy": false,
        });
        s.records.get_mut("bob").unwrap().push(record);
        s.keys.insert("bob".into(), (mallory.recipient(), mallory.signing_public()));
    }
    let status = carol.teams.status(TEAM).await.unwrap();
    assert!(status.members.iter().find(|m| m.user_id == "bob").unwrap().changed);
}

/// Only apps holding something under an older key are read again.
#[tokio::test]
async fn reencrypt_reads_only_apps_under_an_older_key() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let space = bob.teams.space(TEAM, "serverbox").await.unwrap();
    space.write("servers", b"hosts", Condition::Absent).await.unwrap();
    assert_eq!(alice.teams.reencrypt(TEAM).await.unwrap(), Reencrypted::Migrated);
    assert!(fake.requests(&format!("/v2/teams/{TEAM}/sync/serverbox")).is_empty());
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    assert_eq!(alice.teams.reencrypt(TEAM).await.unwrap(), Reencrypted::Migrated);
    assert_eq!(fake.requests(&format!("/v2/teams/{TEAM}/sync/serverbox")).len(), 1);
}
