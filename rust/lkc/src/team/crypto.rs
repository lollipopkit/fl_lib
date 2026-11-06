//! A team's key material, pure: what a device derives, MACs, signs and
//! verifies. Homebase stores all of it opaque (signatures it checks too).
//!
//! Encoding of every message: a domain tag ending in `\0`, a team id as its
//! 16 bytes, an epoch as `i64` big-endian, a key id as its 32 bytes, every
//! string with a `u32` big-endian length before it. Every derivation context
//! names `v1`; a change of any of it is a `v2`.
//!
//! - An epoch's key `K` is 32 random bytes. What the team syncs is age,
//!   sealed to the X25519 identity [`TeamKey::identity`] derives from it.
//! - A wrap is `K` sealed (age) to a member's recipient.
//! - An attestation is a keyed blake3 under `K` of a member's recipient and
//!   signing key: only one holding `K` can make one.
//! - A commit MAC is a keyed blake3 under the previous epoch's `K` of the new
//!   one's [`TeamKey::id`].
//! - A commit is signed (Ed25519) by the admin making it, over the key id,
//!   the key id before it ([`NO_KEY`] for the first) and every member's
//!   role, recipient and signing key: the records form a chain, each
//!   committed by one of the epoch before, so one removed (who holds the
//!   last `K` and their signing key) cannot make the next even with
//!   homebase's help. A grant and an invite are signed too.
//! - An invite's link carries its secret and the inviter's signing key: the
//!   link is the channel apart from homebase.
//! - A member's [`fingerprint`] is what two people compare.
//!
//! Known limits: who is a member is homebase's word; a device trusts the
//! signing key it first meets for a user (then pinned, `Trust`), and the
//! chain from the first record it is shown; a member removed reads what was
//! sealed before the rotation that followed.

use std::io::{Read, Write};
use std::str::FromStr;

use age::secrecy::{ExposeSecret, SecretString};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use bech32::{ToBase32, Variant};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use zeroize::{Zeroize, Zeroizing};

/// What every key, secret and MAC is.
pub const KEY_LEN: usize = 32;

const CTX_IDENTITY: &str = "lkc team v1 identity";
const CTX_ID: &str = "lkc team v1 id";
const CTX_ATTEST: &str = "lkc team v1 attest";
const CTX_COMMIT_MAC: &str = "lkc team v1 commit";
const CTX_INVITE: &str = "lkc team v1 invite";
const CTX_FINGERPRINT: &str = "lkc team v1 fingerprint";

const TAG_COMMIT: &[u8] = b"lkc team v1 commit\0";
const TAG_GRANT: &[u8] = b"lkc team v1 grant\0";
const TAG_INVITE: &[u8] = b"lkc team v1 invite\0";
const TAG_ROLE: &[u8] = b"lkc team v1 role\0";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// Not an age file any key given opens, or not what it should hold.
    Open(String),
    /// A recipient, identity or key that does not parse.
    Malformed(String),
    /// A MAC or signature that does not verify.
    Forged(&'static str),
    /// An age file none of the keys or passphrases given opens.
    WrongKey,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open(e) => write!(f, "cannot open: {e}"),
            Self::Malformed(e) => write!(f, "malformed: {e}"),
            Self::Forged(what) => write!(f, "{what} does not verify"),
            Self::WrongKey => f.write_str("sealed to no key given"),
        }
    }
}

impl std::error::Error for CryptoError {}

pub(crate) fn random32() -> Zeroizing<[u8; KEY_LEN]> {
    let mut b = Zeroizing::new([0u8; KEY_LEN]);
    getrandom::fill(b.as_mut()).expect("the OS random source");
    b
}

/// An age X25519 identity of 32 secret bytes.
fn x25519_identity(secret: &[u8; KEY_LEN]) -> age::x25519::Identity {
    let mut encoded = bech32::encode("age-secret-key-", secret.to_base32(), Variant::Bech32).expect("a valid HRP");
    let upper = Zeroizing::new(encoded.to_uppercase());
    encoded.zeroize();
    age::x25519::Identity::from_str(&upper).expect("32 bytes are an identity")
}

/// [plain] sealed (binary age) to [recipients].
pub(crate) fn seal_to(plain: &[u8], recipients: &[&dyn age::Recipient]) -> Result<Vec<u8>, CryptoError> {
    let encryptor = age::Encryptor::with_recipients(recipients.iter().copied()).map_err(|e| CryptoError::Malformed(e.to_string()))?;
    let mut out = Vec::with_capacity(plain.len() + 256);
    let mut w = encryptor.wrap_output(&mut out).map_err(|e| CryptoError::Malformed(e.to_string()))?;
    w.write_all(plain).and_then(|_| w.finish()).map_err(|e| CryptoError::Malformed(e.to_string()))?;
    Ok(out)
}

/// [sealed] (binary or armored age) opened with any of [identities].
pub(crate) fn open_with(sealed: &[u8], identities: &[&dyn age::Identity]) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    let reader = age::armor::ArmoredReader::new(sealed);
    // Debug, not Display: age's message for `ExcessiveWork` overflows.
    let decryptor = age::Decryptor::new(reader).map_err(|e| CryptoError::Open(format!("{e:?}")))?;
    let mut r = decryptor.decrypt(identities.iter().copied()).map_err(|e| match e {
        age::DecryptError::DecryptionFailed | age::DecryptError::NoMatchingKeys => CryptoError::WrongKey,
        e => CryptoError::Open(format!("{e:?}")),
    })?;
    let mut out = Zeroizing::new(Vec::new());
    r.read_to_end(&mut out).map_err(|e| CryptoError::Open(e.to_string()))?;
    Ok(out)
}

pub fn parse_recipient(r: &str) -> Result<age::x25519::Recipient, CryptoError> {
    age::x25519::Recipient::from_str(r).map_err(|e| CryptoError::Malformed(format!("recipient: {e}")))
}

/// An epoch's key.
#[derive(Clone)]
pub struct TeamKey(Zeroizing<[u8; KEY_LEN]>);

impl std::fmt::Debug for TeamKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TeamKey({})", hex(&self.id()))
    }
}

impl TeamKey {
    pub fn generate() -> Self {
        Self(random32())
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self, CryptoError> {
        let b: [u8; KEY_LEN] = b.try_into().map_err(|_| CryptoError::Open(format!("a key of {} bytes", b.len())))?;
        Ok(Self(Zeroizing::new(b)))
    }

    pub fn bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }

    /// What names it without telling it: in every signature, and checked
    /// against every key a wrap gives.
    pub fn id(&self) -> [u8; KEY_LEN] {
        blake3::derive_key(CTX_ID, self.0.as_ref())
    }

    pub fn identity(&self) -> age::x25519::Identity {
        x25519_identity(&Zeroizing::new(blake3::derive_key(CTX_IDENTITY, self.0.as_ref())))
    }

    /// What the team's files and batches are sealed to.
    pub fn recipient(&self) -> String {
        self.identity().to_public().to_string()
    }

    pub fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let r = self.identity().to_public();
        seal_to(plain, &[&r])
    }

    /// This key sealed to [recipient]: a wrap.
    pub fn wrap(&self, recipient: &str) -> Result<Vec<u8>, CryptoError> {
        let r = parse_recipient(recipient)?;
        seal_to(self.0.as_ref(), &[&r])
    }

    pub fn unwrap(wrap: &[u8], identities: &[&dyn age::Identity]) -> Result<Self, CryptoError> {
        Self::from_bytes(&open_with(wrap, identities)?)
    }

    /// [user_id]'s [recipient] and [signing_key] attested under this key.
    pub fn attest(&self, team: &[u8; 16], epoch: i64, user_id: &str, recipient: &str, signing_key: &[u8; KEY_LEN]) -> [u8; KEY_LEN] {
        let key = blake3::derive_key(CTX_ATTEST, self.0.as_ref());
        let mut m = Message::new(team, epoch);
        m.str(user_id).str(recipient).raw(signing_key);
        *blake3::keyed_hash(&key, &m.0).as_bytes()
    }

    pub fn verify_attestation(&self, team: &[u8; 16], epoch: i64, user_id: &str, recipient: &str, signing_key: &[u8; KEY_LEN], mac: &[u8]) -> Result<(), CryptoError> {
        mac_eq(&self.attest(team, epoch, user_id, recipient, signing_key), mac, "an attestation")
    }

    /// The commit MAC of an epoch's [commit] message ([commit_message]),
    /// this the key of the epoch before.
    pub fn commit_mac(&self, commit: &[u8]) -> [u8; KEY_LEN] {
        let key = blake3::derive_key(CTX_COMMIT_MAC, self.0.as_ref());
        *blake3::keyed_hash(&key, commit).as_bytes()
    }

    pub fn verify_commit_mac(&self, commit: &[u8], mac: &[u8]) -> Result<(), CryptoError> {
        mac_eq(&self.commit_mac(commit), mac, "a commit MAC")
    }
}

/// A MAC compared in constant time.
fn mac_eq(expected: &[u8; KEY_LEN], got: &[u8], what: &'static str) -> Result<(), CryptoError> {
    let got: [u8; KEY_LEN] = got.try_into().map_err(|_| CryptoError::Forged(what))?;
    (blake3::Hash::from(*expected) == blake3::Hash::from(got)).then_some(()).ok_or(CryptoError::Forged(what))
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

/// The fields after a message's tag.
struct Message(Vec<u8>);

impl Message {
    fn new(team: &[u8; 16], epoch: i64) -> Self {
        let mut v = Vec::with_capacity(128);
        v.extend_from_slice(team);
        v.extend_from_slice(&epoch.to_be_bytes());
        Self(v)
    }

    fn tagged(tag: &[u8], team: &[u8; 16], epoch: i64) -> Self {
        let mut m = Self(tag.to_vec());
        m.raw(team).raw(&epoch.to_be_bytes());
        m
    }

    fn raw(&mut self, b: &[u8]) -> &mut Self {
        self.0.extend_from_slice(b);
        self
    }

    fn str(&mut self, s: &str) -> &mut Self {
        self.0.extend_from_slice(&(s.len() as u32).to_be_bytes());
        self.0.extend_from_slice(s.as_bytes());
        self
    }
}

/// A member as a commit names them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Committed {
    pub user_id: String,
    /// `owner`, `admin` or `member`.
    pub role: String,
    pub recipient: String,
    pub signing_key: [u8; KEY_LEN],
}

/// The key id before the first epoch's.
pub const NO_KEY: [u8; KEY_LEN] = [0; KEY_LEN];

/// What a commit signs: epoch [epoch]'s key [key_id], following the key
/// [prev] ([NO_KEY] for the first), by [signer], for exactly [members]
/// (sorted here by user id's bytes).
pub fn commit_message(team: &[u8; 16], epoch: i64, key_id: &[u8; KEY_LEN], prev: &[u8; KEY_LEN], signer: &str, members: &[Committed]) -> Vec<u8> {
    let mut sorted: Vec<&Committed> = members.iter().collect();
    sorted.sort_by(|a, b| a.user_id.as_bytes().cmp(b.user_id.as_bytes()));
    let mut m = Message::tagged(TAG_COMMIT, team, epoch);
    m.raw(key_id).raw(prev).str(signer).raw(&(sorted.len() as u32).to_be_bytes());
    for c in sorted {
        m.str(&c.user_id).str(&c.role).str(&c.recipient).raw(&c.signing_key);
    }
    m.0
}

/// What two people compare to know they see the same member: [user_id]'s
/// [recipient] and [signing_key], as five groups of four hex digits.
pub fn fingerprint(user_id: &str, recipient: &str, signing_key: &[u8; KEY_LEN]) -> String {
    let mut m = Message(Vec::new());
    m.str(user_id).str(recipient).raw(signing_key);
    let digest = blake3::derive_key(CTX_FINGERPRINT, &m.0);
    digest[..10].chunks(2).map(hex).collect::<Vec<_>>().join(" ")
}

/// What a grant signs: epoch [epoch]'s key [key_id] wrapped by [signer] to
/// [user_id]'s [recipient].
pub fn grant_message(team: &[u8; 16], epoch: i64, key_id: &[u8; KEY_LEN], signer: &str, user_id: &str, recipient: &str) -> Vec<u8> {
    let mut m = Message::tagged(TAG_GRANT, team, epoch);
    m.raw(key_id).str(signer).str(user_id).str(recipient);
    m.0
}

/// What a keyed invite signs: epoch [epoch]'s key [key_id] wrapped by
/// [signer] to the link's [recipient], for joining as [role].
pub fn invite_message(team: &[u8; 16], epoch: i64, key_id: &[u8; KEY_LEN], signer: &str, role: &str, recipient: &str) -> Vec<u8> {
    let mut m = Message::tagged(TAG_INVITE, team, epoch);
    m.raw(key_id).str(signer).str(role).str(recipient);
    m.0
}

/// What a promotion signs: at epoch [epoch] (key [key_id]), [signer] makes
/// [user_id], under their [signing_key], [role] (`admin` or `owner`). It is
/// what lets one who joined after the epoch's commit make the next.
pub fn role_message(team: &[u8; 16], epoch: i64, key_id: &[u8; KEY_LEN], signer: &str, user_id: &str, role: &str, signing_key: &[u8; KEY_LEN]) -> Vec<u8> {
    let mut m = Message::tagged(TAG_ROLE, team, epoch);
    m.raw(key_id).str(signer).str(user_id).str(role).raw(signing_key);
    m.0
}

/// What a user's key record signs: their [seq]th keys, following
/// [prev_signing_key] (the record before's, or [NO_KEY] for the first). The
/// record's own key signs it, and the key before too, unless a reset.
pub fn user_key_message(user_id: &str, seq: i64, recipient: &str, signing_key: &[u8; KEY_LEN], prev_signing_key: &[u8; KEY_LEN]) -> Vec<u8> {
    let mut m = Message(b"lkc user v1 key\0".to_vec());
    m.str(user_id).raw(&seq.to_be_bytes()).str(recipient).raw(signing_key).raw(prev_signing_key);
    m.0
}

/// A synced write's owner: a user's id, or `team:{id}`.
fn sync_head(tag: &[u8], owner: &str, app: &str) -> Message {
    let mut m = Message(tag.to_vec());
    m.str(owner).str(app);
    m
}

/// What a file's version signs: its [name], [epoch] (0 for one's own),
/// [version] (rising per name) and the body's blake3.
pub fn sync_file_message(owner: &str, app: &str, name: &str, epoch: i64, version: i64, digest: &[u8; KEY_LEN]) -> Vec<u8> {
    let mut m = sync_head(b"lkc sync v1 file\0", owner, app);
    m.str(name).raw(&epoch.to_be_bytes()).raw(&version.to_be_bytes()).raw(digest);
    m.0
}

/// What a log batch signs: [epoch], the body's blake3, its idempotency [key].
pub fn sync_batch_message(owner: &str, app: &str, epoch: i64, digest: &[u8; KEY_LEN], key: &str) -> Vec<u8> {
    let mut m = sync_head(b"lkc sync v1 batch\0", owner, app);
    m.raw(&epoch.to_be_bytes()).raw(digest).str(key);
    m.0
}

/// What a log snapshot signs: [epoch], the [seq] it covers, the body's blake3.
pub fn sync_snapshot_message(owner: &str, app: &str, epoch: i64, seq: i64, digest: &[u8; KEY_LEN]) -> Vec<u8> {
    let mut m = sync_head(b"lkc sync v1 snapshot\0", owner, app);
    m.raw(&epoch.to_be_bytes()).raw(&seq.to_be_bytes()).raw(digest);
    m.0
}

pub fn sign(key: &SigningKey, message: &[u8]) -> [u8; 64] {
    key.sign(message).to_bytes()
}

/// [signature] of [message] by [signing_key] (32 bytes), strictly.
pub fn verify(signing_key: &[u8], message: &[u8], signature: &[u8], what: &'static str) -> Result<(), CryptoError> {
    let key: [u8; 32] = signing_key.try_into().map_err(|_| CryptoError::Malformed("a signing key".into()))?;
    let key = VerifyingKey::from_bytes(&key).map_err(|_| CryptoError::Malformed("a signing key".into()))?;
    let sig = Signature::from_slice(signature).map_err(|_| CryptoError::Forged(what))?;
    key.verify_strict(message, &sig).map_err(|_| CryptoError::Forged(what))
}

/// An invite's secret: 32 random bytes, in the link's fragment with the
/// inviter's signing key (base64url, unpadded, 64 bytes), never sent to
/// homebase. The link is the channel apart from homebase, so the joiner
/// takes the inviter's key from it, not from homebase.
#[derive(Clone)]
pub struct InviteSecret {
    secret: Zeroizing<[u8; KEY_LEN]>,
    /// The inviter's signing key.
    pub signer: [u8; KEY_LEN],
}

impl InviteSecret {
    pub fn generate(signer: [u8; KEY_LEN]) -> Self {
        Self { secret: random32(), signer }
    }

    pub fn parse(fragment: &str) -> Result<Self, CryptoError> {
        let bad = || CryptoError::Malformed("an invite secret".into());
        let b = Zeroizing::new(URL_SAFE_NO_PAD.decode(fragment.trim_start_matches('#')).map_err(|_| bad())?);
        if b.len() != 2 * KEY_LEN {
            return Err(bad());
        }
        let mut secret = Zeroizing::new([0u8; KEY_LEN]);
        secret.copy_from_slice(&b[..KEY_LEN]);
        Ok(Self { secret, signer: b[KEY_LEN..].try_into().map_err(|_| bad())? })
    }

    pub fn fragment(&self) -> String {
        let mut b = Zeroizing::new(Vec::with_capacity(2 * KEY_LEN));
        b.extend_from_slice(self.secret.as_ref());
        b.extend_from_slice(&self.signer);
        URL_SAFE_NO_PAD.encode(b.as_slice())
    }

    pub fn identity(&self) -> age::x25519::Identity {
        x25519_identity(&Zeroizing::new(blake3::derive_key(CTX_INVITE, self.secret.as_ref())))
    }

    pub fn recipient(&self) -> String {
        self.identity().to_public().to_string()
    }
}

/// A new Ed25519 key from 32 secret bytes.
pub fn signing_key(seed: &[u8; KEY_LEN]) -> SigningKey {
    SigningKey::from_bytes(seed)
}

/// [identity]'s text (`AGE-SECRET-KEY-1…`).
pub fn identity_text(identity: &age::x25519::Identity) -> Zeroizing<String> {
    Zeroizing::new(identity.to_string().expose_secret().to_string())
}

pub fn parse_identity(text: &str) -> Result<age::x25519::Identity, CryptoError> {
    age::x25519::Identity::from_str(text.trim()).map_err(|e| CryptoError::Malformed(format!("identity: {e}")))
}

/// [plain] sealed with [passphrase] (age scrypt, `log2(N)` [work]).
pub fn seal_passphrase(plain: &[u8], passphrase: &str, work: u8) -> Result<Vec<u8>, CryptoError> {
    let mut r = age::scrypt::Recipient::new(SecretString::from(passphrase.to_string()));
    r.set_work_factor(work);
    seal_to(plain, &[&r])
}

/// [sealed] opened with [passphrase], refusing a work factor above [max].
pub fn open_passphrase(sealed: &[u8], passphrase: &str, max: u8) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    let mut i = age::scrypt::Identity::new(SecretString::from(passphrase.to_string()));
    i.set_max_work_factor(max);
    open_with(sealed, &[&i])
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEAM: [u8; 16] = [7; 16];

    #[test]
    fn derivations_are_fixed() {
        let k = TeamKey::from_bytes(&[1; 32]).unwrap();
        // Pinned: a change here is a format change (a `v2`).
        assert_eq!(hex(&k.id()), hex(&blake3::derive_key("lkc team v1 id", &[1; 32])));
        assert!(k.recipient().starts_with("age1"));
        assert_eq!(k.recipient(), TeamKey::from_bytes(&[1; 32]).unwrap().recipient());
        assert_ne!(k.recipient(), TeamKey::from_bytes(&[2; 32]).unwrap().recipient());
    }

    #[test]
    fn seal_and_wrap_round_trip() {
        let k = TeamKey::generate();
        let sealed = k.seal(b"hello").unwrap();
        assert!(sealed.starts_with(b"age-encryption.org/v1\n"));
        assert_eq!(&open_with(&sealed, &[&k.identity()]).unwrap()[..], b"hello");

        let member = age::x25519::Identity::generate();
        let wrap = k.wrap(&member.to_public().to_string()).unwrap();
        assert!(wrap.len() <= 1024);
        assert_eq!(TeamKey::unwrap(&wrap, &[&member]).unwrap().id(), k.id());
        let other = age::x25519::Identity::generate();
        assert!(TeamKey::unwrap(&wrap, &[&other]).is_err());
    }

    #[test]
    fn macs_bind_every_field() {
        let k = TeamKey::generate();
        let sk = [5; 32];
        let mac = k.attest(&TEAM, 3, "u1", "age1x", &sk);
        k.verify_attestation(&TEAM, 3, "u1", "age1x", &sk, &mac).unwrap();
        assert!(k.verify_attestation(&TEAM, 4, "u1", "age1x", &sk, &mac).is_err());
        assert!(k.verify_attestation(&TEAM, 3, "u2", "age1x", &sk, &mac).is_err());
        assert!(k.verify_attestation(&TEAM, 3, "u1", "age1x", &[6; 32], &mac).is_err());
        // Length prefixes: moving a byte between fields changes the MAC.
        assert_ne!(k.attest(&TEAM, 3, "u1a", "ge1x", &sk), mac);
        assert!(TeamKey::generate().verify_attestation(&TEAM, 3, "u1", "age1x", &sk, &mac).is_err());

        let cm = k.commit_mac(b"commit 4");
        k.verify_commit_mac(b"commit 4", &cm).unwrap();
        assert!(k.verify_commit_mac(b"commit 5", &cm).is_err());
        assert!(k.verify_commit_mac(b"commit 4", &cm[..31]).is_err());
    }

    #[test]
    fn commit_message_is_canonical() {
        let a = Committed { user_id: "b".into(), role: "member".into(), recipient: "age1b".into(), signing_key: [2; 32] };
        let b = Committed { user_id: "a".into(), role: "owner".into(), recipient: "age1a".into(), signing_key: [1; 32] };
        let id = [9; 32];
        let m1 = commit_message(&TEAM, 1, &id, &NO_KEY, "a", &[a.clone(), b.clone()]);
        assert_eq!(m1, commit_message(&TEAM, 1, &id, &NO_KEY, "a", &[b.clone(), a.clone()]));
        assert_ne!(m1, commit_message(&TEAM, 1, &id, &[8; 32], "a", &[b.clone(), a.clone()]));
        let mut expected = b"lkc team v1 commit\0".to_vec();
        expected.extend_from_slice(&TEAM);
        expected.extend_from_slice(&1i64.to_be_bytes());
        expected.extend_from_slice(&id);
        expected.extend_from_slice(&NO_KEY);
        expected.extend_from_slice(&[0, 0, 0, 1, b'a', 0, 0, 0, 2]);
        for (u, r, k, sk) in [("a", "owner", "age1a", [1u8; 32]), ("b", "member", "age1b", [2; 32])] {
            for s in [u, r, k] {
                expected.extend_from_slice(&(s.len() as u32).to_be_bytes());
                expected.extend_from_slice(s.as_bytes());
            }
            expected.extend_from_slice(&sk);
        }
        assert_eq!(m1, expected);
    }

    /// Homebase's own expectations (`homebase-db` `team::tests::signed_messages`).
    #[test]
    fn messages_match_homebase() {
        let mut team = [0u8; 16];
        team[15] = 1;
        let m = grant_message(&team, 2, &[3; 32], "a", "bc", "r");
        let mut want = b"lkc team v1 grant\0".to_vec();
        want.extend_from_slice(&team);
        want.extend_from_slice(&2i64.to_be_bytes());
        want.extend_from_slice(&[3; 32]);
        for s in ["a", "bc", "r"] {
            want.extend_from_slice(&(s.len() as u32).to_be_bytes());
            want.extend_from_slice(s.as_bytes());
        }
        assert_eq!(m, want);
        let c = commit_message(&team, 2, &[3; 32], &[4; 32], "a", &[Committed { user_id: "a".into(), role: "owner".into(), recipient: "r".into(), signing_key: [5; 32] }]);
        let mut want = b"lkc team v1 commit\0".to_vec();
        want.extend_from_slice(&team);
        want.extend_from_slice(&2i64.to_be_bytes());
        want.extend_from_slice(&[3; 32]);
        want.extend_from_slice(&[4; 32]);
        want.extend_from_slice(b"\0\0\0\x01a\0\0\0\x01\0\0\0\x01a\0\0\0\x05owner\0\0\0\x01r");
        want.extend_from_slice(&[5; 32]);
        assert_eq!(c, want);
        let r = role_message(&team, 2, &[3; 32], "a", "b", "admin", &[5; 32]);
        let mut want = b"lkc team v1 role\0".to_vec();
        want.extend_from_slice(&team);
        want.extend_from_slice(&2i64.to_be_bytes());
        want.extend_from_slice(&[3; 32]);
        want.extend_from_slice(b"\0\0\0\x01a\0\0\0\x01b\0\0\0\x05admin");
        want.extend_from_slice(&[5; 32]);
        assert_eq!(r, want);
    }

    /// Homebase's signatures of its fixed messages (`homebase-db`
    /// `team::tests::vectors`), each by the key of seed `[1; 32]`.
    #[test]
    fn signatures_match_homebase() {
        let key = |seed: u8| signing_key(&[seed; 32]);
        let public = |seed: u8| key(seed).verifying_key().to_bytes();
        let digest = *blake3::hash(b"hello").as_bytes();
        let owner = "team:00000000-0000-0000-0000-000000000001";
        let recipient = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p";
        let messages = [
            user_key_message("user-1", 1, recipient, &public(1), &NO_KEY),
            user_key_message("user-1", 2, recipient, &public(1), &public(2)),
            sync_file_message(owner, "serverbox", "backup.age", 3, 7, &digest),
            sync_batch_message(owner, "serverbox", 3, &digest, "idem-key-0000001"),
            sync_snapshot_message(owner, "serverbox", 3, 42, &digest),
        ];
        let want = [
            "878033e33d6d720a76f005b948a9df27fc6293d80eeda8e2a0677b98a3d6a6e23db6b01bcce750ffd6492aedb78be184ba71c81c1a27640dd04f283832af7308",
            "e6360160769490209350f800fae850fc3a73d545f4b3ccc2b2af6361987fe1ffb6891b0096aa5fd9867b3d9820a38bb503775ccc3b4e16f7a43ec5fa2243cf0e",
            "a7e11feb9002130f43c207ab15e75c337766c270ce577169278d5d7c8984319b2003c4bbb22c2a456a222745adb2a86dc5732d941f8614456aac8bfdd4652a0e",
            "1c2214faee58d0c43fb6ddc1acecd25f75f3a39a580ca48760fa1444809beeb22edd8afb0380208e2deb4c5449912bf3c8dc7ad5219bbf1707439dd81d0bd00f",
            "35ec72198642ce7a01e389c07eb05cadd6bb93d253fcf9ff8f2a2e0c81bf954320998ca965cd6c00384d172e3612214c7404cf456df026087d987de4e3d53104",
        ];
        for (m, want) in messages.iter().zip(want) {
            assert_eq!(hex(&sign(&key(1), m)), want);
        }
    }

    #[test]
    fn fingerprints_bind_every_field() {
        let f = fingerprint("u", "age1u", &[1; 32]);
        assert_eq!(f.len(), 24);
        assert_ne!(f, fingerprint("u", "age1u", &[2; 32]));
        assert_ne!(f, fingerprint("u", "age1v", &[1; 32]));
    }

    #[test]
    fn signatures_verify_strictly() {
        let sk = signing_key(&random32());
        let pk = sk.verifying_key().to_bytes();
        let m = grant_message(&TEAM, 2, &[3; 32], "admin", "u", "age1u");
        let sig = sign(&sk, &m);
        verify(&pk, &m, &sig, "a grant").unwrap();
        let other = grant_message(&TEAM, 2, &[3; 32], "admin", "u", "age1v");
        assert!(verify(&pk, &other, &sig, "a grant").is_err());
        assert_ne!(m, invite_message(&TEAM, 2, &[3; 32], "admin", "u", "age1u"));
    }

    #[test]
    fn invite_secret_round_trips() {
        let s = InviteSecret::generate([7; 32]);
        let f = s.fragment();
        assert_eq!(f.len(), 86);
        let back = InviteSecret::parse(&format!("#{f}")).unwrap();
        assert_eq!((back.recipient(), back.signer), (s.recipient(), [7; 32]));
        assert!(InviteSecret::parse("short").is_err());
    }

    #[test]
    fn passphrase_round_trips() {
        let sealed = seal_passphrase(b"x", "pw", 10).unwrap();
        assert_eq!(&open_passphrase(&sealed, "pw", 20).unwrap()[..], b"x");
        assert!(open_passphrase(&sealed, "no", 20).is_err());
        assert!(open_passphrase(&sealed, "pw", 9).is_err());
    }
}
