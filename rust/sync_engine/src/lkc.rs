//! The sync on LK Cloud: homebase's log ([LogTransport]) and the account's key
//! file, `identity.age`, written only if unchanged ([KeyFile]).

use std::sync::Arc;

use fl_lkc::Store;
use fl_lkc::sync::{Condition, Error as LkcError, Kind, LogRead, SyncClient};

use crate::key::{BoxFuture, KeyFile, Versioned};
use crate::log::{Appended, LogTransport, Page, SnapshotBody};
use crate::{BlobStore, Error, Listed, Result};

/// The key file's name beside the log.
pub const KEY_FILE: &str = "identity.age";

fn remote(e: LkcError) -> Error {
    match e.kind {
        Kind::Refused(reason) if reason == "sync_log_full" => Error::LogFull,
        Kind::Refused(reason) => Error::Refused(reason),
        // Over what any plan keeps: the plan's own refusal, as far as anyone
        // can do anything about it.
        Kind::TooLarge => Error::Refused("sync_file_too_large".into()),
        Kind::SignedOut => Error::SignedOut,
        _ => Error::Remote(e.to_string()),
    }
}

/// [LogTransport] on an app's LK Cloud sync.
pub struct LkcLog<S: Store>(pub Arc<SyncClient<S>>);

impl<S: Store> BlobStore for LkcLog<S> {
    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        match self.0.upload_bytes(&name, body, Condition::Absent).await {
            Ok(_) => Ok(()),
            // Named by its content: the one there is this one.
            Err(e) if e.kind == Kind::Changed => Ok(()),
            Err(e) => Err(remote(e)),
        }
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        Ok(self.0.download_bytes(&name).await.map_err(remote)?.map(|(body, _, _)| body))
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        Ok(self.0.list().await.map_err(remote)?.into_iter().filter(|f| f.name.starts_with(&prefix)).map(|f| Listed { at: rfc3339_ms(&f.updated_at), name: f.name }).collect())
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.0.delete(&name, None).await.map(|_| ()).map_err(remote)
    }
}

impl<S: Store> LogTransport for LkcLog<S> {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        let a = self.0.append(&key, body).await.map_err(remote)?;
        Ok(Appended { log: a.log, seq: a.seq, compact: a.compact })
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        Ok(match self.0.read_log(after, log.as_deref(), None).await.map_err(remote)? {
            LogRead::Compacted { log, .. } => Page::Compacted { log },
            LogRead::Page { log, batches, more, .. } => Page::Batches { log, batches: batches.into_iter().map(|b| (b.seq, b.body)).collect(), more },
        })
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        match self.0.put_snapshot_bytes(seq, body).await {
            Ok(_) => Ok(true),
            Err(LkcError { kind: Kind::Refused(reason), .. }) if reason == "sync_snapshot_stale" => Ok(false),
            Err(e) => Err(remote(e)),
        }
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        Ok(self.0.download_snapshot_bytes().await.map_err(remote)?.map(|(s, body)| SnapshotBody { log: s.log, seq: s.seq, body }))
    }
}

/// The account's key file on LK Cloud. Writes are ordered: none read is none
/// there.
pub struct LkcKeyFile<S: Store> {
    pub client: Arc<SyncClient<S>>,
    /// The account's id.
    pub account: String,
}

impl<S: Store> KeyFile for LkcKeyFile<S> {
    fn id(&self) -> String {
        self.account.clone()
    }

    fn read(&self) -> BoxFuture<'_, Result<Option<Versioned>>> {
        Box::pin(async move { Ok(self.client.download_bytes(KEY_FILE).await.map_err(remote)?.map(|(body, etag, _)| (body, etag))) })
    }

    fn write(&self, body: Vec<u8>, if_version: Option<String>) -> BoxFuture<'_, Result<Option<String>>> {
        Box::pin(async move {
            let condition = if_version.map_or(Condition::Absent, Condition::Match);
            match self.client.upload_bytes(KEY_FILE, body, condition).await {
                Ok(v) => Ok(Some(v)),
                Err(e) if e.kind == Kind::Changed => Ok(None),
                Err(e) => Err(remote(e)),
            }
        })
    }

    fn can_create(&self) -> BoxFuture<'_, Result<bool>> {
        Box::pin(async { Ok(true) })
    }
}

/// An RFC 3339 time (`2026-11-10T08:00:00.123Z`, `…+08:00`) as Unix ms.
pub fn rfc3339_ms(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't' | b' ') || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, sec) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
    let mut i = 19;
    let mut ms = 0;
    if b.get(i) == Some(&b'.') {
        let start = i + 1;
        i = start;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        let frac = &s[start..i];
        let digits: String = frac.chars().chain("000".chars()).take(3).collect();
        ms = digits.parse::<i64>().ok()?;
    }
    let offset_min = match b.get(i)? {
        b'Z' | b'z' => 0,
        sign @ (b'+' | b'-') => {
            let oh = num(i + 1..i + 3)?;
            let om = num(i + 4..i + 6)?;
            let o = oh * 60 + om;
            if *sign == b'-' { -o } else { o }
        }
        _ => return None,
    };
    // Days from the civil date (Howard Hinnant's days_from_civil).
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(((days * 24 + h) * 60 + mi - offset_min) * 60_000 + sec * 1000 + ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lkc(kind: Kind) -> LkcError {
        LkcError { kind, detail: String::new() }
    }

    #[test]
    fn homebase_refusals_say_what_they_are() {
        assert_eq!(remote(lkc(Kind::Refused("sync_log_full".into()))), Error::LogFull);
        assert_eq!(remote(lkc(Kind::Refused("sync_quota".into()))), Error::Refused("sync_quota".into()));
        assert_eq!(remote(lkc(Kind::Refused("sync_file_too_large".into()))), Error::Refused("sync_file_too_large".into()));
        assert_eq!(remote(lkc(Kind::TooLarge)), Error::Refused("sync_file_too_large".into()));
        assert_eq!(remote(lkc(Kind::SignedOut)), Error::SignedOut);
        assert!(matches!(remote(lkc(Kind::Unreachable)), Error::Remote(_)));
    }
}
