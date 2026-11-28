//! Promotions and ownership: what confers admin and when an epoch rotates.

use super::*;

#[tokio::test]
async fn a_promotion_unsigned_confers_nothing() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    // Homebase makes her an admin on its own word.
    state.lock().unwrap().members.get_mut("carol").unwrap().role = "admin".into();
    assert_eq!(carol.teams.rotate(TEAM, &[]).await, Err(TeamError::PromotionNeeded));
    carol_commits(&state, &alice, &bob, &carol);
    assert!(refused_as_unauthorized(bob.teams.keyring(TEAM).await));
}

#[tokio::test]
async fn a_promotion_by_one_not_authorized_confers_nothing() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    let eve = person(&fake, "eve").await;
    let key_id = raw(state.lock().unwrap().epochs[&1]["key_id"].as_str().unwrap());
    let message = crypto::role_message(&team_bytes(TEAM).unwrap(), 1, &key_id, "eve", "carol", "admin", &carol.key().signing_raw());
    let grant = json!({
        "user_id": "carol", "role": "admin", "signing_key": carol.key().signing_public(), "signed_by": "eve",
        "signer_key": eve.key().signing_public(), "signature": b64(&crypto::sign(eve.key().signing(), &message)),
    });
    state.lock().unwrap().roles.entry(1).or_default().push(grant);
    carol_commits(&state, &alice, &bob, &carol);
    assert!(refused_as_unauthorized(bob.teams.keyring(TEAM).await));
}

#[tokio::test]
async fn a_promotion_is_of_its_epoch_and_keys() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    alice.teams.set_role(TEAM, "carol", "admin", &carol.fingerprint()).await.unwrap();
    let grant = state.lock().unwrap().roles[&1][0].clone();

    // Another signing key for carol than the one alice signed.
    let mut swapped = grant.clone();
    swapped["signing_key"] = json!(AccountKey::generate("carol").signing_public());
    state.lock().unwrap().roles.insert(1, vec![swapped]);
    assert_eq!(carol.teams.rotate(TEAM, &[]).await, Err(TeamError::PromotionNeeded));

    // Epoch 1's promotion shown under epoch 2: not of its key.
    state.lock().unwrap().roles.insert(1, vec![grant.clone()]);
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let dave = person(&fake, "dave").await;
    dave.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    let mut replayed = grant;
    replayed["user_id"] = json!("dave");
    state.lock().unwrap().roles.insert(2, vec![replayed]);
    state.lock().unwrap().members.get_mut("dave").unwrap().role = "admin".into();
    assert_eq!(dave.teams.rotate(TEAM, &[]).await, Err(TeamError::PromotionNeeded));
}

#[tokio::test]
async fn before_the_first_key_the_members_are_shown_to_confirm() {
    let (_state, _fake, alice, bob) = setup().await;
    let status = alice.teams.status(TEAM).await.unwrap();
    assert_eq!(status.epoch, 0);
    assert!(status.may_commit);
    let b = status.members.iter().find(|m| m.user_id == "bob").unwrap();
    assert_eq!(b.fingerprint.as_deref(), Some(bob.fingerprint().as_str()));
    assert_eq!(alice.teams.commit_first(TEAM, &[b.fingerprint.clone().unwrap()]).await.unwrap(), 1);
}

/// What was verified of a team holds however its id is written.
#[tokio::test]
async fn a_team_is_one_whatever_its_id_looks_like() {
    let (state, _fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    bob.teams.keyring(TEAM).await.unwrap();
    let bare: String = TEAM.chars().filter(|c| *c != '-').collect();
    let trust = Trust::from_json(&bob.kept.0.lock().unwrap()).unwrap();
    assert_eq!(trust.seen(&canonical(&bare).unwrap()).unwrap().epoch, 2);
}

/// Bob, a member of epoch 1 holding its key, makes epoch 2 naming himself
/// the owner: refused, and his own device does not offer it.
#[tokio::test]
async fn a_member_cannot_make_himself_an_admin() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    assert!(!bob.teams.status(TEAM).await.unwrap().may_commit);
    state.lock().unwrap().members.get_mut("bob").unwrap().role = "admin".into();
    assert_eq!(bob.teams.rotate(TEAM, &[]).await, Err(TeamError::PromotionNeeded));
    let _ = fake;
    {
        let mut s = state.lock().unwrap();
        let prev = raw(s.epochs[&1]["key_id"].as_str().unwrap());
        let next = TeamKey::generate();
        let members = [alice.committed("member"), bob.committed("owner")];
        s.epochs.insert(2, record(2, next.id(), prev, "bob", bob.key(), &members, None));
        s.epoch = 2;
    }
    assert!(refused_as_unauthorized(alice.teams.keyring(TEAM).await));
}

/// A promotion names the key of the one promoted: one they then sign under
/// another key confers nothing further.
#[tokio::test]
async fn a_promotion_holds_the_key_it_named() {
    let (state, fake, alice, bob) = setup().await;
    let carol = carol_joined(&state, &fake, &alice, &bob).await;
    alice.teams.set_role(TEAM, "carol", "admin", &carol.fingerprint()).await.unwrap();
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let dave = person(&fake, "dave").await;
    dave.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    let key_id = raw(state.lock().unwrap().epochs[&1]["key_id"].as_str().unwrap());
    let other = AccountKey::generate("carol");
    let message = crypto::role_message(&team_bytes(TEAM).unwrap(), 1, &key_id, "carol", "dave", "admin", &dave.key().signing_raw());
    let grant = json!({
        "user_id": "dave", "role": "admin", "signing_key": dave.key().signing_public(), "signed_by": "carol",
        "signer_key": other.signing_public(), "signature": b64(&crypto::sign(other.signing(), &message)),
    });
    state.lock().unwrap().roles.entry(1).or_default().push(grant);
    state.lock().unwrap().members.get_mut("dave").unwrap().role = "admin".into();
    assert_eq!(dave.teams.rotate(TEAM, &[]).await, Err(TeamError::PromotionNeeded));
}
