//! The sync on LK Cloud: homebase's log ([LogTransport]) and the account's key
//! file, `identity.age`, written only if unchanged ([KeyFile]).

use std::sync::Arc;

use fl_lkc::Store;
use fl_lkc::sync::{Committed, Condition, Error as LkcError, Kind, LogRead, SyncClient};

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
        Kind::Untrusted => Error::Untrusted(e.detail),
        _ => Error::Remote(e.to_string()),
    }
}

/// [LogTransport] on an app's LK Cloud sync.
pub struct LkcLog<S: Store> {
    pub client: Arc<SyncClient<S>>,
    /// The account's id.
    pub account: String,
}

impl<S: Store> BlobStore for LkcLog<S> {
    fn signs_blobs(&self) -> bool {
        self.client.has_personal_auth()
    }

    async fn put_blob(&self, name: String, body: Vec<u8>) -> Result<()> {
        self.put_blob_signed(name, body).await.map(|_| ())
    }

    async fn put_blob_signed(&self, name: String, body: Vec<u8>) -> Result<bool> {
        let (res, signed) = self.client.upload_blob_bytes_checked(&name, body.clone()).await;
        match res {
            Ok(_) => Ok(signed),
            Err(e) if e.kind == Kind::Changed => match self.get_blob_verified(name.clone(), true).await? {
                None => Err(Error::Untrusted(format!("{name}: server answered 412 for missing blob"))),
                Some((_, true)) => Ok(true),
                Some((remote_bytes, false)) => {
                    if signed && remote_bytes == body {
                        Err(Error::Untrusted(format!("{name}: server stripped signature on upload")))
                    } else {
                        Ok(false)
                    }
                }
            },
            Err(e) => Err(remote(e)),
        }
    }

    async fn get_blob(&self, name: String) -> Result<Option<Vec<u8>>> {
        Ok(self.client.download_blob_bytes(&name).await.map_err(remote)?.map(|(body, _, _)| body))
    }

    async fn get_blob_verified(&self, name: String, allow_retained_unsigned: bool) -> Result<Option<(Vec<u8>, bool)>> {
        let (fetched, verified_auth) = if allow_retained_unsigned {
            self.client.download_retained_blob_bytes_checked(&name).await
        } else {
            self.client.download_blob_bytes_checked(&name).await
        };
        Ok(fetched.map_err(remote)?.map(|(body, _, sig)| (body, verified_auth && sig.is_some())))
    }

    async fn blobs(&self, prefix: String) -> Result<Vec<Listed>> {
        Ok(self
            .client
            .list()
            .await
            .map_err(remote)?
            .into_iter()
            .filter(|f| f.name.starts_with(&prefix))
            .map(|f| Listed { at: rfc3339_ms(&f.updated_at), name: f.name, signed: f.signed.is_some() })
            .collect())
    }

    async fn delete_blob(&self, name: String) -> Result<()> {
        self.client.delete(&name, None).await.map(|_| ()).map_err(remote)
    }
}

impl<S: Store> LogTransport for LkcLog<S> {
    async fn append(&self, key: String, body: Vec<u8>) -> Result<Appended> {
        match self.client.append(&key, body).await {
            Ok(a) => Ok(Appended { log: a.log, seq: a.seq, compact: a.compact }),
            Err(e) => {
                if let Some(Committed::Batch(a)) = e.committed {
                    return Err(Error::AppendPersistFailed {
                        appended: Appended { log: a.log, seq: a.seq, compact: a.compact },
                        detail: e.detail,
                    });
                }
                Err(remote(e))
            }
        }
    }

    async fn read(&self, after: i64, log: Option<String>) -> Result<Page> {
        Ok(match self.client.read_log(after, log.as_deref(), None).await.map_err(remote)? {
            LogRead::Compacted { log, .. } => Page::Compacted { log },
            LogRead::Page { log, batches, more, .. } => Page::Batches {
                log,
                batches: batches.into_iter().map(|b| (b.seq, b.body, b.signed.is_some())).collect(),
                more,
            },
        })
    }

    async fn put_snapshot(&self, seq: i64, body: Vec<u8>) -> Result<bool> {
        match self.client.put_snapshot_bytes(seq, body).await {
            Ok(_) => Ok(true),
            Err(LkcError { kind: Kind::Refused(reason), .. }) if reason == "sync_snapshot_stale" => Ok(false),
            Err(e) => {
                if let Some(Committed::Snapshot { log, seq, .. }) = e.committed {
                    return Err(Error::SnapshotPersistFailed { log, seq, detail: e.detail });
                }
                Err(remote(e))
            }
        }
    }

    async fn flush_committed_snapshot(&self, log: Option<String>, seq: i64, body: Vec<u8>) -> Result<(bool, Option<String>)> {
        self.client
            .flush_committed_snapshot_bytes(&self.account, log.as_deref(), seq, &body)
            .await
            .map_err(|e| match e.kind {
                Kind::Invalid => {
                    if let Some(Committed::Snapshot { log, seq, .. }) = e.committed {
                        return Error::SnapshotPersistFailed { log, seq, detail: e.detail };
                    }
                    Error::Host(e.detail)
                }
                _ => remote(e),
            })
    }

    async fn snapshot(&self) -> Result<Option<SnapshotBody>> {
        Ok(self
            .client
            .download_snapshot_bytes()
            .await
            .map_err(remote)?
            .map(|(s, body)| SnapshotBody { log: s.log, seq: s.seq, body, signed: s.signed.is_some() }))
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
                Err(e) => {
                    if let Some(Committed::File { etag, version }) = e.committed {
                        return Err(Error::KeyFilePersistFailed { version: etag, sync_version: Some(version), detail: e.detail });
                    }
                    Err(remote(e))
                }
            }
        })
    }

    fn flush_committed_write(
        &self,
        body: Vec<u8>,
        if_version: Option<String>,
        _version: String,
        sync_version: Option<i64>,
    ) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            if let Some(ver) = sync_version {
                return self.client.flush_committed_file(&self.account, KEY_FILE, ver).await.map_err(|e| match e.kind {
                    Kind::Invalid => Error::Host(e.detail),
                    _ => remote(e),
                });
            }
            match self.write(body, if_version).await {
                Ok(Some(_)) => Ok(()),
                Ok(None) => Err(Error::Host("committed key-file write watermark remains unpersisted after CAS miss".into())),
                Err(Error::KeyFilePersistFailed { detail, .. }) => Err(Error::Host(detail)),
                Err(e) => Err(e),
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
        LkcError { kind, detail: String::new(), committed: None }
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
