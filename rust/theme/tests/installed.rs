//! What installing writes and what reading it back answers: the round trip
//! fl_lib relies on (`_write`, `installed`).

mod common;

use common::*;
use fl_theme::package::{ColorSpec, INSTALLED_BACKGROUND};
use fl_theme::{Package, install, install_files, installed_variants, read_installed};
use indexmap::IndexMap;
use serde_json::json;
use sha2::{Digest, Sha256};

fn layout(p: &Package) -> IndexMap<String, Vec<u8>> {
    p.layout().unwrap().into_iter().collect()
}

fn text(files: &IndexMap<String, Vec<u8>>, path: &str) -> String {
    String::from_utf8(files[path].clone()).unwrap()
}

/// The icon files a directory holds for the keys a manifest names, as the
/// app looks them up.
fn icons_in(files: &IndexMap<String, Vec<u8>>, dir: &str) -> Vec<String> {
    files.keys().filter_map(|p| p.strip_prefix(&format!("{dir}icons/"))).map(str::to_string).collect()
}

#[test]
fn a_package_reads_back_as_it_was_checked() {
    let mut data = package2();
    data["schema"] = json!({"min": 3, "max": 3});
    data["icons"] = json!({"style": "mingcute", "images": {"tab.server": "icons/tab_server.svg"}, "colors": {"tab.server": "primary"}});
    data["splash"] = json!({"color": 0xff112233u32, "duration": 900, "logo": "splash_logo.svg"});
    data["background"] = json!({"type": "image", "image": "background.png", "opacity": 0.3, "blur": 2, "tile": 64});
    data["components"] = json!({"card": {"radius": 20, "backgroundColor": "surface"}, "dark": {"card": {"radius": 4}}});
    data["layout"] = json!({"density": "compact"});
    data["colors"]["palette"] = json!({"light": {"primary": 0xff6750a4u32}});
    let p = install(&bundle(
        &data,
        &[
            ("icons/tab_server.svg", SVG_ICON.as_bytes()),
            ("splash_logo.svg", SVG_ICON.as_bytes()),
            ("background.png", &png_sized(64, 64)),
        ],
    ))
    .unwrap();
    let files = layout(&p);
    let mut paths: Vec<&str> = files.keys().map(String::as_str).collect();
    paths.sort();
    assert_eq!(paths, [INSTALLED_BACKGROUND, "icons/tab_server.svg", "manifest.toml", "splash_logo.svg"]);
    assert_eq!(installed_variants(&text(&files, "manifest.toml")).unwrap(), None);

    let back = read_installed(&text(&files, "manifest.toml"), &icons_in(&files, "")).unwrap();
    let theme = &p.themes[0];
    assert_eq!((back.id.as_str(), back.name.as_str()), ("example.amethyst", "Amethyst"));
    assert_eq!((back.schema_min, back.schema_max), (3, 3));
    assert_eq!(back.modes, theme.modes);
    assert_eq!((back.mode, back.seed, back.system_color), (theme.mode, theme.seed, theme.system_color));
    assert_eq!(back.palette_light, theme.palette_light);
    assert_eq!(back.components, theme.components);
    assert_eq!(back.density.as_deref(), Some("compact"));
    assert_eq!(back.icon_style, "mingcute");
    assert_eq!(back.icon_files["tab.server"], "tab_server.svg");
    // An SVG and a PNG for one key: the SVG, as the app has always looked.
    let both = read_installed(&text(&files, "manifest.toml"), &["tab_server.png".into(), "tab_server.svg".into()]).unwrap();
    assert_eq!(both.icon_files["tab.server"], "tab_server.svg");
    assert_eq!(back.icon_colors["tab.server"], ColorSpec::Role("primary".into()));
    assert_eq!(back.background, theme.background);
    assert_eq!(back.shapes, theme.shapes);
    assert_eq!(back.splash, theme.splash);
}

#[test]
fn variants_install_as_a_list_and_a_theme_each() {
    let mut data = package2();
    data["schema"] = json!({"min": 3, "max": 3});
    data["variants"] = json!({
        "trans": {"name": "Trans", "colors": {"seed": 0xff5bcefau32}},
        "rainbow": {"name": "Rainbow"},
    });
    let p = install(&bundle(&data, &[])).unwrap();
    let files = layout(&p);
    let variants = installed_variants(&text(&files, "manifest.toml")).unwrap().unwrap();
    assert_eq!(variants.iter().map(|v| v.key.as_str()).collect::<Vec<_>>(), ["trans", "rainbow"]);
    let trans = read_installed(&text(&files, "variants/trans/manifest.toml"), &[]).unwrap();
    assert_eq!(trans.seed, 0xff5bcefa);
    assert_eq!(trans.name, "Amethyst");
    assert!(files.contains_key("variants/rainbow/manifest.toml"));
}

#[test]
fn a_read_back_refuses_what_an_install_would() {
    let p = install(&bundle(&package("none"), &[])).unwrap();
    let manifest = text(&layout(&p), "manifest.toml");
    assert!(read_installed(&manifest, &[]).is_ok());
    // An icon the manifest names with no file for it.
    let named = manifest.replace("images = []", "images = [\"tab.server\"]");
    assert!(read_installed(&named, &[]).is_err());
    assert!(read_installed("format = 2", &[]).is_err());
    assert!(installed_variants("variants = [{ key = \"Bad Key\", name = \"x\" }]").is_err());
    assert!(
        installed_variants("variants = [{ key = \"trans\", name = \"a\" }, { key = \"trans\", name = \"b\" }]").is_err(),
        "two entries for one directory"
    );
    let many: Vec<String> = (0..=fl_theme::package::MAX_VARIANTS).map(|i| format!("{{ key = \"v{i}\", name = \"v\" }}")).collect();
    assert!(installed_variants(&format!("variants = [{}]", many.join(", "))).is_err(), "more than a package may carry");
}

#[test]
fn files_are_one_installation_by_their_digest() {
    let manifest = toml::to_string(&to_toml(&package("none"))).unwrap();
    let mut files = IndexMap::new();
    files.insert("manifest.toml".to_string(), manifest.into_bytes());
    let p = install_files(files.clone()).unwrap();
    // fl_lib's `installAssets`: each path and its bytes, length-prefixed
    // (big-endian u32), in path order.
    let mut digest = Sha256::new();
    for (path, bytes) in &files {
        digest.update((path.len() as u32).to_be_bytes());
        digest.update(path.as_bytes());
        digest.update((bytes.len() as u32).to_be_bytes());
        digest.update(bytes);
    }
    let expected: String = digest.finalize().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(p.installation_id, expected);
    assert!(install_files(IndexMap::new()).is_err());
}

#[test]
fn every_builtin_theme_installs() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/themes");
    let mut seen = 0;
    for dir in std::fs::read_dir(&root).unwrap() {
        let dir = dir.unwrap().path();
        let mut files = IndexMap::new();
        fn walk(base: &std::path::Path, dir: &std::path::Path, out: &mut IndexMap<String, Vec<u8>>) {
            for e in std::fs::read_dir(dir).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    walk(base, &p, out);
                } else {
                    out.insert(p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/"), std::fs::read(&p).unwrap());
                }
            }
        }
        walk(&dir, &dir, &mut files);
        let p = install_files(files).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        assert!(!p.layout().unwrap().is_empty());
        seen += 1;
    }
    assert!(seen > 0);
}

/// Opt-in: the installations an app already wrote, by the code before this
/// one, read back; each is printed as read or refused. `FL_THEME_INSTALLED_DIR`
/// is a themes directory (several, `:`-separated); read only.
#[test]
#[ignore]
fn installations_already_on_disk_read_back() {
    let Ok(dirs) = std::env::var("FL_THEME_INSTALLED_DIR") else { return };
    let mut read = 0;
    for root in dirs.split(':') {
        for entry in std::fs::read_dir(root).unwrap() {
            let dir = entry.unwrap().path();
            let Ok(manifest) = std::fs::read_to_string(dir.join("manifest.toml")) else { continue };
            let icons = |dir: &std::path::Path| -> Vec<String> {
                std::fs::read_dir(dir.join("icons"))
                    .map(|it| it.map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect())
                    .unwrap_or_default()
            };
            match installed_variants(&manifest).unwrap_or_else(|e| panic!("{}: {e}", dir.display())) {
                Some(variants) => {
                    for v in variants {
                        let vdir = dir.join("variants").join(&v.key);
                        let m = std::fs::read_to_string(vdir.join("manifest.toml")).unwrap();
                        match read_installed(&m, &icons(&vdir)) {
                            Ok(t) => {
                                eprintln!("ok      {} ({})", t.name, v.key);
                                read += 1;
                            }
                            Err(e) => eprintln!("refused {}: {e}", vdir.display()),
                        }
                    }
                }
                None => {
                    match read_installed(&manifest, &icons(&dir)) {
                        Ok(t) => {
                            eprintln!("ok      {}", t.name);
                            read += 1;
                        }
                        // What the Dart reader refused too (an installation
                        // from before a rule it now holds) is printed, not
                        // failed: compare by hand.
                        Err(e) => eprintln!("refused {}: {e}", dir.display()),
                    }
                }
            }
        }
    }
    eprintln!("read {read} installed themes");
    assert!(read > 0);
}
