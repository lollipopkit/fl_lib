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
use super::verify::raw32;
use super::{TeamClient, TeamError, b64};
use crate::secret_key::SecretKey;
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
    /// The signing key this one replaced: it signs the key record that
    /// publishes this one, so the account's chain goes on unbroken.
    previous: Option<SigningKey>,
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
    /// The Ed25519 seed of [AccountKey::previous], base64.
    #[serde(default)]
    previous: Option<String>,
}

impl AccountKey {
    pub fn generate(user_id: &str) -> Self {
        Self { user_id: user_id.to_string(), identities: vec![age::x25519::Identity::generate()], signing: crypto::signing_key(&crypto::random32()), signed: vec![], previous: None }
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
            previous: self.previous.as_ref().map(|k| BASE64.encode(k.to_bytes())),
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
        let previous = match &t.previous {
            None => None,
            Some(p) => {
                let p = Zeroizing::new(BASE64.decode(p).map_err(|_| CryptoError::Malformed("account key: previous".into()))?);
                let p: [u8; 32] = p.as_slice().try_into().map_err(|_| CryptoError::Malformed("account key: previous".into()))?;
                Some(crypto::signing_key(&p))
            }
        };
        Ok(Self { user_id: t.user_id.clone(), identities, signing: crypto::signing_key(&seed), signed: t.signed.clone(), previous })
    }

    pub fn seal(&self, passphrase: &str) -> Result<Vec<u8>, CryptoError> {
        self.seal_with(passphrase, None)
    }

    /// Seals with `(passphrase, secret_key)` when `secret_key` is present,
    /// protecting the uploaded key file against offline password cracking.
    pub fn seal_with(&self, passphrase: &str, secret_key: Option<&SecretKey>) -> Result<Vec<u8>, CryptoError> {
        match secret_key {
            Some(sk) => {
                let derived = sk.combine_passphrase(passphrase);
                crypto::seal_passphrase(self.to_text().as_bytes(), &derived, WORK_FACTOR)
            }
            None => crypto::seal_passphrase(self.to_text().as_bytes(), passphrase, WORK_FACTOR),
        }
    }

    /// [sealed] opened with [passphrase]: [TeamError::WrongPassphrase] when
    /// it does not.
    pub fn open(sealed: &[u8], passphrase: &str) -> Result<Self, TeamError> {
        Self::open_with(sealed, passphrase, None).map(|(key, _)| key)
    }

    /// Opens [sealed] with `(passphrase, secret_key)`. Returns `(key, upgraded)`
    /// where `upgraded == true` means a legacy passphrase-only file was opened
    /// while `secret_key` is present and should be re-sealed.
    pub fn open_with(sealed: &[u8], passphrase: &str, secret_key: Option<&SecretKey>) -> Result<(Self, bool), TeamError> {
        let (plain, legacy) = match secret_key {
            Some(sk) => {
                let derived = sk.combine_passphrase(passphrase);
                match crypto::open_passphrase(sealed, &derived, MAX_WORK_FACTOR) {
                    Ok(p) => (p, false),
                    // TODO(migration): drop passphrase-only fallback once all
                    // existing `lkc/identity.age` files are re-sealed with SecretKey.
                    Err(CryptoError::WrongKey) => match crypto::open_passphrase(sealed, passphrase, MAX_WORK_FACTOR) {
                        Ok(p) => (p, true),
                        Err(CryptoError::WrongKey) => return Err(TeamError::WrongPassphrase),
                        Err(e) => return Err(TeamError::Crypto(e)),
                    },
                    Err(e) => return Err(TeamError::Crypto(e)),
                }
            }
            None => match crypto::open_passphrase(sealed, passphrase, MAX_WORK_FACTOR) {
                Ok(p) => (p, false),
                Err(CryptoError::WrongKey) => return Err(TeamError::WrongPassphrase),
                Err(e) => return Err(TeamError::Crypto(e)),
            },
        };
        let text = std::str::from_utf8(&plain).map_err(|_| TeamError::Crypto(CryptoError::Malformed("account key: not text".into())))?;
        Ok((Self::from_text(text)?, legacy))
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
        Self { user_id: self.user_id.clone(), identities, signing: crypto::signing_key(&crypto::random32()), signed, previous: Some(self.signing.clone()) }
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

    /// Whether a device of the account made its key: one to open, not to set.
    pub async fn exists(&self) -> Result<bool, TeamError> {
        Ok(self.sync.head(FILE).await?.is_some())
    }

    /// The key and its version; `None` before any device made one.
    pub async fn fetch(&self, passphrase: &str) -> Result<Option<(AccountKey, String)>, TeamError> {
        self.fetch_with(passphrase, None).await
    }

    /// Fetches the account key with `(passphrase, secret_key)`, automatically
    /// upgrading a legacy passphrase-only file when `secret_key` is provided.
    pub async fn fetch_with(&self, passphrase: &str, secret_key: Option<&SecretKey>) -> Result<Option<(AccountKey, String)>, TeamError> {
        let Some((sealed, etag, _)) = self.sync.download_bytes(FILE).await? else { return Ok(None) };
        let (key, legacy) = AccountKey::open_with(&sealed, passphrase, secret_key)?;
        if key.user_id != self.user_id {
            return Err(TeamError::Untrusted("the account key is of another account".into()));
        }
        if legacy && let Some(sk) = secret_key {
            // Best-effort upgrade to two-factor sealing; another device racing
            // us simply leaves its newer version in place.
            if let Ok(new_etag) = self.write_with(&key, passphrase, Some(sk), Condition::Match(etag.clone())).await {
                return Ok(Some((key, new_etag)));
            }
        }
        Ok(Some((key, etag)))
    }

    /// The account's key: the file's, else a new one put there (another
    /// device's taken if it was first).
    pub async fn load_or_create(&self, passphrase: &str) -> Result<AccountKey, TeamError> {
        self.load_or_create_with(passphrase, None).await
    }

    /// [`Self::load_or_create`] with optional two-factor [`SecretKey`].
    pub async fn load_or_create_with(&self, passphrase: &str, secret_key: Option<&SecretKey>) -> Result<AccountKey, TeamError> {
        let mut wait = std::time::Duration::from_millis(200);
        for _ in 0..RACES {
            if let Some((key, _)) = self.fetch_with(passphrase, secret_key).await? {
                return Ok(key);
            }
            let key = AccountKey::generate(&self.user_id);
            match self.write_with(&key, passphrase, secret_key, Condition::Absent).await {
                Ok(_) => return Ok(key),
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
        self.rotate_with(key, etag, passphrase, None).await
    }

    pub async fn rotate_with(&self, key: &AccountKey, etag: &str, passphrase: &str, secret_key: Option<&SecretKey>) -> Result<AccountKey, TeamError> {
        let next = key.rotated();
        self.write_with(&next, passphrase, secret_key, Condition::Match(etag.to_string())).await?;
        Ok(next)
    }

    /// The file sealed with [new], from [old]: the password changed.
    pub async fn change_passphrase(&self, old: &str, new: &str) -> Result<(), TeamError> {
        self.change_passphrase_with(old, new, None).await
    }

    pub async fn change_passphrase_with(&self, old: &str, new: &str, secret_key: Option<&SecretKey>) -> Result<(), TeamError> {
        let Some((key, etag)) = self.fetch_with(old, secret_key).await? else { return Err(TeamError::NotFound) };
        self.write_with(&key, new, secret_key, Condition::Match(etag)).await?;
        Ok(())
    }

    async fn write_with(&self, key: &AccountKey, passphrase: &str, secret_key: Option<&SecretKey>, condition: Condition) -> Result<String, TeamError> {
        self.sync.upload_bytes(FILE, key.seal_with(passphrase, secret_key)?, condition).await.map_err(Into::into)
    }
}

impl<S: Store> TeamClient<S> {
    /// [key]'s public halves on `/v2/keys` as the account's next key
    /// record, unless already its head. Signed by the key, and by the key
    /// before when this one replaced it ([AccountKey::rotated]); otherwise
    /// a reset, which every member is asked to confirm. Homebase tells the
    /// teams.
    pub async fn publish(&self, key: &AccountKey) -> Result<(), TeamError> {
        for again in [true, false] {
            let head = self.user_key().await?;
            let (recipient, signing_key) = (key.recipient(), key.signing_public());
            if head.recipient.as_deref() == Some(&recipient) && head.signing_key.as_deref() == Some(&signing_key) {
                return Ok(());
            }
            let seq = head.next_seq.max(1);
            let tail = match &head.prev_signing_key {
                Some(k) => raw32(k, "prev_signing_key")?,
                None => crypto::NO_KEY,
            };
            let message = crypto::user_key_message(key.user_id(), seq, &recipient, &key.signing_raw(), &tail);
            // The key before signs only when it is the chain's tail.
            let prev = key.previous.as_ref().filter(|p| p.verifying_key().to_bytes() == tail);
            let body = serde_json::json!({
                "seq": seq,
                "recipient": recipient,
                "signing_key": signing_key,
                "self_signature": b64(&crypto::sign(key.signing(), &message)),
                "prev_signature": prev.map(|p| b64(&crypto::sign(p, &message))),
            });
            match self.put_user_key(&body).await {
                // Another device published meanwhile: read the head again.
                Err(TeamError::Refused(r)) if again && r == "user_key_seq" => continue,
                other => return other,
            }
        }
        Err(TeamError::Refused("user_key_seq".into()))
    }
    /// Publishes [key] on `/v2/keys` only when `/v2/keys` is empty, already
    /// matches [key], or chains cleanly from `key.previous`. Refuses to send
    /// an unchained reset (`prev_signature: None`) when a different signing
    /// key already exists on `/v2/keys`, preventing a stale device or a
    /// compromised server from breaking the account's team key chain.
    pub async fn publish_no_reset(&self, key: &AccountKey) -> Result<(), TeamError> {
        for again in [true, false] {
            let head = self.user_key().await?;
            let (recipient, signing_key) = (key.recipient(), key.signing_public());
            if head.recipient.as_deref() == Some(&recipient) && head.signing_key.as_deref() == Some(&signing_key) {
                return Ok(());
            }
            let seq = head.next_seq.max(1);
            let tail = match &head.prev_signing_key {
                Some(k) => raw32(k, "prev_signing_key")?,
                None => crypto::NO_KEY,
            };
            let prev = key.previous.as_ref().filter(|p| p.verifying_key().to_bytes() == tail);
            if head.prev_signing_key.is_some() && prev.is_none() {
                return Err(TeamError::Untrusted("remote signing key head differs from local account key; refusing silent reset".into()));
            }
            let message = crypto::user_key_message(key.user_id(), seq, &recipient, &key.signing_raw(), &tail);
            let body = serde_json::json!({
                "seq": seq,
                "recipient": recipient,
                "signing_key": signing_key,
                "self_signature": b64(&crypto::sign(key.signing(), &message)),
                "prev_signature": prev.map(|p| b64(&crypto::sign(p, &message))),
            });
            match self.put_user_key(&body).await {
                Err(TeamError::Refused(r)) if again && r == "user_key_seq" => continue,
                other => return other,
            }
        }
        Err(TeamError::Refused("user_key_seq".into()))
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
    fn secret_key_seal_and_legacy_fallback() {
        let k = AccountKey::generate("u1");
        let sk = SecretKey::generate();
        let wrong_sk = SecretKey::generate();

        let sealed_2fa = k.seal_with("pw", Some(&sk)).unwrap();
        // Bare password alone cannot open a 2FA-sealed account key.
        assert!(matches!(AccountKey::open_with(&sealed_2fa, "pw", None), Err(TeamError::WrongPassphrase)));
        // Wrong secret key cannot open it.
        assert!(matches!(AccountKey::open_with(&sealed_2fa, "pw", Some(&wrong_sk)), Err(TeamError::WrongPassphrase)));
        // Correct (password, secret_key) opens with upgraded=false.
        let (opened, upgraded) = AccountKey::open_with(&sealed_2fa, "pw", Some(&sk)).unwrap();
        assert!(!upgraded);
        assert_eq!(opened.signing_public(), k.signing_public());

        // Legacy passphrase-only file opens with upgraded=true when secret_key is given.
        let legacy = k.seal_with("pw", None).unwrap();
        let (opened_legacy, upgraded_legacy) = AccountKey::open_with(&legacy, "pw", Some(&sk)).unwrap();
        assert!(upgraded_legacy);
        assert_eq!(opened_legacy.signing_public(), k.signing_public());
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
