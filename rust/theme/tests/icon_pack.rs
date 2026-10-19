//! Icon packs (`kind = "icons"`): icons chosen apart from the theme.

mod common;

use common::*;
use fl_theme::package::ColorSpec;
use fl_theme::{install, read_installed, read_installed_icon_pack};
use serde_json::{Value as Json, json};

fn pack() -> Json {
    json!({
        "format": 1,
        "schema": {"min": 4, "max": 4},
        "id": "example.devicons",
        "name": "Devicons",
        "kind": "icons",
        "icons": {
            "images": {"file.py": "icons/file_py.svg", "tab.server": "icons/tab_server.svg"},
            "colors": {"tab.server": "primary"},
        },
    })
}

const FILES: [(&str, &[u8]); 2] =
    [("icons/file_py.svg", SVG_ICON.as_bytes()), ("icons/tab_server.svg", SVG_ICON.as_bytes())];

fn why(manifest: &Json, files: &[(&str, &[u8])]) -> String {
    install(&bundle(manifest, files)).unwrap_err().0
}

#[test]
fn installs_and_reads_back() {
    let p = install(&bundle(&pack(), &FILES)).unwrap();
    assert!(p.themes.is_empty());
    let icons = p.icon_pack.as_ref().unwrap();
    assert_eq!(icons.images, ["file.py", "tab.server"]);
    assert_eq!(icons.colors["tab.server"], ColorSpec::Role("primary".into()));

    let layout = p.layout().unwrap();
    let paths: Vec<&str> = layout.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(paths, ["manifest.toml", "icons/file_py.svg", "icons/tab_server.svg"]);
    let manifest = std::str::from_utf8(&layout[0].1).unwrap();
    let read = read_installed_icon_pack(manifest, &["file_py.svg".into(), "tab_server.svg".into()]).unwrap();
    assert_eq!((read.id.as_str(), read.name.as_str()), ("example.devicons", "Devicons"));
    assert_eq!(read.icon_files["file.py"], "file_py.svg");
    assert_eq!(read.icon_colors["tab.server"], ColorSpec::Role("primary".into()));

    // Read back as strictly as it was installed.
    let older = manifest.replace("min = 4", "min = 3");
    assert_eq!(read_installed_icon_pack(&older, &["file_py.svg".into()]).unwrap_err().0, "An icon pack needs schema 4");
    let empty = "format = 1\nid = \"example.devicons\"\nname = \"Devicons\"\nkind = \"icons\"\n\
                 [schema]\nmin = 4\nmax = 4\n[icons]\nimages = []\n";
    assert_eq!(read_installed_icon_pack(empty, &[]).unwrap_err().0, "An icon pack carries no icons");

    let extra = format!("{manifest}\n[shapes]\ncard = 3\n");
    assert_eq!(read_installed_icon_pack(&extra, &["file_py.svg".into(), "tab_server.svg".into()]).unwrap_err().0, "Unknown icon pack section");
    let styled = manifest.replace("[icons]\n", "[icons]\nstyle = \"classic\"\n");
    assert_ne!(styled, manifest);
    assert_eq!(read_installed_icon_pack(&styled, &["file_py.svg".into(), "tab_server.svg".into()]).unwrap_err().0, "Unknown icon field");

    let twice = manifest.replace("\"file.py\",", "\"file.py\", \"file.py\",");
    assert_ne!(twice, manifest);
    assert_eq!(read_installed_icon_pack(&twice, &["file_py.svg".into(), "tab_server.svg".into()]).unwrap_err().0, "Invalid icon keys");

    // Neither reader takes the other's manifest.
    assert!(read_installed(manifest, &["file_py.svg".into()]).is_err());
    let theme = install(&bundle(&package("gradient"), &[])).unwrap();
    let theme_manifest = String::from_utf8(theme.layout().unwrap()[0].1.clone()).unwrap();
    assert!(read_installed_icon_pack(&theme_manifest, &[]).is_err());
}

#[test]
fn carries_up_to_128_icons() {
    let names: Vec<String> = (0..128).map(|i| format!("icons/file_e{i}.svg")).collect();
    let mut m = pack();
    m["icons"] = json!({"images": {}});
    for (i, name) in names.iter().enumerate() {
        m["icons"]["images"][format!("file.e{i}")] = json!(name);
    }
    let files: Vec<(&str, &[u8])> = names.iter().map(|n| (n.as_str(), SVG_ICON.as_bytes())).collect();
    assert_eq!(install(&bundle(&m, &files)).unwrap().icon_pack.unwrap().images.len(), 128);
}

#[test]
fn refusals_name_their_reason() {
    let mut m = pack();
    m["schema"] = json!({"min": 3, "max": 4});
    assert_eq!(why(&m, &FILES), "An icon pack needs schema 4");

    for section in ["colors", "shapes", "modes", "splash"] {
        let mut m = pack();
        m[section] = json!({});
        assert_eq!(why(&m, &FILES), "Unknown icon pack section", "{section}");
    }

    let mut m = pack();
    m["icons"]["style"] = json!("classic");
    assert_eq!(why(&m, &FILES), "Unknown icon field");

    let mut m = pack();
    m["icons"] = json!({"images": {}});
    assert_eq!(why(&m, &[]), "An icon pack carries no icons");

    let mut m = pack();
    m["kind"] = json!("fonts");
    assert_eq!(why(&m, &FILES), "Unknown package kind");

    let mut m = pack();
    m["icons"]["colors"] = json!({"file.rs": "primary"});
    assert_eq!(why(&m, &FILES), "Icon color without an image");

    let mut extra = FILES.to_vec();
    extra.push(("background.png", &[0]));
    assert_eq!(why(&pack(), &extra), "Unexpected theme asset");

    let mut m = pack();
    m["icons"]["images"]["file.py"] = json!("icons/file_rs.svg");
    assert_eq!(why(&m, &FILES), "Invalid icon path");
}
