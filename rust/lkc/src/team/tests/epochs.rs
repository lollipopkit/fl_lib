//! Team keys and epochs: the first key, invites, rotation and what is refused.

use super::*;

#[tokio::test]
async fn the_first_key_needs_each_member_confirmed() {
    let (_, _fake, alice, bob) = setup().await;
    let err = alice.teams.commit_first(TEAM, &[]).await.unwrap_err();
    assert_eq!(err, TeamError::Unconfirmed(vec!["bob".into()]));
    // A fingerprint of other keys confirms nothing.
    let other = crypto::fingerprint("bob", &bob.key().recipient(), &[9; 32]);
    assert!(matches!(alice.teams.commit_first(TEAM, &[other]).await, Err(TeamError::Unconfirmed(_))));
    assert_eq!(alice.teams.commit_first(TEAM, &[bob.fingerprint()]).await.unwrap(), 1);
    assert_eq!(bob.teams.keyring(TEAM).await.unwrap().epoch(), 1);
    // What was verified is kept before it is used.
    let trust = Trust::from_json(&bob.kept.0.lock().unwrap()).unwrap();
    assert_eq!(trust.seen(TEAM).unwrap().epoch, 1);
    assert_eq!(trust.pinned("alice").unwrap().signing_key, alice.key().signing_public());
}

#[tokio::test]
async fn members_join_by_invite_and_grant() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let ring = alice.teams.keyring(TEAM).await.unwrap();

    // A keyed invite: carol takes the key from the link.
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let carol = person(&fake, "carol").await;
    carol.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    assert_eq!(carol.teams.keyring(TEAM).await.unwrap().current().id(), ring.current().id());

    // A link naming another inviter's key, or another secret, opens nothing.
    let eve = person(&fake, "eve").await;
    let link2 = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let forged = InviteSecret::generate([7; 32]).fragment();
    assert!(matches!(eve.teams.join(&link2.made.token, Some(&forged)).await, Err(TeamError::Untrusted(_))));
    let wrong_signer = InviteSecret::generate(eve.key().signing_raw()).fragment();
    assert!(matches!(eve.teams.join(&link2.made.token, Some(&wrong_signer)).await, Err(TeamError::Untrusted(_))));

    // An invite without the key: dave waits for an admin's grant, of the
    // keys the person saw.
    let plain = alice.teams.create_invite(TEAM, &terms(), false).await.unwrap();
    let dave = person(&fake, "dave").await;
    dave.teams.join(&plain.made.token, None).await.unwrap();
    assert!(dave.teams.keyring(TEAM).await.is_err());
    let status = alice.teams.status(TEAM).await.unwrap();
    let d = status.members.iter().find(|m| m.user_id == "dave").unwrap();
    assert!(!d.keyed && d.fingerprint.as_deref() == Some(dave.fingerprint().as_str()));
    assert!(matches!(alice.teams.grant(TEAM, "dave", &alice.fingerprint()).await, Err(TeamError::Untrusted(_))));
    alice.teams.grant(TEAM, "dave", &dave.fingerprint()).await.unwrap();
    assert_eq!(dave.teams.keyring(TEAM).await.unwrap().current().id(), ring.current().id());
    // A member cannot grant, nor invite.
    assert_eq!(bob.teams.grant(TEAM, "dave", &dave.fingerprint()).await, Err(TeamError::Perm));
    assert_eq!(bob.teams.create_invite(TEAM, &terms(), false).await.unwrap_err(), TeamError::Perm);
}

#[tokio::test]
async fn rotation_reencrypts_the_space_and_writes_follow_it() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let space = bob.teams.space(TEAM, "serverbox").await.unwrap();
    space.write("servers", b"hosts", Condition::Absent).await.unwrap();
    space.put_snapshot(5, b"log").await.unwrap();
    let ring1 = space.ring().await;

    // Pages of two records: three epochs read in two.
    for _ in 0..2 {
        alice.teams.rotate(TEAM, &[]).await.unwrap();
    }
    assert_eq!(alice.teams.reencrypt(TEAM).await.unwrap(), Reencrypted::Migrated);
    let (plain, etag) = space.read("servers").await.unwrap().unwrap();
    assert_eq!(plain, b"hosts");
    // Bob's space still names epoch 1: refused, sealed again, sent again.
    space.write("servers", b"more", Condition::Match(etag)).await.unwrap();
    let ring3 = space.ring().await;
    assert_eq!(ring3.epoch(), 3);
    let s = state.lock().unwrap();
    assert_eq!(s.files["servers"].2, 3);
    assert!(ring1.open(&s.files["servers"].1).is_err());
    assert_eq!(s.files[".snapshot"].2, 3);
    assert_eq!(ring3.open(&s.files[".snapshot"].1).unwrap(), b"log");
}

#[tokio::test]
async fn a_commit_that_loses_a_race_is_told_the_epoch() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    state.lock().unwrap().race = true;
    assert_eq!(alice.teams.rotate(TEAM, &[]).await, Err(TeamError::StaleEpoch(1)));
    assert_eq!(alice.teams.rotate(TEAM, &[]).await, Ok(2));
}

#[tokio::test]
async fn forged_key_material_is_refused() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    bob.teams.keyring(TEAM).await.unwrap();
    let good = state.lock().unwrap().epochs[&1].clone();

    // A key in bob's wrap other than the one signed.
    let forged = TeamKey::generate();
    let real_wrap = state.lock().unwrap().wraps[&(1, "bob".to_string())].wrap.clone();
    state.lock().unwrap().wraps.get_mut(&(1, "bob".to_string())).unwrap().wrap = b64(&forged.wrap(&bob.key().recipient()).unwrap());
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(_))));
    state.lock().unwrap().wraps.get_mut(&(1, "bob".to_string())).unwrap().wrap = real_wrap;

    // A record re-signed by one not managing the team.
    let key_id = raw(good["key_id"].as_str().unwrap());
    let members = [alice.committed("owner"), bob.committed("member")];
    let by_bob = record(1, key_id, NO_KEY, "bob", bob.key(), &members, None);
    state.lock().unwrap().epochs.insert(1, by_bob);
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(_))));

    // A record whose signature does not verify.
    let mut tampered = good.clone();
    tampered["members"][1]["recipient"] = json!(TeamKey::generate().recipient());
    state.lock().unwrap().epochs.insert(1, tampered);
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Crypto(_))));

    // Alice's signing key swapped for another homebase holds: not the one
    // pinned, so the person is asked.
    let mallory = AccountKey::generate("alice");
    let mut swapped_members = members.clone();
    swapped_members[0].signing_key = mallory.signing_raw();
    state.lock().unwrap().epochs.insert(1, record(1, key_id, NO_KEY, "alice", &mallory, &swapped_members, None));
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::SigningKeyChanged { .. })));

    // An attestation not under the key: that member is homebase's word alone.
    state.lock().unwrap().epochs.insert(1, good);
    state.lock().unwrap().members.get_mut("alice").unwrap().attestation = Some(b64(&[0; 32]));
    let status = bob.teams.status(TEAM).await.unwrap();
    assert!(!status.members.iter().find(|m| m.user_id == "alice").unwrap().attested);
    let _ = fake;
}

/// Eve, an admin removed, keeps the key she held and her signing key; with
/// homebase's help she makes the next epoch, wrapping a key she knows.
#[tokio::test]
async fn a_removed_admin_cannot_make_the_next_epoch() {
    let (state, fake, alice, bob) = setup().await;
    let eve = person(&fake, "eve").await;
    add(&state, "eve", "admin");
    alice.teams.commit_first(TEAM, &[bob.fingerprint(), eve.fingerprint()]).await.unwrap();
    bob.teams.keyring(TEAM).await.unwrap();
    state.lock().unwrap().members.remove("eve");
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    bob.teams.keyring(TEAM).await.unwrap();

    let prev = raw(state.lock().unwrap().epochs[&2]["key_id"].as_str().unwrap());
    let hers = TeamKey::generate();
    let members = [alice.committed("owner"), bob.committed("member"), eve.committed("admin")];
    {
        let mut s = state.lock().unwrap();
        s.epochs.insert(3, record(3, hers.id(), prev, "eve", eve.key(), &members, None));
        s.wraps.insert((3, "bob".into()), W { recipient: bob.key().recipient(), wrap: b64(&hers.wrap(&bob.key().recipient()).unwrap()), signed: None });
        s.epoch = 3;
    }
    let err = bob.teams.keyring(TEAM).await.err().unwrap();
    assert!(matches!(&err, TeamError::Untrusted(e) if e.contains("not managing the epoch before")), "{err:?}");
}

#[tokio::test]
async fn an_epoch_shown_lower_or_with_another_key_is_refused() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    bob.teams.keyring(TEAM).await.unwrap();

    // Epoch 1 again, as if 2 never happened.
    let two = state.lock().unwrap().epochs.remove(&2).unwrap();
    state.lock().unwrap().epoch = 1;
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(e)) if e.contains("below the last verified")));

    // Epoch 2 again, of another key, signed rightly by alice.
    let prev = raw(state.lock().unwrap().epochs[&1]["key_id"].as_str().unwrap());
    let other = TeamKey::generate();
    let members = [alice.committed("owner"), bob.committed("member")];
    {
        let mut s = state.lock().unwrap();
        s.epochs.insert(2, record(2, other.id(), prev, "alice", alice.key(), &members, Some(b64(&[0; 32]))));
        s.wraps.insert((2, "bob".into()), W { recipient: bob.key().recipient(), wrap: b64(&other.wrap(&bob.key().recipient()).unwrap()), signed: None });
        s.epoch = 2;
    }
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(e)) if e.contains("another key")));
    let _ = two;
}

#[tokio::test]
async fn an_account_key_rotation_keeps_its_teams() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    bob.teams.keyring(TEAM).await.unwrap();

    // Bob rotates on one device: his old wraps still open, rewrapped.
    let rotated = bob.key().rotated();
    let old_text = bob.key().to_text();
    let bob2 = person_with(&fake, rotated, bob.kept.clone()).await;
    assert!(bob2.teams.keyring(TEAM).await.unwrap().stale_own());
    bob2.teams.rewrap_teams().await.unwrap();
    assert!(!bob2.teams.status(TEAM).await.unwrap().stale_own);
    // His other device, still on the old key, is told.
    let stale = AccountKey::from_text(&old_text).unwrap();
    let client = TeamClient::new(session(&fake, "bob").await);
    let other = Teams::new(client, stale, Trust::default(), Kept::default());
    assert_eq!(other.keyring(TEAM).await.err(), Some(TeamError::AccountKeyReplaced));

    // Alice rotates and commits under her new signing key, which her old
    // one signed: bob's device follows it on its own.
    let alice2 = person_with(&fake, alice.key().rotated(), alice.kept.clone()).await;
    alice2.teams.rewrap_teams().await.unwrap();
    alice2.teams.rotate(TEAM, &[]).await.unwrap();
    assert_eq!(bob2.teams.keyring(TEAM).await.unwrap().epoch(), 2);

    // A key her old one never signed (a reset) commits nothing: only a
    // recovery the person accepts starts anew.
    let reset = person_with(&fake, AccountKey::generate("alice"), Kept::default()).await;
    {
        let mut st = state.lock().unwrap();
        let prev = raw(st.epochs[&2]["key_id"].as_str().unwrap());
        let members = [reset.committed("owner"), bob2.committed("member")];
        st.epochs.insert(3, record(3, TeamKey::generate().id(), prev, "alice", reset.key(), &members, Some(b64(&[0; 32]))));
        st.epoch = 3;
    }
    assert!(refused_as_unauthorized(bob2.teams.keyring(TEAM).await));
}

#[tokio::test]
async fn an_earlier_epoch_that_does_not_check_is_left_out() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    let forged = TeamKey::generate();
    state.lock().unwrap().wraps.get_mut(&(1, "bob".to_string())).unwrap().wrap = b64(&forged.wrap(&bob.key().recipient()).unwrap());
    let status = bob.teams.status(TEAM).await.unwrap();
    assert_eq!((status.epoch, status.skipped_epochs), (2, vec![1]));
}

#[tokio::test]
async fn a_stale_epoch_names_the_current() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let sync = SyncClient::for_team(alice.teams.client().session().clone(), TEAM, "serverbox", 0);
    let body = b"age-encryption.org/v1\n".to_vec();
    let err = sync.upload_bytes("x", body.clone(), Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, sync::Kind::StaleEpoch(1));
    sync.set_epoch(1);
    // A team's write is signed, or refused.
    let err = sync.upload_bytes("x", body, Condition::Absent).await.unwrap_err();
    assert_eq!(err.kind, sync::Kind::Refused("sync_signature".into()));
    assert!(!state.lock().unwrap().files.contains_key("x"));
    assert!(fake.requests(&format!("/v2/teams/{TEAM}/sync/serverbox/x")).iter().all(|r| r.header("x-team-epoch").is_some()));
}

#[tokio::test]
async fn a_member_awaiting_a_grant_is_told_so_and_rewraps_nothing() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let plain = alice.teams.create_invite(TEAM, &terms(), false).await.unwrap();
    let dave = person(&fake, "dave").await;
    dave.teams.join(&plain.made.token, None).await.unwrap();
    assert_eq!(dave.teams.keyring(TEAM).await.err(), Some(TeamError::Unkeyed));
    dave.teams.rewrap_teams().await.unwrap();
}

#[tokio::test]
async fn a_file_of_an_epoch_not_held_is_reported() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    let forged = TeamKey::generate();
    {
        let mut s = state.lock().unwrap();
        s.wraps.get_mut(&(1, "alice".to_string())).unwrap().wrap = b64(&forged.wrap(&alice.key().recipient()).unwrap());
        s.files.insert("old".into(), ("e".into(), forged.seal(b"x").unwrap(), 1, Value::Null));
    }
    assert_eq!(alice.teams.reencrypt(TEAM).await.unwrap(), Reencrypted::Unreadable(vec!["serverbox/old".into()]));
}

/// Alice signs epoch 2 with her first key, rotates, signs 3 with the next:
/// bob, who saw only epoch 1, follows her chain and reads on; a record past
/// 3 under the key she replaced is refused.
#[tokio::test]
async fn a_replaced_signing_key_signs_nothing_after_its_successor() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    bob.teams.keyring(TEAM).await.unwrap();
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    let alice2 = person_with(&fake, alice.key().rotated(), alice.kept.clone()).await;
    alice2.teams.rewrap_teams().await.unwrap();
    alice2.teams.rotate(TEAM, &[]).await.unwrap();
    // Her old key signed the new one: followed without asking.
    assert_eq!(bob.teams.keyring(TEAM).await.unwrap().epoch(), 3);

    let prev = raw(state.lock().unwrap().epochs[&3]["key_id"].as_str().unwrap());
    let next = TeamKey::generate();
    let members = [alice.committed("owner"), bob.committed("member")];
    {
        let mut s = state.lock().unwrap();
        s.epochs.insert(4, record(4, next.id(), prev, "alice", alice.key(), &members, None));
        s.wraps.insert((4, "bob".into()), W { recipient: bob.key().recipient(), wrap: b64(&next.wrap(&bob.key().recipient()).unwrap()), signed: None });
        s.epoch = 4;
    }
    assert!(refused_as_unauthorized(bob.teams.keyring(TEAM).await));
}

/// Carol joins by a keyed invite after epoch 1's commit; alice promotes her:
/// her rotation checks on bob's device.
#[tokio::test]
async fn a_member_promoted_mid_epoch_rotates() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let carol = person(&fake, "carol").await;
    carol.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    // Not an admin yet: an invite never makes one.
    assert!(matches!(alice.teams.set_role(TEAM, "carol", "admin", &bob.fingerprint()).await, Err(TeamError::Untrusted(_))));
    alice.teams.set_role(TEAM, "carol", "admin", &carol.fingerprint()).await.unwrap();
    assert_eq!(carol.teams.rotate(TEAM, &[]).await.unwrap(), 2);
    assert_eq!(bob.teams.keyring(TEAM).await.unwrap().epoch(), 2);
}

#[tokio::test]
async fn ownership_transferred_mid_epoch_rotates() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let carol = person(&fake, "carol").await;
    carol.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    alice.teams.transfer(TEAM, "carol", &carol.fingerprint()).await.unwrap();
    state.lock().unwrap().members.remove("alice");
    assert_eq!(carol.teams.rotate(TEAM, &[]).await.unwrap(), 2);
    assert_eq!(bob.teams.keyring(TEAM).await.unwrap().epoch(), 2);
}
