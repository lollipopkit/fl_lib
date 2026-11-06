//! A user's key records as a chain: each signed by its own key, and a
//! rotation by the key before too. Homebase checks the signatures as a record
//! is published; a device checks them again, since homebase may lie.

use std::collections::BTreeMap;

use super::crypto::{self, KEY_LEN, NO_KEY};
use super::verify::raw32;
use super::{KeyRecord, TeamError, unb64};

/// A record checked: its keys, and whether it follows the one before by a
/// rotation the key before signed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub seq: i64,
    pub recipient: String,
    pub signing_key: [u8; KEY_LEN],
    /// Signed by the key before: the same person's, without a doubt.
    pub rotates: bool,
}

/// A user's records, checked, by seq.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Chain(Vec<Link>);

impl Chain {
    /// [records] of [user_id] checked: a record whose own signature does not
    /// verify is homebase's forgery, refused; a legacy one (unsigned, from
    /// before records were) or a reset starts the chain anew.
    pub fn check(user_id: &str, records: &[KeyRecord]) -> Result<Self, TeamError> {
        let mut chain = Self::default();
        chain.extend(user_id, records)?;
        Ok(chain)
    }

    /// [records], the ones after this chain's, checked onto it.
    pub fn extend(&mut self, user_id: &str, records: &[KeyRecord]) -> Result<(), TeamError> {
        let mut links = self.0.clone();
        for r in records {
            let signing_key = raw32(&r.signing_key, "signing_key")?;
            let prev_key = r.prev_signing_key.as_deref().map(|k| raw32(k, "prev_signing_key")).transpose()?.unwrap_or(NO_KEY);
            let before = links.last();
            if before.is_some_and(|b| r.seq <= b.seq) {
                return Err(TeamError::Untrusted(format!("{user_id}: key records out of order")));
            }
            let mut rotates = false;
            if !r.legacy {
                let message = crypto::user_key_message(user_id, r.seq, &r.recipient, &signing_key, &prev_key);
                let own = r.self_signature.as_deref().ok_or_else(|| TeamError::Untrusted(format!("{user_id}: a key record unsigned")))?;
                crypto::verify(&signing_key, &message, &unb64(own, "self_signature")?, "a key record")?;
                rotates = !r.reset
                    && before.is_some_and(|b| b.seq + 1 == r.seq && b.signing_key == prev_key)
                    && match &r.prev_signature {
                        Some(sig) => crypto::verify(&prev_key, &message, &unb64(sig, "prev_signature")?, "a key rotation").is_ok(),
                        None => false,
                    };
            }
            links.push(Link { seq: r.seq, recipient: r.recipient.clone(), signing_key, rotates });
        }
        self.0 = links;
        Ok(())
    }

    pub fn head(&self) -> Option<&Link> {
        self.0.last()
    }

    pub fn links(&self) -> &[Link] {
        &self.0
    }

    /// Whether [to] is [from], or reached from a record of [from] by signed
    /// rotations only.
    pub fn follows(&self, from: &[u8; KEY_LEN], to: &[u8; KEY_LEN]) -> bool {
        if from == to {
            return true;
        }
        let mut on = false;
        for l in &self.0 {
            on = &l.signing_key == from || (on && l.rotates);
            if on && &l.signing_key == to {
                return true;
            }
        }
        false
    }

    /// The record of [key], the latest if it came back.
    pub fn link_of(&self, key: &[u8; KEY_LEN]) -> Option<&Link> {
        self.0.iter().rev().find(|l| &l.signing_key == key)
    }
}

/// The chains a check needs, by user.
pub type Chains = BTreeMap<String, Chain>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::team::b64;

    fn record(user: &str, seq: i64, key: &ed25519_dalek::SigningKey, prev: Option<&ed25519_dalek::SigningKey>, reset: bool) -> KeyRecord {
        let recipient = "age1r".to_string();
        let sk = key.verifying_key().to_bytes();
        let prev_key = prev.map_or(NO_KEY, |p| p.verifying_key().to_bytes());
        let message = crypto::user_key_message(user, seq, &recipient, &sk, &prev_key);
        KeyRecord {
            seq,
            recipient,
            signing_key: b64(&sk),
            prev_signing_key: prev.map(|_| b64(&prev_key)),
            self_signature: Some(b64(&crypto::sign(key, &message))),
            prev_signature: if reset { None } else { prev.map(|p| b64(&crypto::sign(p, &message))) },
            reset,
            legacy: false,
        }
    }

    #[test]
    fn rotations_follow_resets_do_not() {
        let k: Vec<_> = (1..=4u8).map(|s| crypto::signing_key(&[s; 32])).collect();
        let pk = |i: usize| k[i].verifying_key().to_bytes();
        let records = [
            record("u", 1, &k[0], None, true),
            record("u", 2, &k[1], Some(&k[0]), false),
            record("u", 3, &k[2], Some(&k[1]), true),
            record("u", 4, &k[3], Some(&k[2]), false),
        ];
        let chain = Chain::check("u", &records).unwrap();
        assert!(chain.follows(&pk(0), &pk(1)));
        assert!(!chain.follows(&pk(1), &pk(0)));
        assert!(!chain.follows(&pk(0), &pk(2)), "a reset breaks it");
        assert!(chain.follows(&pk(2), &pk(3)));

        // A rotation whose key before did not sign it: homebase's alone.
        let mut forged = records.clone();
        forged[1].prev_signature = forged[2].self_signature.clone();
        assert!(!Chain::check("u", &forged).unwrap().follows(&pk(0), &pk(1)));
        // A record its own key did not sign is refused outright.
        let mut bad = records.clone();
        bad[3].self_signature = bad[2].self_signature.clone();
        assert!(Chain::check("u", &bad).is_err());
        // Unsigned legacy records start anew.
        let mut legacy = records.clone();
        legacy[1].legacy = true;
        assert!(!Chain::check("u", &legacy).unwrap().follows(&pk(0), &pk(1)));
    }
}
