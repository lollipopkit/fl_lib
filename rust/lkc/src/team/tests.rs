//! Teams end to end against a fake homebase holding what the real one holds
//! and refusing what it refuses (a commit's signature over its own members
//! and the key before, a grant's over its epoch's key id, a write under
//! another epoch), each user by their token; then homebase lying.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::crypto::{Committed, InviteSecret, NO_KEY, TeamKey};
use super::identity::AccountKey;
use super::*;
use crate::fake::{Fake, Request, Response};
use crate::session::{Session, Store, Stored};
use crate::sync::{Condition, SyncClient};
use crate::{Client, now_ms};

const TEAM: &str = "0b5b1b6e-6f7a-4c1e-9d2a-3e4f5a6b7c8d";
/// Records a page of `/keys` holds: small, so paging is exercised.
const PAGE: usize = 2;

#[derive(Clone, Default)]
struct Nowhere;

impl Store for Nowhere {
    async fn save(&self, _: Option<Stored>) -> Result<(), String> {
        Ok(())
    }
}

#[derive(Clone, Default)]
struct Kept(Arc<Mutex<String>>);

impl Keeper for Kept {
    async fn save(&self, json: String) -> Result<(), String> {
        *self.0.lock().unwrap() = json;
        Ok(())
    }
}

#[derive(Clone)]
struct M {
    role: String,
    approved: bool,
    attestation: Option<String>,
}

#[derive(Clone)]
struct W {
    recipient: String,
    wrap: String,
    signed: Option<(String, String, String)>,
}

#[derive(Default)]
struct State {
    keys: BTreeMap<String, (String, String)>,
    epoch: i64,
    migrated: i64,
    members: BTreeMap<String, M>,
    wraps: BTreeMap<(i64, String), W>,
    epochs: BTreeMap<i64, Value>,
    /// token → (role, epoch, keyed).
    invites: BTreeMap<String, (String, i64, Option<Value>)>,
    files: BTreeMap<String, (String, Vec<u8>, i64)>,
    etags: u64,
    /// The next commit loses a race to one made meanwhile.
    race: bool,
    /// Promotions by epoch.
    roles: BTreeMap<i64, Vec<Value>>,
}

fn ok(data: Value) -> Response {
    Response::json(200, json!({ "code": 0, "data": data }))
}

fn refuse(reason: &str) -> Response {
    Response::json(200, json!({ "code": 4, "msg": "Param", "reason": reason }))
}

fn perm() -> Response {
    Response::json(200, json!({ "code": 2, "msg": "No perm", "reason": "team_role" }))
}

fn raw(s: &str) -> [u8; 32] {
    unb64(s, "test").unwrap().try_into().unwrap()
}

fn member_list(s: &State) -> Value {
    Value::Array(
        s.members
            .iter()
            .map(|(u, m)| {
                let keyed = s.wraps.get(&(s.epoch, u.clone())).is_some_and(|w| s.keys.get(u).is_some_and(|k| k.0 == w.recipient));
                json!({
                    "user_id": u, "name": u, "avatar": null, "role": m.role, "approved": m.approved,
                    "joined_at": "2026-01-01T00:00:00Z", "recipient": s.keys.get(u).map(|k| &k.0),
                    "attestation": m.attestation, "keyed": keyed, "signing_key": s.keys.get(u).map(|k| &k.1),
                })
            })
            .collect(),
    )
}

fn verify_as(s: &State, user: &str, message: &[u8], sig: &str) -> bool {
    s.keys.get(user).is_some_and(|k| crypto::verify(&unb64(&k.1, "t").unwrap(), message, &unb64(sig, "t").unwrap(), "test").is_ok())
}

/// A record as homebase keeps it, of [members] (user, role, recipient,
/// signing key), signed by [by] with [signing].
fn record(epoch: i64, key_id: [u8; 32], prev: [u8; 32], by: &str, signing: &AccountKey, members: &[Committed], mac: Option<String>) -> Value {
    let team = team_bytes(TEAM).unwrap();
    let message = crypto::commit_message(&team, epoch, &key_id, &prev, by, members);
    json!({
        "epoch": epoch, "key_id": b64(&key_id), "prev_key_id": b64(&prev), "committed_by": by,
        "signing_key": signing.signing_public(), "signature": b64(&crypto::sign(signing.signing(), &message)), "commit_mac": mac,
        "members": members.iter().map(|m| json!({ "user_id": m.user_id, "role": m.role, "recipient": m.recipient, "signing_key": b64(&m.signing_key) })).collect::<Vec<_>>(),
    })
}

fn handle(st: &Mutex<State>, r: &Request) -> Response {
    let user = r.header("authorization").and_then(|a| a.strip_prefix("Bearer tok-")).unwrap_or_default().to_string();
    let mut s = st.lock().unwrap();
    let body: Value = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
    let team = team_bytes(TEAM).unwrap();
    let path = r.path().to_string();
    let base = format!("/v2/teams/{TEAM}");
    let role = s.members.get(&user).filter(|m| m.approved).map(|m| m.role.clone());
    let manages_ = role.as_deref().is_some_and(manages);
    let query = |k: &str| r.target.split_once('?').and_then(|(_, q)| q.split('&').find_map(|kv| kv.strip_prefix(&format!("{k}=")).map(str::to_string)));
    match (r.method.as_str(), path.as_str()) {
        ("GET", "/v2/keys") => {
            let k = s.keys.get(&user);
            ok(json!({ "recipient": k.map(|k| &k.0), "signing_key": k.map(|k| &k.1) }))
        }
        ("PUT", "/v2/keys") => {
            s.keys.insert(user, (body["recipient"].as_str().unwrap().into(), body["signing_key"].as_str().unwrap().into()));
            ok(Value::Null)
        }
        ("GET", "/v2/teams") => ok(json!([{
            "id": TEAM, "name": "t", "epoch": s.epoch, "migrated_epoch": s.migrated, "rotation_needed": false,
            "approval_required": false, "created_at": "2026-01-01T00:00:00Z", "role": role, "approved": role.is_some(), "member_count": s.members.len(),
        }])),
        ("GET", p) if p == base => ok(json!({
            "id": TEAM, "name": "t", "epoch": s.epoch, "migrated_epoch": s.migrated, "rotation_needed": false,
            "approval_required": false, "created_at": "2026-01-01T00:00:00Z", "role": role, "approved": true,
            "member_count": s.members.len(), "members": member_list(&s), "invites": null, "max_members": 200,
        })),
        ("GET", p) if p == format!("{base}/keys") => {
            let since: i64 = query("since").map_or(0, |v| v.parse().unwrap());
            let wraps: Vec<Value> = s
                .wraps
                .iter()
                .filter(|((_, u), _)| *u == user)
                .map(|((e, _), w)| {
                    let (by, key, sig) = w.signed.clone().map_or((None, None, None), |(a, b, c)| (Some(a), Some(b), Some(c)));
                    json!({ "epoch": e, "recipient": w.recipient, "wrap": w.wrap, "signed_by": by, "signing_key": key, "signature": sig })
                })
                .collect();
            let after: Vec<Value> = s
                .epochs
                .range(since + 1..)
                .map(|(e, v)| {
                    let mut v = v.clone();
                    v["roles"] = json!(s.roles.get(e).cloned().unwrap_or_default());
                    v
                })
                .collect();
            ok(json!({
                "epoch": s.epoch, "migrated_epoch": s.migrated, "rotation_needed": false, "commit_mac": null,
                "wraps": wraps, "epochs": after.iter().take(PAGE).collect::<Vec<_>>(), "epochs_more": after.len() > PAGE,
            }))
        }
        ("POST", p) if p == format!("{base}/keys") => {
            if !manages_ {
                return perm();
            }
            if body["epoch"].as_i64() != Some(s.epoch) || std::mem::take(&mut s.race) {
                return refuse("team_epoch_stale");
            }
            let new = s.epoch + 1;
            let prev = s.epochs.get(&s.epoch).map_or(NO_KEY, |r| raw(r["key_id"].as_str().unwrap()));
            if raw(body["prev_key_id"].as_str().unwrap()) != prev {
                return Response::json(200, json!({ "code": 3, "reason": "team_key_chain" }));
            }
            let key_id = raw(body["key_id"].as_str().unwrap());
            // Rebuilt from homebase's own members, as homebase does.
            let members: Vec<Committed> = s
                .members
                .iter()
                .filter(|(_, m)| m.approved)
                .map(|(u, m)| Committed { user_id: u.clone(), role: m.role.clone(), recipient: s.keys[u].0.clone(), signing_key: raw(&s.keys[u].1) })
                .collect();
            let wraps = body["wraps"].as_array().unwrap();
            if wraps.len() != members.len() {
                return refuse("team_key_members");
            }
            let message = crypto::commit_message(&team, new, &key_id, &prev, &user, &members);
            if !verify_as(&s, &user, &message, body["signature"].as_str().unwrap()) {
                return refuse("team_signature");
            }
            for w in wraps {
                let u = w["user_id"].as_str().unwrap().to_string();
                s.wraps.insert((new, u.clone()), W { recipient: w["recipient"].as_str().unwrap().into(), wrap: w["wrap"].as_str().unwrap().into(), signed: None });
                s.members.get_mut(&u).unwrap().attestation = w["attestation"].as_str().map(str::to_string);
            }
            let signing_key = s.keys[&user].1.clone();
            let rec = json!({
                "epoch": new, "key_id": body["key_id"], "prev_key_id": b64(&prev), "committed_by": user, "signing_key": signing_key,
                "signature": body["signature"], "commit_mac": body["commit_mac"],
                "members": members.iter().map(|m| json!({ "user_id": m.user_id, "role": m.role, "recipient": m.recipient, "signing_key": b64(&m.signing_key) })).collect::<Vec<_>>(),
            });
            s.epochs.insert(new, rec);
            if s.epoch == 0 {
                s.migrated = new;
            }
            s.epoch = new;
            ok(json!({ "epoch": new }))
        }
        ("PUT", p) if p.starts_with(&format!("{base}/keys/")) => {
            let epoch: i64 = p.rsplit('/').next().unwrap().parse().unwrap();
            let target = body["user_id"].as_str().unwrap().to_string();
            let own = target == user;
            if !own && !manages_ {
                return perm();
            }
            let kept = s.wraps.keys().any(|(e, _)| *e == epoch);
            let Some(rec) = s.epochs.get(&epoch).filter(|_| kept) else { return refuse("team_epoch_stale") };
            if rec["key_id"] != body["key_id"] {
                return refuse("team_signature");
            }
            let recipient = body["recipient"].as_str().unwrap().to_string();
            if s.keys.get(&target).map(|k| &k.0) != Some(&recipient) {
                return refuse("team_key_recipient");
            }
            if !own && s.wraps.get(&(epoch, target.clone())).is_some_and(|w| w.recipient == recipient) {
                return refuse("team_key_held");
            }
            let key_id = raw(body["key_id"].as_str().unwrap());
            let message = crypto::grant_message(&team, epoch, &key_id, &user, &target, &recipient);
            if !verify_as(&s, &user, &message, body["signature"].as_str().unwrap()) {
                return refuse("team_signature");
            }
            let signed = Some((user.clone(), s.keys[&user].1.clone(), body["signature"].as_str().unwrap().to_string()));
            s.wraps.insert((epoch, target.clone()), W { recipient, wrap: body["wrap"].as_str().unwrap().into(), signed });
            if epoch == s.epoch {
                s.members.get_mut(&target).unwrap().attestation = body["attestation"].as_str().map(str::to_string);
            }
            ok(json!({ "epoch": s.epoch }))
        }
        ("POST", p) if p == format!("{base}/keys/migrated") => {
            if s.files.values().any(|f| f.2 != s.epoch) {
                return refuse("team_unmigrated");
            }
            s.migrated = s.epoch;
            ok(json!({ "epoch": s.epoch }))
        }
        ("POST", p) if p == format!("{base}/keys/rotation") => ok(Value::Null),
        ("PUT", p) if p.starts_with(&format!("{base}/members/")) && p.ends_with("/role") => {
            if role.as_deref() != Some("owner") {
                return perm();
            }
            let target = p.trim_start_matches(&format!("{base}/members/")).trim_end_matches("/role").to_string();
            let to = body["role"].as_str().unwrap().to_string();
            if let Err(r) = promote(&mut s, &team, &user, &target, &to, &body) {
                return r;
            }
            s.members.get_mut(&target).unwrap().role = to;
            ok(Value::Null)
        }
        ("POST", p) if p == format!("{base}/transfer") => {
            if role.as_deref() != Some("owner") {
                return perm();
            }
            let target = body["user_id"].as_str().unwrap().to_string();
            if let Err(r) = promote(&mut s, &team, &user, &target, "owner", &body) {
                return r;
            }
            s.members.get_mut(&target).unwrap().role = "owner".into();
            s.members.get_mut(&user).unwrap().role = "admin".into();
            ok(Value::Null)
        }
        ("POST", p) if p == format!("{base}/invites") => {
            if !manages_ {
                return perm();
            }
            let token = format!("{:0>43}", s.invites.len());
            let keyed = (!body["key"].is_null()).then(|| {
                let mut k = body["key"].clone();
                k["signed_by"] = json!(user);
                k["signing_key"] = json!(s.keys[&user].1);
                k
            });
            let epoch = s.epoch;
            s.invites.insert(token.clone(), (body["role"].as_str().unwrap().into(), epoch, keyed.clone()));
            ok(json!({
                "id": "i", "role": body["role"], "created_by": user, "epoch": epoch, "keyed": keyed.is_some(),
                "uses_left": 1, "expires_at": "2026-01-08T00:00:00Z", "created_at": "2026-01-01T00:00:00Z", "token": token,
            }))
        }
        ("GET", p) if p.starts_with("/v2/teams/invites/") => {
            let token = p.trim_start_matches("/v2/teams/invites/");
            let Some((role, epoch, key)) = s.invites.get(token).cloned() else { return Response::json(200, json!({ "code": 3, "msg": "Not found" })) };
            let k = key.unwrap_or(Value::Null);
            ok(json!({
                "team_id": TEAM, "team_name": "t", "role": role, "epoch": epoch, "approval_required": false,
                "recipient": k["recipient"], "wrap": k["wrap"], "key_id": k["key_id"], "signed_by": k["signed_by"],
                "signing_key": k["signing_key"], "signature": k["signature"],
            }))
        }
        ("POST", p) if p.starts_with("/v2/teams/invites/") && p.ends_with("/join") => {
            let token = p.trim_start_matches("/v2/teams/invites/").trim_end_matches("/join");
            let (role, invite_epoch, keyed) = s.invites.get(token).cloned().unwrap();
            let mut m = M { role, approved: true, attestation: None };
            if let Some(k) = body.get("key") {
                let epoch = k["epoch"].as_i64().unwrap();
                let recipient = k["recipient"].as_str().unwrap().to_string();
                if keyed.is_none() || epoch != s.epoch || invite_epoch != s.epoch || s.keys.get(&user).map(|k| &k.0) != Some(&recipient) {
                    return refuse("team_key");
                }
                let key_id = raw(s.epochs[&epoch]["key_id"].as_str().unwrap());
                let message = crypto::grant_message(&team, epoch, &key_id, &user, &user, &recipient);
                if !verify_as(&s, &user, &message, k["signature"].as_str().unwrap()) {
                    return refuse("team_signature");
                }
                m.attestation = k["attestation"].as_str().map(str::to_string);
                let signed = Some((user.clone(), s.keys[&user].1.clone(), k["signature"].as_str().unwrap().to_string()));
                s.wraps.insert((epoch, user.clone()), W { recipient, wrap: k["wrap"].as_str().unwrap().into(), signed });
            }
            s.members.insert(user, m);
            ok(json!({ "team_id": TEAM, "approved": true }))
        }
        ("GET", p) if p == format!("{base}/sync/serverbox") => ok(Value::Array(
            s.files.iter().map(|(n, f)| json!({ "name": n, "etag": f.0, "size": f.1.len(), "updated_at": "2026-01-01T00:00:00Z", "epoch": f.2 })).collect(),
        )),
        ("GET", p) if p == format!("{base}/sync/serverbox/snapshot") => match s.files.get(".snapshot") {
            Some(f) => Response::status(200).header("etag", &format!("\"{}\"", f.0)).header("sync-log", "l").header("sync-seq", "5").body(f.1.clone()),
            None => Response::status(404),
        },
        ("PUT", p) if p == format!("{base}/sync/serverbox/snapshot") => {
            let epoch: i64 = r.header("x-team-epoch").unwrap().parse().unwrap();
            assert_eq!(query("seq").as_deref(), Some("5"));
            s.etags += 1;
            let etag = format!("{:032x}", s.etags);
            s.files.insert(".snapshot".into(), (etag.clone(), r.body.clone(), epoch));
            Response::status(204).header("etag", &format!("\"{etag}\""))
        }
        ("GET", p) if p.starts_with(&format!("{base}/sync/serverbox/")) => match s.files.get(p.rsplit('/').next().unwrap()) {
            Some(f) => Response::status(200).header("etag", &format!("\"{}\"", f.0)).body(f.1.clone()),
            None => Response::status(404),
        },
        ("PUT", p) if p.starts_with(&format!("{base}/sync/serverbox/")) => {
            let name = p.rsplit('/').next().unwrap().to_string();
            let epoch: i64 = r.header("x-team-epoch").unwrap().parse().unwrap();
            if epoch != s.epoch {
                return Response::json(409, json!({ "code": 4, "reason": "team_epoch_stale" })).header("x-team-epoch", &s.epoch.to_string());
            }
            let current = s.files.get(&name).map(|f| f.0.clone());
            let wanted = r.header("if-match").map(|e| e.trim_matches('"').to_string());
            if current != wanted {
                return Response::status(412);
            }
            s.etags += 1;
            let etag = format!("{:032x}", s.etags);
            s.files.insert(name, (etag.clone(), r.body.clone(), epoch));
            Response::status(204).header("etag", &format!("\"{etag}\""))
        }
        _ => Response::status(404),
    }
}

/// A promotion checked as homebase checks it, and kept with its epoch.
fn promote(s: &mut State, team: &[u8; 16], by: &str, target: &str, role: &str, body: &Value) -> Result<(), Response> {
    if s.epoch == 0 || !manages(role) {
        return Ok(());
    }
    let epoch = body["epoch"].as_i64().unwrap_or(-1);
    if epoch != s.epoch || s.epochs[&epoch]["key_id"] != body["key_id"] || s.keys[target].1 != body["signing_key"].as_str().unwrap_or_default() {
        return Err(refuse("team_signature"));
    }
    let key_id = raw(body["key_id"].as_str().unwrap());
    let message = crypto::role_message(team, epoch, &key_id, by, target, role, &raw(&s.keys[target].1));
    if !verify_as(s, by, &message, body["signature"].as_str().unwrap()) {
        return Err(refuse("team_signature"));
    }
    let grant = json!({
        "user_id": target, "role": role, "signing_key": s.keys[target].1, "signed_by": by,
        "signer_key": s.keys[by].1, "signature": body["signature"],
    });
    s.roles.entry(epoch).or_default().push(grant);
    Ok(())
}

struct Person {
    teams: Arc<Teams<Nowhere, Kept>>,
    kept: Kept,
}

async fn session(fake: &Fake, id: &str) -> Arc<Session<Nowhere>> {
    let client = Arc::new(Client::with(&fake.issuer(), "app", &fake.base).unwrap());
    let stored = Stored { access: format!("tok-{id}"), refresh: None, expires_at: now_ms() + 3_600_000, refreshing: false };
    Arc::new(Session::restore(client, Nowhere, Some(stored)).await)
}

async fn person(fake: &Fake, id: &str) -> Person {
    person_with(fake, AccountKey::generate(id), Kept::default()).await
}

async fn person_with(fake: &Fake, key: AccountKey, kept: Kept) -> Person {
    let client = TeamClient::new(session(fake, key.user_id()).await);
    client.publish(&key).await.unwrap();
    let trust = Trust::from_json(&kept.0.lock().unwrap()).unwrap();
    Person { teams: Arc::new(Teams::new(client, key, trust, kept.clone())), kept }
}

impl Person {
    fn key(&self) -> &AccountKey {
        self.teams.key()
    }

    fn fingerprint(&self) -> String {
        crypto::fingerprint(self.key().user_id(), &self.key().recipient(), &self.key().signing_raw())
    }

    fn committed(&self, role: &str) -> Committed {
        Committed { user_id: self.key().user_id().into(), role: role.into(), recipient: self.key().recipient(), signing_key: self.key().signing_raw() }
    }
}

fn terms() -> InviteTerms {
    InviteTerms { role: "member".into(), uses: 1, days: 7 }
}

fn add(state: &Mutex<State>, user: &str, role: &str) {
    state.lock().unwrap().members.insert(user.into(), M { role: role.into(), approved: true, attestation: None });
}

async fn setup() -> (Arc<Mutex<State>>, Fake, Person, Person) {
    let state = Arc::new(Mutex::new(State::default()));
    let st = state.clone();
    let fake = Fake::start(move |r| handle(&st, r)).await;
    let alice = person(&fake, "alice").await;
    let bob = person(&fake, "bob").await;
    add(&state, "alice", "owner");
    add(&state, "bob", "member");
    (state, fake, alice, bob)
}

async fn keyed(state: &Arc<Mutex<State>>, alice: &Person, bob: &Person) {
    let _ = state;
    alice.teams.commit_first(TEAM, &[bob.fingerprint()]).await.unwrap();
}

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
    assert_eq!(trust.known("alice"), [alice.key().signing_public()]);
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
    let ring1 = space.ring().await;
    state.lock().unwrap().files.insert(".snapshot".into(), ("s".into(), ring1.seal(b"log").unwrap(), 1));

    // Pages of two records: three epochs read in two.
    for _ in 0..2 {
        alice.teams.rotate(TEAM, &[]).await.unwrap();
    }
    assert_eq!(alice.teams.reencrypt(TEAM, &["serverbox"]).await.unwrap(), Reencrypted::Migrated);
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
        s.epochs.insert(2, record(2, other.id(), prev, "alice", alice.key(), &members, None));
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

    // Alice rotates and commits under her new signing key: her own device
    // takes it; bob's asks the person, then takes it once accepted.
    let alice2 = person_with(&fake, alice.key().rotated(), alice.kept.clone()).await;
    alice2.teams.rewrap_teams().await.unwrap();
    alice2.teams.rotate(TEAM, &[]).await.unwrap();
    let changed = bob2.teams.keyring(TEAM).await.err().unwrap();
    assert_eq!(changed, TeamError::SigningKeyChanged { user_id: "alice".into(), signing_key: alice2.key().signing_public() });
    bob2.teams.accept_signing_key("alice", &alice2.key().signing_public()).await.unwrap();
    assert_eq!(bob2.teams.keyring(TEAM).await.unwrap().epoch(), 2);
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
    sync.upload_bytes("x", body, Condition::Absent).await.unwrap();
    assert_eq!(state.lock().unwrap().files["x"].2, 1);
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
        s.files.insert("old".into(), ("e".into(), forged.seal(b"x").unwrap(), 1));
    }
    assert_eq!(alice.teams.reencrypt(TEAM, &["serverbox"]).await.unwrap(), Reencrypted::Unreadable(vec!["serverbox/old".into()]));
}

/// Alice signs epoch 2 with her first key, rotates, signs 3 with the next:
/// bob, who saw only epoch 1, accepts her new key and reads on; a record
/// past 3 under the key she replaced is refused.
#[tokio::test]
async fn a_replaced_signing_key_signs_nothing_after_its_successor() {
    let (state, fake, alice, bob) = setup().await;
    keyed(&state, &alice, &bob).await;
    bob.teams.keyring(TEAM).await.unwrap();
    alice.teams.rotate(TEAM, &[]).await.unwrap();
    let alice2 = person_with(&fake, alice.key().rotated(), alice.kept.clone()).await;
    alice2.teams.rewrap_teams().await.unwrap();
    alice2.teams.rotate(TEAM, &[]).await.unwrap();
    let Err(TeamError::SigningKeyChanged { signing_key, .. }) = bob.teams.keyring(TEAM).await else { panic!("a new key taken") };
    bob.teams.accept_signing_key("alice", &signing_key).await.unwrap();
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
    assert!(matches!(bob.teams.keyring(TEAM).await, Err(TeamError::Untrusted(e)) if e.contains("replaced")));
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
    let admin = InviteTerms { role: "admin".into(), ..terms() };
    assert!(matches!(alice.teams.create_invite(TEAM, &admin, true).await, Err(TeamError::Invalid(_))));
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

async fn carol_joined(state: &Arc<Mutex<State>>, fake: &Fake, alice: &Person, bob: &Person) -> Person {
    keyed(state, alice, bob).await;
    bob.teams.keyring(TEAM).await.unwrap();
    let link = alice.teams.create_invite(TEAM, &terms(), true).await.unwrap();
    let carol = person(fake, "carol").await;
    carol.teams.join(&link.made.token, link.secret.as_deref()).await.unwrap();
    carol
}

/// Carol makes epoch 2 as homebase lets her (it would, lying), signed rightly.
fn carol_commits(state: &Mutex<State>, alice: &Person, bob: &Person, carol: &Person) {
    let mut s = state.lock().unwrap();
    let prev = raw(s.epochs[&1]["key_id"].as_str().unwrap());
    let next = TeamKey::generate();
    let members = [alice.committed("owner"), bob.committed("member"), carol.committed("admin")];
    s.epochs.insert(2, record(2, next.id(), prev, "carol", carol.key(), &members, None));
    s.wraps.insert((2, "bob".into()), W { recipient: bob.key().recipient(), wrap: b64(&next.wrap(&bob.key().recipient()).unwrap()), signed: None });
    s.epoch = 2;
}

fn refused_as_unauthorized(r: Result<Arc<Keyring>, TeamError>) -> bool {
    matches!(r, Err(TeamError::Untrusted(e)) if e.contains("not managing the epoch before"))
}

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
