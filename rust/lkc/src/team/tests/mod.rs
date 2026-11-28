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

mod epochs;
mod promotions;
mod reads;

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
            Some(f) => signed_headers(Response::status(200).header("etag", &format!("\"{}\"", f.0)).header("sync-log", "1f").header("sync-seq", "5"), &f.3).body(f.1.clone()),
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
