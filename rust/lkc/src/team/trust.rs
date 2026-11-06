//! What a device remembers of what it checked, so homebase cannot later show
//! it less: the signing keys met for each user (trust on first use), and per
//! team the last epoch verified, its key id and who was in it.

use std::collections::BTreeMap;
use std::future::Future;

use serde::{Deserialize, Serialize};

use super::chain::Chain;
use super::crypto::{self, KEY_LEN};
use super::verify::raw32;
use super::{TeamError, b64};

/// Where [Trust] is kept between runs (the app's keychain); every change is
/// written before what it allows is used.
pub trait Keeper: Send + Sync + 'static {
    fn save(&self, json: String) -> impl Future<Output = Result<(), String>> + Send;
}

/// A team's last epoch verified.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Seen {
    pub epoch: i64,
    /// Base64.
    pub key_id: String,
}

/// A user's signing key as last trusted here, with the record it is of.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pinned {
    pub seq: i64,
    /// Base64.
    pub signing_key: String,
    /// Keys of theirs trusted before a break in their chain (the person
    /// accepted the next): what they signed then still holds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub earlier: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trust {
    v: u32,
    /// Each user's signing key trusted last; followed along their key
    /// records by signed rotations, a break asked of the person.
    users: BTreeMap<String, Pinned>,
    teams: BTreeMap<String, Seen>,
    /// Each user's fingerprint as the person last compared it with them.
    #[serde(default)]
    compared: BTreeMap<String, String>,
    /// Recovery epochs the person accepted, by team.
    #[serde(default)]
    recoveries: BTreeMap<String, Vec<(i64, String)>>,
    /// The highest version read or written of each synced name
    /// (`owner/app/name`): one lower is homebase going back.
    #[serde(default)]
    versions: BTreeMap<String, i64>,
}

const VERSION: u32 = 2;

impl Trust {
    pub fn from_json(json: &str) -> Result<Self, TeamError> {
        let fresh = Self { v: VERSION, ..Self::default() };
        if json.trim().is_empty() {
            return Ok(fresh);
        }
        let v = serde_json::from_str::<serde_json::Value>(json).map_err(|e| TeamError::Invalid(format!("trust: {e}")))?;
        match v["v"].as_u64() {
            // TODO(migration): drop once no device holds a version 1 trust
            // (only the e2e accounts' do): it pinned keys without records,
            // which these are checked against now, so it starts anew.
            Some(1) => Ok(fresh),
            Some(n) if n == VERSION as u64 => serde_json::from_value(v).map_err(|e| TeamError::Invalid(format!("trust: {e}"))),
            other => Err(TeamError::Invalid(format!("trust: version {other:?}"))),
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("plain JSON")
    }

    /// [signing_key] (base64) as [user_id]'s from now on: the person compared
    /// it after a break in their chain.
    pub fn accept(&mut self, user_id: &str, signing_key: &str) {
        let mut earlier = Vec::new();
        if let Some(p) = self.users.remove(user_id) {
            earlier = p.earlier;
            if p.signing_key != signing_key && !earlier.contains(&p.signing_key) {
                earlier.push(p.signing_key);
            }
        }
        earlier.retain(|k| k != signing_key);
        self.users.insert(user_id.to_string(), Pinned { seq: 0, signing_key: signing_key.to_string(), earlier });
    }

    pub fn pinned(&self, user_id: &str) -> Option<&Pinned> {
        self.users.get(user_id)
    }

    /// [key] is [user_id]'s by their [chain]: the one trusted, one it rotated
    /// to (then trusted on), or one it rotated from (signing what came
    /// before). First met, it is trusted (and pinned). Another is
    /// [TeamError::SigningKeyChanged] until the person accepts it.
    pub(crate) fn check(&mut self, user_id: &str, chain: &Chain, key: &[u8; KEY_LEN]) -> Result<(), TeamError> {
        let encoded = b64(key);
        let seq = chain.link_of(key).map_or(0, |l| l.seq);
        let Some(pinned) = self.users.get_mut(user_id) else {
            self.users.insert(user_id.to_string(), Pinned { seq, signing_key: encoded, earlier: vec![] });
            return Ok(());
        };
        if pinned.signing_key == encoded || pinned.earlier.contains(&encoded) {
            return Ok(());
        }
        let pinned_key = raw32(&pinned.signing_key, "pinned")?;
        if chain.follows(&pinned_key, key) {
            if seq > pinned.seq {
                pinned.seq = seq;
                pinned.signing_key = encoded;
            }
            return Ok(());
        }
        if chain.follows(key, &pinned_key) {
            return Ok(());
        }
        for e in &pinned.earlier {
            let e = raw32(e, "earlier")?;
            if chain.follows(&e, key) || chain.follows(key, &e) {
                return Ok(());
            }
        }
        let fingerprint = chain.link_of(key).map(|l| crypto::fingerprint(user_id, &l.recipient, key));
        Err(TeamError::SigningKeyChanged { user_id: user_id.to_string(), signing_key: encoded, fingerprint })
    }

    /// [fingerprint] compared with [user_id] by the person.
    pub fn compare(&mut self, user_id: &str, fingerprint: &str) {
        self.compared.insert(user_id.to_string(), fingerprint.to_string());
    }

    /// [user_id]'s fingerprint as the person last compared it.
    pub fn compared(&self, user_id: &str) -> Option<&str> {
        self.compared.get(user_id).map(String::as_str)
    }

    pub fn seen(&self, team: &str) -> Option<&Seen> {
        self.teams.get(team)
    }

    pub(crate) fn see(&mut self, team: &str, seen: Seen) {
        self.teams.insert(team.to_string(), seen);
    }

    /// Forgets team [team]: left, or deleted.
    pub fn forget_team(&mut self, team: &str) {
        self.teams.remove(team);
        self.recoveries.remove(team);
        let prefix = format!("team:{team}/");
        self.versions.retain(|k, _| !k.starts_with(&prefix));
    }

    /// Recovery epoch [epoch] of [team], made by [user_id] under
    /// [signing_key], taken: the person accepted it, and so that key.
    pub fn accept_recovery(&mut self, team: &str, epoch: i64, user_id: &str, signing_key: &str) {
        let list = self.recoveries.entry(team.to_string()).or_default();
        let accepted = (epoch, signing_key.to_string());
        if !list.contains(&accepted) {
            list.push(accepted);
        }
        self.accept(user_id, signing_key);
    }

    pub fn recovery_accepted(&self, team: &str, epoch: i64, signing_key: &str) -> bool {
        self.recoveries.get(team).is_some_and(|l| l.iter().any(|(e, k)| *e == epoch && k == signing_key))
    }

    /// The highest version known of [name] (`owner/app/name`).
    pub fn version(&self, name: &str) -> i64 {
        self.versions.get(name).copied().unwrap_or(0)
    }

    /// [version] of [name] seen: kept when higher.
    pub(crate) fn saw_version(&mut self, name: &str, version: i64) {
        let v = self.versions.entry(name.to_string()).or_insert(0);
        *v = (*v).max(version);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::team::KeyRecord;
    use crate::team::crypto;

    #[test]
    fn keys_follow_their_chain() {
        let k: Vec<_> = (1..=3u8).map(|s| crypto::signing_key(&[s; 32])).collect();
        let pk = |i: usize| k[i].verifying_key().to_bytes();
        let rec = |seq: i64, i: usize, prev: Option<usize>, reset: bool| {
            let p = prev.map_or(crypto::NO_KEY, pk);
            let m = crypto::user_key_message("a", seq, "r", &pk(i), &p);
            KeyRecord {
                seq,
                recipient: "r".into(),
                signing_key: b64(&pk(i)),
                prev_signing_key: prev.map(|j| b64(&pk(j))),
                self_signature: Some(b64(&crypto::sign(&k[i], &m))),
                prev_signature: if reset { None } else { prev.map(|j| b64(&crypto::sign(&k[j], &m))) },
                reset,
                legacy: false,
            }
        };
        let chain = Chain::check("a", &[rec(1, 0, None, true), rec(2, 1, Some(0), false), rec(3, 2, Some(1), true)]).unwrap();
        let mut t = Trust::from_json("").unwrap();
        t.check("a", &chain, &pk(0)).unwrap();
        t.check("a", &chain, &pk(1)).unwrap();
        assert_eq!(t.pinned("a").unwrap().seq, 2);
        t.check("a", &chain, &pk(0)).unwrap();
        assert!(matches!(t.check("a", &chain, &pk(2)), Err(TeamError::SigningKeyChanged { .. })));
        t.accept("a", &b64(&pk(2)));
        t.check("a", &chain, &pk(2)).unwrap();
        // What the keys before the break signed still holds.
        t.check("a", &chain, &pk(0)).unwrap();
        t.check("a", &chain, &pk(1)).unwrap();
        let back = Trust::from_json(&t.to_json()).unwrap();
        assert_eq!(back, t);
        assert_eq!(Trust::from_json(r#"{"v":1,"users":{"a":["x"]},"teams":{}}"#).unwrap().pinned("a"), None);
        assert!(Trust::from_json(r#"{"v":3}"#).is_err());
    }
}
