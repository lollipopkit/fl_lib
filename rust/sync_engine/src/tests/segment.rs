//! The segment sync over a folder.

use super::*;

#[tokio::test]
async fn devices_converge_on_segments() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    a.host.edit("k", "a", Some(json!(1)));
    b.host.edit("k", "b", Some(json!(2)));
    let (sa, sb) = (a.segments(&files, &file).await, b.segments(&files, &file).await);
    sa.sync().await.unwrap();
    sb.sync().await.unwrap();
    sa.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
    assert!(files.names().iter().any(|n| n.starts_with("seg-")));
}

#[tokio::test]
async fn a_gap_is_read_from_a_snapshot_and_covered_segments_go() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let a = Device::new("pw");
    SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*a.host, "dav").await.unwrap();
    let sa = a.segments(&files, &file).await;
    for i in 0..(crate::segment::COMPACT_EVERY + 2) {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        sa.sync().await.unwrap();
    }
    let mine = format!("{:016x}", a.host.device);
    assert!(files.names().contains(&format!("snap-{mine}.age")));
    // Segments the snapshot covers, gone: b reads them from it.
    let first = format!("seg-{mine}-1.age");
    files.delete_blob(first).await.unwrap();
    let b = Device::new("pw");
    SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*b.host, "dav").await.unwrap();
    b.segments(&files, &file).await.sync().await.unwrap();
    assert_eq!(a.host.values(), b.host.values());
}

#[tokio::test]
async fn a_blob_that_has_not_arrived_is_waited_for() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    let big = "y".repeat(200 << 10);
    a.host.edit("font", "f1", Some(json!(big)));
    a.segments(&files, &file).await.sync().await.unwrap();
    // The folder has the segment, not yet the blob it names.
    let blob = files.names().into_iter().find(|n| n.starts_with("op-")).unwrap();
    let held = files.files.lock().unwrap().remove(&blob).unwrap();
    let sb = b.segments(&files, &file).await;
    sb.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), None);
    files.files.lock().unwrap().insert(blob, held);
    sb.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), Some(json!(big)));
}

#[tokio::test]
async fn a_blob_its_device_removed_is_not_waited_for() {
    let (files, file) = (Arc::new(MemFiles::default()), Arc::new(MemKeyFile::default()));
    let (a, b) = (Device::new("pw"), Device::new("pw"));
    for d in [&a, &b] {
        SegmentSync::<MemHost, MemFiles, SyncKey>::bind(&*d.host, "dav").await.unwrap();
    }
    let sa = a.segments(&files, &file).await;
    a.host.edit("font", "f1", Some(json!("x".repeat(200 << 10))));
    sa.sync().await.unwrap();
    // Replaced, and a's snapshot written past it: the old blob goes.
    a.host.edit("font", "f1", Some(json!("new")));
    for i in 0..crate::segment::COMPACT_EVERY {
        a.host.edit("k", &format!("r{i}"), Some(json!(i)));
        sa.sync().await.unwrap();
    }
    let blob = files.names().into_iter().find(|n| n.starts_with("op-")).unwrap();
    files.delete_blob(blob).await.unwrap();
    b.segments(&files, &file).await.sync().await.unwrap();
    assert_eq!(b.host.value("font", "f1"), Some(json!("new")));
    assert_eq!(a.host.values(), b.host.values());
}
