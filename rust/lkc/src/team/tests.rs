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
const LOG: &str = "6f1c0000-0000-4000-8000-000000000001";

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
    /// token → (epoch, keyed).
    invites: BTreeMap<String, (i64, Option<Value>)>,
    /// name → (etag, body, epoch, signature as listed).
    files: BTreeMap<String, (String, Vec<u8>, i64, Value)>,
    /// Each name's highest version.
    versions: BTreeMap<String, i64>,
    /// Each user's key records.
    records: BTreeMap<String, Vec<Value>>,
    /// Who received an epoch's key after its commit.
    joins: BTreeMap<i64, Vec<Value>>,
    /// (seq, body, epoch, idempotency key, signature).
    log: Vec<(i64, Vec<u8>, i64, String, Value)>,
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
            let records = s.records.get(&user).cloned().unwrap_or_default();
            let head = records.last();
            ok(json!({
                "recipient": k.map(|k| &k.0), "signing_key": k.map(|k| &k.1),
                "seq": head.map_or(0, |h| h["seq"].as_i64().unwrap()), "reset": head.is_some_and(|h| h["reset"] == true),
                "next_seq": records.len() + 1, "prev_signing_key": k.map(|k| &k.1),
            }))
        }
        ("PUT", "/v2/keys") => match put_key(&mut s, &user, &body) {
            Ok(()) => ok(Value::Null),
            Err(r) => r,
        },
        ("GET", p) if p.starts_with("/v2/keys/") && p.ends_with("/records") => {
            let of = p.trim_start_matches("/v2/keys/").trim_end_matches("/records");
            let since: i64 = query("since").map_or(0, |v| v.parse().unwrap());
            let records: Vec<Value> = s.records.get(of).cloned().unwrap_or_default().into_iter().filter(|r| r["seq"].as_i64().unwrap() > since).collect();
            ok(json!({ "records": records, "more": false }))
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
                    v["joins"] = json!(s.joins.get(e).cloned().unwrap_or_default());
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
            if s.epoch > 0 && body["commit_mac"].as_str().is_none() {
                return refuse("team_commit_mac");
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
            let target_key = s.keys[&target].1.clone();
            let listed = s.epochs[&epoch]["members"].as_array().unwrap().iter().any(|m| m["user_id"] == json!(target) && m["signing_key"] == json!(target_key));
            if !listed {
                let join = json!({
                    "user_id": target, "recipient": recipient, "signing_key": target_key, "via": "grant", "signed_by": user,
                    "signer_key": s.keys[&user].1, "signature": body["signature"], "invite": null,
                });
                s.joins.entry(epoch).or_default().retain(|j| j["user_id"] != json!(target));
                s.joins.entry(epoch).or_default().push(join);
            }
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
            assert!(body.get("role").is_none());
            s.invites.insert(token.clone(), (epoch, keyed.clone()));
            ok(json!({
                "id": "i", "created_by": user, "epoch": epoch, "keyed": keyed.is_some(),
                "uses_left": 1, "expires_at": "2026-01-08T00:00:00Z", "created_at": "2026-01-01T00:00:00Z", "token": token,
            }))
        }
        ("GET", p) if p.starts_with("/v2/teams/invites/") => {
            let token = p.trim_start_matches("/v2/teams/invites/");
            let Some((epoch, key)) = s.invites.get(token).cloned() else { return Response::json(200, json!({ "code": 3, "msg": "Not found" })) };
            let k = key.unwrap_or(Value::Null);
            ok(json!({
                "team_id": TEAM, "team_name": "t", "epoch": epoch, "approval_required": false,
                "recipient": k["recipient"], "wrap": k["wrap"], "key_id": k["key_id"], "signed_by": k["signed_by"],
                "signing_key": k["signing_key"], "signature": k["signature"],
            }))
        }
        ("POST", p) if p.starts_with("/v2/teams/invites/") && p.ends_with("/join") => {
            let token = p.trim_start_matches("/v2/teams/invites/").trim_end_matches("/join");
            let (invite_epoch, keyed) = s.invites.get(token).cloned().unwrap();
            let mut m = M { role: "member".into(), approved: true, attestation: None };
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
                let inv = keyed.unwrap();
                let join = json!({
                    "user_id": user, "recipient": recipient, "signing_key": s.keys[&user].1, "via": "invite", "signed_by": user,
                    "signer_key": s.keys[&user].1, "signature": k["signature"],
                    "invite": { "signed_by": inv["signed_by"], "signer_key": inv["signing_key"], "recipient": inv["recipient"], "signature": inv["signature"] },
                });
                s.joins.entry(epoch).or_default().push(join);
                let signed = Some((user.clone(), s.keys[&user].1.clone(), k["signature"].as_str().unwrap().to_string()));
                s.wraps.insert((epoch, user.clone()), W { recipient, wrap: k["wrap"].as_str().unwrap().into(), signed });
            }
            s.members.insert(user, m);
            ok(json!({ "team_id": TEAM, "approved": true }))
        }
        ("GET", p) if p == format!("{base}/sync") => {
            let epochs = s.files.values().map(|f| f.2).chain(s.log.iter().map(|b| b.2));
            let apps: Vec<Value> = epochs.clone().min().map(|oldest| json!({
                "app": "serverbox", "files": s.files.keys().filter(|n| *n != ".snapshot").count(),
                "bytes": s.files.values().map(|f| f.1.len()).sum::<usize>(), "snapshot": s.files.contains_key(".snapshot"),
                "log": !s.log.is_empty(), "oldest_epoch": oldest,
            })).into_iter().collect();
            ok(json!(apps))
        }
        ("GET", p) if p == format!("{base}/sync/serverbox") => ok(Value::Array(
            s.files
                .iter()
                .map(|(n, f)| {
                    let mut v = json!({ "name": n, "etag": f.0, "size": f.1.len(), "updated_at": "2026-01-01T00:00:00Z", "epoch": f.2 });
                    if let Value::Object(sig) = &f.3 {
                        v.as_object_mut().unwrap().extend(sig.clone());
                    }
                    v
                })
                .collect(),
        )),
        ("GET", p) if p == format!("{base}/sync/serverbox/snapshot") => match s.files.get(".snapshot") {
            Some(f) => signed_headers(Response::status(200).header("etag", &format!("\"{}\"", f.0)).header("sync-log", "l").header("sync-seq", "5"), &f.3).body(f.1.clone()),
            None => Response::status(404),
        },
        ("PUT", p) if p == format!("{base}/sync/serverbox/snapshot") => {
            let epoch: i64 = r.header("x-team-epoch").unwrap().parse().unwrap();
            assert_eq!(query("seq").as_deref(), Some("5"));
            let message = crypto::sync_snapshot_message(&format!("team:{TEAM}"), "serverbox", epoch, 5, blake3::hash(&r.body).as_bytes());
            let Some(sig) = signed_as(&s, &user, &message, r) else { return Response::json(403, json!({ "code": 2, "reason": "sync_signature" })) };
            s.etags += 1;
            let etag = format!("{:032x}", s.etags);
            s.files.insert(".snapshot".into(), (etag.clone(), r.body.clone(), epoch, sig));
            Response::status(204).header("etag", &format!("\"{etag}\""))
        }
        ("POST", p) if p == format!("{base}/sync/serverbox/log") => {
            let epoch: i64 = r.header("x-team-epoch").unwrap().parse().unwrap();
            if epoch != s.epoch {
                return Response::json(409, json!({ "code": 4, "reason": "team_epoch_stale" })).header("x-team-epoch", &s.epoch.to_string());
            }
            let key = r.header("idempotency-key").unwrap().to_string();
            let message = crypto::sync_batch_message(&format!("team:{TEAM}"), "serverbox", epoch, blake3::hash(&r.body).as_bytes(), &key);
            let Some(sig) = signed_as(&s, &user, &message, r) else { return Response::json(403, json!({ "code": 2, "reason": "sync_signature" })) };
            let seq = s.log.len() as i64 + 1;
            s.log.push((seq, r.body.clone(), epoch, key, sig));
            ok(json!({ "log": LOG, "seq": seq, "live": { "batches": seq, "bytes": 0 }, "compact": false }))
        }
        ("GET", p) if p == format!("{base}/sync/serverbox/log") => {
            let after: i64 = query("after").map_or(0, |v| v.parse().unwrap());
            let batches: Vec<Value> = s
                .log
                .iter()
                .filter(|b| b.0 > after)
                .map(|(seq, body, epoch, key, sig)| {
                    let mut v = json!({
                        "seq": seq, "size": body.len(), "epoch": epoch, "digest": blake3::hash(body).to_hex().as_str(),
                        "body": b64(body), "idempotency_key": key,
                    });
                    v.as_object_mut().unwrap().extend(sig.as_object().unwrap().clone());
                    v
                })
                .collect();
            ok(json!({ "log": LOG, "batches": batches, "head": s.log.len(), "snapshot_seq": 0, "more": false }))
        }
        ("GET", p) if p.starts_with(&format!("{base}/sync/serverbox/")) => match s.files.get(p.rsplit('/').next().unwrap()) {
            Some(f) => signed_headers(Response::status(200).header("etag", &format!("\"{}\"", f.0)), &f.3).body(f.1.clone()),
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
            if r.header("x-signature").is_none() {
                return Response::json(403, json!({ "code": 2, "reason": "sync_signature" }));
            }
            let highest = s.versions.get(&name).copied().unwrap_or(0);
            let version: i64 = r.header("x-sync-version").and_then(|v| v.parse().ok()).unwrap_or(0);
            if version <= highest || version > highest + 1024 {
                return Response::json(409, json!({ "code": 4, "reason": "sync_version" })).header("x-sync-version", &highest.to_string());
            }
            let message = crypto::sync_file_message(&format!("team:{TEAM}"), "serverbox", &name, epoch, version, blake3::hash(&r.body).as_bytes());
            let Some(mut sig) = signed_as(&s, &user, &message, r) else { return Response::json(403, json!({ "code": 2, "reason": "sync_signature" })) };
            sig["version"] = json!(version);
            s.versions.insert(name.clone(), version);
            s.etags += 1;
            let etag = format!("{:032x}", s.etags);
            s.files.insert(name, (etag.clone(), r.body.clone(), epoch, sig));
            Response::status(204).header("etag", &format!("\"{etag}\""))
        }
        _ => Response::status(404),
    }
}

/// A write's signature, checked against [user]'s signing key, as homebase
/// lists it.
fn signed_as(s: &State, user: &str, message: &[u8], r: &Request) -> Option<Value> {
    let sig = r.header("x-signature")?;
    verify_as(s, user, message, sig).then(|| json!({ "signer": user, "signing_key": s.keys[user].1, "signature": sig }))
}

fn signed_headers(mut res: Response, sig: &Value) -> Response {
    for (h, k) in [("x-signer", "signer"), ("x-signing-key", "signing_key"), ("x-signature", "signature"), ("x-sync-version", "version")] {
        match &sig[k] {
            Value::String(v) => res = res.header(h, v),
            Value::Number(v) => res = res.header(h, &v.to_string()),
            _ => {}
        }
    }
    res
}

/// A key record checked as homebase checks it: the next seq, naming the
/// chain's tail, signed by its key and (unless a reset) the one before.
fn put_key(s: &mut State, user: &str, body: &Value) -> Result<(), Response> {
    let records = s.records.entry(user.to_string()).or_default();
    let seq = body["seq"].as_i64().unwrap();
    if seq != records.len() as i64 + 1 {
        return Err(Response::json(409, json!({ "code": 4, "reason": "user_key_seq" })));
    }
    let tail = s.keys.get(user).map_or(NO_KEY, |k| raw(&k.1));
    let recipient = body["recipient"].as_str().unwrap().to_string();
    let signing_key = body["signing_key"].as_str().unwrap().to_string();
    let message = crypto::user_key_message(user, seq, &recipient, &raw(&signing_key), &tail);
    let check = |key: &[u8; 32], sig: &str| crypto::verify(key, &message, &unb64(sig, "t").unwrap(), "t").is_ok();
    if !check(&raw(&signing_key), body["self_signature"].as_str().unwrap()) {
        return Err(refuse("user_key_signature"));
    }
    let prev_signature = body["prev_signature"].as_str();
    if prev_signature.is_some_and(|sig| !check(&tail, sig)) {
        return Err(refuse("user_key_signature"));
    }
    records.push(json!({
        "seq": seq, "recipient": recipient, "signing_key": signing_key,
        "prev_signing_key": (tail != NO_KEY).then(|| b64(&tail)), "self_signature": body["self_signature"],
        "prev_signature": prev_signature, "reset": prev_signature.is_none(), "legacy": false, "created_at": "2026-01-01T00:00:00Z",
    }));
    s.keys.insert(user.to_string(), (recipient, signing_key));
    Ok(())
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
    InviteTerms { uses: 1, days: 7 }
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
