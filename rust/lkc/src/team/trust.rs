//! What a device remembers of what it checked, so homebase cannot later show
//! it less: the signing keys met for each user (trust on first use), and per
//! team the last epoch verified, its key id and who was in it.

use std::collections::BTreeMap;
use std::future::Future;

use serde::{Deserialize, Serialize};

use super::TeamError;

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

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trust {
    v: u32,
    /// Each user's signing keys met (base64), the newest last.
    users: BTreeMap<String, Vec<String>>,
    teams: BTreeMap<String, Seen>,
}

impl Trust {
    pub fn from_json(json: &str) -> Result<Self, TeamError> {
        if json.trim().is_empty() {
            return Ok(Self { v: 1, ..Self::default() });
        }
        let t: Self = serde_json::from_str(json).map_err(|e| TeamError::Invalid(format!("trust: {e}")))?;
        if t.v != 1 {
            return Err(TeamError::Invalid(format!("trust: version {}", t.v)));
        }
        Ok(t)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("plain JSON")
    }

    /// [signing_key] as [user_id]'s newest: the person accepted a change.
    pub fn accept(&mut self, user_id: &str, signing_key: &str) {
        let keys = self.users.entry(user_id.to_string()).or_default();
        keys.retain(|k| k != signing_key);
        keys.push(signing_key.to_string());
    }

    pub fn known(&self, user_id: &str) -> &[String] {
        self.users.get(user_id).map_or(&[], Vec::as_slice)
    }

    fn newest(&self, user_id: &str) -> Option<&str> {
        self.known(user_id).last().map(String::as_str)
    }

    /// [signing_key]'s place among [user_id]'s, the oldest first: pinned now
    /// if they are first met; [TeamError::SigningKeyChanged] if another is.
    pub(crate) fn place(&mut self, user_id: &str, signing_key: &str) -> Result<usize, TeamError> {
        if let Some(i) = self.known(user_id).iter().position(|k| k == signing_key) {
            return Ok(i);
        }
        if !self.known(user_id).is_empty() {
            return Err(TeamError::SigningKeyChanged { user_id: user_id.to_string(), signing_key: signing_key.to_string() });
        }
        self.accept(user_id, signing_key);
        Ok(0)
    }

    /// [signing_key] is one [user_id] had: pinned now if they are first met.
    pub(crate) fn check_known(&mut self, user_id: &str, signing_key: &str) -> Result<(), TeamError> {
        self.place(user_id, signing_key).map(|_| ())
    }

    /// [signing_key] noted for [user_id] if first met; `false` when another
    /// is pinned for them (a warning, not a refusal: they hold no key here).
    pub(crate) fn note(&mut self, user_id: &str, signing_key: &str) -> bool {
        match self.newest(user_id) {
            Some(k) => k == signing_key,
            None => {
                self.accept(user_id, signing_key);
                true
            }
        }
    }

    /// Team [team]'s (its [super::canonical] id) last epoch verified.
    pub fn seen(&self, team: &str) -> Option<&Seen> {
        self.teams.get(team)
    }

    pub(crate) fn see(&mut self, team: &str, seen: Seen) {
        self.teams.insert(team.to_string(), seen);
    }

    /// Forgets team [team]: left, or deleted.
    pub fn forget_team(&mut self, team: &str) {
        self.teams.remove(team);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_pinned_on_first_use() {
        let mut t = Trust::from_json("").unwrap();
        assert_eq!(t.place("a", "k1").unwrap(), 0);
        assert!(matches!(t.place("a", "k2"), Err(TeamError::SigningKeyChanged { .. })));
        t.accept("a", "k2");
        assert_eq!((t.place("a", "k1").unwrap(), t.place("a", "k2").unwrap()), (0, 1));
        assert!(t.note("a", "k2") && !t.note("a", "k3"));
        let back = Trust::from_json(&t.to_json()).unwrap();
        assert_eq!(back, t);
        assert!(Trust::from_json(r#"{"v":2,"users":{},"teams":{}}"#).is_err());
    }
}
