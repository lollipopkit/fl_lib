//! The key file's age sealing: identities, and what is sealed with a password.

use super::*;

pub(super) fn generate() -> String {
    use age::secrecy::ExposeSecret;
    age::x25519::Identity::generate().to_string().expose_secret().to_string()
}

pub(super) fn parse_identities(identities: &[String]) -> Result<Vec<age::x25519::Identity>> {
    identities.iter().map(|i| age::x25519::Identity::from_str(i).map_err(|e| Error::Unreadable(format!("not an age identity: {e}")))).collect()
}

pub(super) fn lines(text: Option<&str>, comments: bool) -> Vec<String> {
    text.unwrap_or_default().split('\n').map(str::trim).filter(|t| !t.is_empty() && (comments || !t.starts_with('#'))).map(str::to_string).collect()
}

/// [sealed] opened with [pwd]: its epoch and keys, the newest first; `None`
/// when [pwd] does not open it. A file with no epoch line is epoch 0.
pub(super) fn read(sealed: &[u8], pwd: &str) -> Result<Option<(i64, Vec<String>)>> {
    let Some(plain) = open_with_password(sealed, pwd)? else { return Ok(None) };
    let text = Zeroizing::new(String::from_utf8((*plain).clone()).map_err(|_| Error::Unreadable("identity.age is not text".into()))?);
    let all = lines(Some(&text), true);
    let epoch = all.first().filter(|l| l.starts_with('#')).and_then(|l| epoch_of(l)).unwrap_or(0);
    let identities: Vec<String> = all.into_iter().filter(|l| !l.starts_with('#')).collect();
    if identities.is_empty() {
        return Err(Error::Unreadable("identity.age holds no key".into()));
    }
    Ok(Some((epoch, identities)))
}

/// `# … epoch <n>`: the `epoch` a word of its own.
fn epoch_of(line: &str) -> Option<i64> {
    let at = line.rfind("epoch ")?;
    if at > 0 && line.as_bytes()[at - 1].is_ascii_alphanumeric() {
        return None;
    }
    let n = &line[at + "epoch ".len()..];
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    n.parse().ok()
}

/// [plain] sealed with [pwd], armored, as `age -p -a` writes it.
pub fn seal_with_password(plain: &[u8], pwd: &str) -> Result<Vec<u8>> {
    let mut recipient = age::scrypt::Recipient::new(SecretString::from(pwd.to_string()));
    recipient.set_work_factor(WORK_FACTOR);
    let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient)).map_err(|e| Error::Host(e.to_string()))?;
    let mut out = Vec::new();
    let armored = age::armor::ArmoredWriter::wrap_output(&mut out, age::armor::Format::AsciiArmor).map_err(|e| Error::Host(e.to_string()))?;
    let mut w = encryptor.wrap_output(armored).map_err(|e| Error::Host(e.to_string()))?;
    w.write_all(plain).map_err(|e| Error::Host(e.to_string()))?;
    w.finish().and_then(|armored| armored.finish()).map_err(|e| Error::Host(e.to_string()))?;
    Ok(out)
}

/// [sealed] (armored or binary) opened with [pwd]; `None` when [pwd] does not
/// open it.
pub fn open_with_password(sealed: &[u8], pwd: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let start = sealed.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(sealed.len());
    let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(&sealed[start..])).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut identity = age::scrypt::Identity::new(SecretString::from(pwd.to_string()));
    identity.set_max_work_factor(MAX_WORK_FACTOR);
    let mut r = match decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity)) {
        Ok(r) => r,
        Err(age::DecryptError::DecryptionFailed | age::DecryptError::NoMatchingKeys) => return Ok(None),
        Err(e) => return Err(Error::Unreadable(format!("{e:?}"))),
    };
    let mut out = Zeroizing::new(Vec::new());
    r.read_to_end(&mut out).map_err(|e| Error::Unreadable(e.to_string()))?;
    Ok(Some(out))
}

/// [sealed] opened with whichever of [identities] it is sealed to.
pub fn open_with(sealed: &[u8], identities: &[age::x25519::Identity]) -> Result<Vec<u8>> {
    if identities.is_empty() {
        return Err(Error::Unreadable("no key here".into()));
    }
    let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(sealed)).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut r = decryptor.decrypt(identities.iter().map(|i| i as &dyn age::Identity)).map_err(|e| Error::Unreadable(format!("{e:?}")))?;
    let mut out = Vec::new();
    r.read_to_end(&mut out).map_err(|e| Error::Unreadable(e.to_string()))?;
    Ok(out)
}
