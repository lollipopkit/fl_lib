//! Client-only 128-bit secret key (1Password model) that stays off every
//! server and combines with the user's backup password before `age scrypt`.
//!
//! Format: `S1-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` (30 Crockford Base32
//! characters encoding 128 random bits followed by a 22-bit BLAKE3 checksum,
//! 150 bits total). A single mistyped character is caught locally before any
//! key derivation runs.

use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::team::crypto::CryptoError;

const PREFIX: &str = "S1";
const RAW_LEN: usize = 16;
const CHECK_BITS: usize = 22;
const TOTAL_CHARS: usize = 30; // (128 + 22) / 5
const GROUP_SIZE: usize = 5;

const CTX_CHECK: &str = "lkc secret key v1 check";
const CTX_PASSPHRASE: &str = "lkc sync v1 secret-key passphrase";

/// Crockford Base32 alphabet (omits I, L, O, U).
const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// A 128-bit client-side secret key, zeroed on drop.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct SecretKey([u8; RAW_LEN]);

impl std::fmt::Debug for SecretKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretKey(…)")
    }
}

impl SecretKey {
    /// Generates a fresh 128-bit key from the OS CSPRNG.
    pub fn generate() -> Self {
        let mut raw = [0u8; RAW_LEN];
        getrandom::fill(&mut raw).expect("the OS random source");
        Self(raw)
    }

    /// Formats as `S1-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
    pub fn format(&self) -> Zeroizing<String> {
        let check = checksum(&self.0);
        let mut chars = [0u8; TOTAL_CHARS];
        // Pack 128 raw bits + 22 checksum bits = 150 bits into 30 x 5-bit symbols.
        let mut bit_pos = 0usize;
        for slot in &mut chars {
            let mut v = 0u8;
            for _ in 0..5 {
                v <<= 1;
                let bit = if bit_pos < RAW_LEN * 8 {
                    let byte = self.0[bit_pos / 8];
                    (byte >> (7 - (bit_pos % 8))) & 1
                } else {
                    let cbit = bit_pos - RAW_LEN * 8;
                    ((check >> (CHECK_BITS - 1 - cbit)) & 1) as u8
                };
                v |= bit;
                bit_pos += 1;
            }
            *slot = ALPHABET[v as usize];
        }
        let mut out = String::with_capacity(PREFIX.len() + TOTAL_CHARS + TOTAL_CHARS / GROUP_SIZE);
        out.push_str(PREFIX);
        for chunk in chars.chunks(GROUP_SIZE) {
            out.push('-');
            out.push_str(std::str::from_utf8(chunk).expect("ASCII"));
        }
        chars.zeroize();
        Zeroizing::new(out)
    }

    /// Parses a formatted secret key, tolerating case, whitespace, dashes and
    /// Crockford confusables (`I`/`L` -> `1`, `O` -> `0`).
    pub fn parse(input: &str) -> Result<Self, CryptoError> {
        let cleaned: Zeroizing<String> = Zeroizing::new(
            input
                .chars()
                .filter(|c| !c.is_ascii_whitespace() && *c != '-')
                .map(|c| match c.to_ascii_uppercase() {
                    'I' | 'L' => '1',
                    'O' => '0',
                    other => other,
                })
                .collect(),
        );
        let Some(body) = cleaned.strip_prefix(PREFIX) else {
            return Err(CryptoError::Malformed("secret key must start with S1".into()));
        };
        if body.len() != TOTAL_CHARS {
            return Err(CryptoError::Malformed("secret key has wrong length".into()));
        }
        let mut raw = Zeroizing::new([0u8; RAW_LEN]);
        let mut got_check = 0u32;
        let mut bit_pos = 0usize;
        for b in body.bytes() {
            let v = decode_char(b).ok_or_else(|| CryptoError::Malformed("secret key has invalid character".into()))?;
            for shift in (0..5).rev() {
                let bit = (v >> shift) & 1;
                if bit_pos < RAW_LEN * 8 {
                    if bit != 0 {
                        raw[bit_pos / 8] |= 1 << (7 - (bit_pos % 8));
                    }
                } else {
                    let cbit = bit_pos - RAW_LEN * 8;
                    if bit != 0 {
                        got_check |= 1u32 << (CHECK_BITS - 1 - cbit);
                    }
                }
                bit_pos += 1;
            }
        }
        if got_check != checksum(&raw) {
            return Err(CryptoError::Malformed("secret key checksum mismatch".into()));
        }
        Ok(Self(*raw))
    }

    /// Derives a 256-bit hex passphrase for `age scrypt` from `(password, self)`.
    /// Length-prefixed so boundary shifting between fields is impossible.
    pub fn combine_passphrase(&self, password: &str) -> Zeroizing<String> {
        let mut h = blake3::Hasher::new_derive_key(CTX_PASSPHRASE);
        h.update(&(password.len() as u32).to_be_bytes());
        h.update(password.as_bytes());
        h.update(&self.0);
        Zeroizing::new(h.finalize().to_hex().to_string())
    }
}

fn checksum(raw: &[u8; RAW_LEN]) -> u32 {
    let hash = blake3::derive_key(CTX_CHECK, raw);
    ((hash[0] as u32) << 14) | ((hash[1] as u32) << 6) | ((hash[2] as u32) >> 2)
}

fn decode_char(b: u8) -> Option<u8> {
    let normalized = match b {
        b'I' | b'L' => b'1',
        b'O' => b'0',
        other => other,
    };
    ALPHABET.iter().position(|&c| c == normalized).map(|i| i as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_format() {
        let key = SecretKey::generate();
        let text = key.format();
        assert_eq!(text.len(), 38);
        assert!(text.starts_with("S1-"));
        assert_eq!(SecretKey::parse(&text).unwrap(), key);
        // Case, whitespace, dashes and Crockford confusables are tolerated.
        let messy = format!("  {}  ", text.to_lowercase().replace('-', " "));
        assert_eq!(SecretKey::parse(&messy).unwrap(), key);
    }

    #[test]
    fn checksum_rejects_typos() {
        let key = SecretKey([0x42; RAW_LEN]);
        let text = key.format();
        let mut tampered = text.as_bytes().to_vec();
        // Flip the last character to a different valid Crockford symbol.
        let last = tampered.len() - 1;
        tampered[last] = if tampered[last] == b'0' { b'1' } else { b'0' };
        assert!(SecretKey::parse(std::str::from_utf8(&tampered).unwrap()).is_err());
        assert!(SecretKey::parse("S2-00000-00000-00000-00000-00000-00000").is_err());
        assert!(SecretKey::parse("S1-SHORT").is_err());
    }

    #[test]
    fn crockford_confusables_normalize() {
        let key = SecretKey([0x01; RAW_LEN]);
        let text = key.format();
        let confused = text.replace('1', "l").replace('0', "o");
        assert_eq!(SecretKey::parse(&confused).unwrap(), key);
    }

    #[test]
    fn combine_passphrase_is_domain_separated_and_pinned() {
        let a = SecretKey([1; RAW_LEN]);
        let b = SecretKey([2; RAW_LEN]);
        let p1 = a.combine_passphrase("pw");
        assert_eq!(p1.len(), 64);
        assert_eq!(p1, a.combine_passphrase("pw"));
        assert_ne!(p1, a.combine_passphrase("pw2"));
        assert_ne!(p1, b.combine_passphrase("pw"));
    }
}
