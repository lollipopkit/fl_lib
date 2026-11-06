//! The account's own key: an age X25519 identity, which every team's key is
//! wrapped to, and an Ed25519 key, which signs what an admin's device makes
//! of a team's. One per account for every app: in the sync space of app
//! [`APP`] as [`FILE`], sealed with the person's LK Cloud key password (age
//! scrypt), its public halves published on `/v2/keys`.

use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::crypto::{self, CryptoError, identity_text, parse_identity};
use super::{TeamClient, TeamError};
use crate::session::{Session, Store};
use crate::sync::{Condition, Kind, SyncClient};

/// The sync space the account key is kept in, apart from any app's.
pub const APP: &str = "lkc";
pub const FILE: &str = "identity.age";
/// scrypt's `log2(N)` written: as fl_lib's `AgeCryptor`, well under a second
/// on a phone.
pub const WORK_FACTOR: u8 = 17;
/// The highest opened.
pub const MAX_WORK_FACTOR: u8 = 20;
/// The identities kept after a rotation besides the newest: wraps to an
/// older recipient open until they are rewrapped.
const HISTORY: usize = 3;
/// How often [AccountKeyFile::load_or_create] reads again after losing.
const RACES: usize = 5;

#[derive(Clone)]
pub struct AccountKey {
    /// The account it is of.
    user_id: String,
    /// The newest first.
    identities: Vec<age::x25519::Identity>,
    signing: SigningKey,
    /// The public halves of the signing keys this one replaced, base64:
    /// what this account signed before is still its own.
    signed: Vec<String>,
}

/// Zeroed when dropped: it holds the secret keys as text.
#[derive(Serialize, Deserialize, zeroize::Zeroize, zeroize::ZeroizeOnDrop)]
struct Text {
    v: u32,
    user_id: String,
    /// `AGE-SECRET-KEY-1…`, the newest first.
    age: Vec<String>,
    /// The Ed25519 seed, base64.
    signing: String,
    #[serde(default)]
    signed: Vec<String>,
}

impl AccountKey {
    pub fn generate(user_id: &str) -> Self {
        Self { user_id: user_id.to_string(), identities: vec![age::x25519::Identity::generate()], signing: crypto::signing_key(&crypto::random32()), signed: vec![] }
    }

    pub fn user_id(&self) -> &str {
        &self.user_id
    }

    /// What is sealed, and what a device keeps in its keychain once read.
    pub fn to_text(&self) -> Zeroizing<String> {
        let text = Text {
            v: 1,
            user_id: self.user_id.clone(),
            age: self.identities.iter().map(|i| identity_text(i).to_string()).collect(),
            signing: BASE64.encode(self.signing.to_bytes()),
            signed: self.signed.clone(),
        };
        Zeroizing::new(serde_json::to_string(&text).expect("plain JSON"))
    }

    pub fn from_text(text: &str) -> Result<Self, CryptoError> {
        let t: Text = serde_json::from_str(text).map_err(|e| CryptoError::Malformed(format!("account key: {e}")))?;
        if t.v != 1 || t.age.is_empty() || t.user_id.is_empty() {
            return Err(CryptoError::Malformed("account key: not version 1".into()));
        }
        let identities = t.age.iter().map(|i| parse_identity(i)).collect::<Result<Vec<_>, _>>()?;
        let seed = Zeroizing::new(BASE64.decode(&t.signing).map_err(|_| CryptoError::Malformed("account key: signing".into()))?);
        let seed: [u8; 32] = seed.as_slice().try_into().map_err(|_| CryptoError::Malformed("account key: signing".into()))?;
        Ok(Self { user_id: t.user_id.clone(), identities, signing: crypto::signing_key(&seed), signed: t.signed.clone() })
    }

    pub fn seal(&self, passphrase: &str) -> Result<Vec<u8>, CryptoError> {
        crypto::seal_passphrase(self.to_text().as_bytes(), passphrase, WORK_FACTOR)
    }

    /// [sealed] opened with [passphrase]: [TeamError::WrongPassphrase] when
    /// it does not.
    pub fn open(sealed: &[u8], passphrase: &str) -> Result<Self, TeamError> {
        let plain = crypto::open_passphrase(sealed, passphrase, MAX_WORK_FACTOR).map_err(|e| match e {
            CryptoError::WrongKey => TeamError::WrongPassphrase,
            e => TeamError::Crypto(e),
        })?;
        let text = std::str::from_utf8(&plain).map_err(|_| TeamError::Crypto(CryptoError::Malformed("account key: not text".into())))?;
        Ok(Self::from_text(text)?)
    }

    /// What teams wrap their keys to.
    pub fn recipient(&self) -> String {
        self.identities[0].to_public().to_string()
    }

    /// Whether [recipient] is one of this key's, the current or an older.
    pub fn holds(&self, recipient: &str) -> bool {
        self.identities.iter().any(|i| i.to_public().to_string() == recipient)
    }

    pub fn identities(&self) -> Vec<&dyn age::Identity> {
        self.identities.iter().map(|i| i as &dyn age::Identity).collect()
    }

    pub fn signing(&self) -> &SigningKey {
        &self.signing
    }

    /// The Ed25519 public key, base64.
    pub fn signing_public(&self) -> String {
        BASE64.encode(self.signing_raw())
    }

    pub fn signing_raw(&self) -> [u8; 32] {
        self.signing.verifying_key().to_bytes()
    }

    /// Every signing key's public half this account has had, the current
    /// first.
    pub fn signing_history(&self) -> impl Iterator<Item = String> + '_ {
        std::iter::once(self.signing_public()).chain(self.signed.iter().cloned())
    }

    /// New keys in place of these, the older identities kept to open wraps
    /// not yet rewrapped. The signing key is new too: the old may be known.
    pub fn rotated(&self) -> Self {
        let mut identities = vec![age::x25519::Identity::generate()];
        identities.extend(self.identities.iter().take(HISTORY).cloned());
        let signed = self.signing_history().collect();
        Self { user_id: self.user_id.clone(), identities, signing: crypto::signing_key(&crypto::random32()), signed }
    }
}

/// Reads and writes the account key's file, of account [user_id].
pub struct AccountKeyFile<S: Store> {
    sync: SyncClient<S>,
    user_id: String,
}

impl<S: Store> AccountKeyFile<S> {
    pub fn new(session: Arc<Session<S>>, user_id: &str) -> Self {
        Self { sync: SyncClient::new(session, APP), user_id: user_id.to_string() }
    }

    /// The key and its version; `None` before any device made one.
    pub async fn fetch(&self, passphrase: &str) -> Result<Option<(AccountKey, String)>, TeamError> {
        let Some((sealed, etag)) = self.sync.download_bytes(FILE).await? else { return Ok(None) };
        let key = AccountKey::open(&sealed, passphrase)?;
        if key.user_id != self.user_id {
            return Err(TeamError::Untrusted("the account key is of another account".into()));
        }
        Ok(Some((key, etag)))
    }

    /// The account's key: the file's, else a new one put there (another
    /// device's taken if it was first).
    pub async fn load_or_create(&self, passphrase: &str) -> Result<AccountKey, TeamError> {
        let mut wait = std::time::Duration::from_millis(200);
        for _ in 0..RACES {
            if let Some((key, _)) = self.fetch(passphrase).await? {
                return Ok(key);
            }
            let key = AccountKey::generate(&self.user_id);
            match self.write(&key, passphrase, Condition::Absent).await {
                Ok(()) => return Ok(key),
                // Another device's is there, though not yet shown: read again.
                Err(TeamError::Sync(Kind::Changed, _)) => {
                    tokio::time::sleep(wait).await;
                    wait *= 2;
                }
                Err(e) => return Err(e),
            }
        }
        Err(TeamError::Unreachable("the account key is there and is not".into()))
    }

    /// [key] rotated, written over the version [etag] read: fails, changing
    /// nothing, when another device wrote it meanwhile.
    pub async fn rotate(&self, key: &AccountKey, etag: &str, passphrase: &str) -> Result<AccountKey, TeamError> {
        let next = key.rotated();
        self.write(&next, passphrase, Condition::Match(etag.to_string())).await?;
        Ok(next)
    }

    /// The file sealed with [new], from [old]: the password changed.
    pub async fn change_passphrase(&self, old: &str, new: &str) -> Result<(), TeamError> {
        let Some((key, etag)) = self.fetch(old).await? else { return Err(TeamError::NotFound) };
        self.write(&key, new, Condition::Match(etag)).await
    }

    async fn write(&self, key: &AccountKey, passphrase: &str, condition: Condition) -> Result<(), TeamError> {
        self.sync.upload_bytes(FILE, key.seal(passphrase)?, condition).await.map(|_| ()).map_err(Into::into)
    }
}

impl<S: Store> TeamClient<S> {
    /// Public halves read from `/v2/keys` before, published again.
    pub async fn restore_user_key(&self, recipient: &str, signing_key: &str) -> Result<(), TeamError> {
        self.set_user_key(recipient, signing_key).await
    }

    /// [key]'s public halves on `/v2/keys`, unless already there. Homebase
    /// tells the teams, whose devices check the new attestation.
    pub async fn publish(&self, key: &AccountKey) -> Result<(), TeamError> {
        let published = self.user_key().await?;
        let (recipient, signing_key) = (key.recipient(), key.signing_public());
        if published.recipient.as_deref() == Some(&recipient) && published.signing_key.as_deref() == Some(&signing_key) {
            return Ok(());
        }
        self.set_user_key(&recipient, &signing_key).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_and_seal_round_trip() {
        let k = AccountKey::generate("u");
        let back = AccountKey::from_text(&k.to_text()).unwrap();
        assert_eq!(back.recipient(), k.recipient());
        assert_eq!(back.signing_public(), k.signing_public());

        let sealed = crypto::seal_passphrase(k.to_text().as_bytes(), "pw", 10).unwrap();
        assert_eq!(AccountKey::open(&sealed, "pw").unwrap().recipient(), k.recipient());
        assert!(matches!(AccountKey::open(&sealed, "nope"), Err(TeamError::WrongPassphrase)));
    }

    #[test]
    fn rotation_keeps_older_identities() {
        let k = AccountKey::generate("u");
        let mut r = k.rotated();
        assert_ne!(r.recipient(), k.recipient());
        assert_ne!(r.signing_public(), k.signing_public());
        assert_eq!(r.identities[1].to_public().to_string(), k.recipient());
        for _ in 0..5 {
            r = r.rotated();
        }
        assert_eq!(r.identities.len(), HISTORY + 1);
    }
}
