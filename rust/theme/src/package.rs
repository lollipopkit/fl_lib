//! Installing a package: fl_lib `ThemePackages._installAssets` and
//! `_prepare`, check for check and in the same order, so a refusal reads the
//! same in the app and the panel.

use std::collections::HashSet;

use indexmap::IndexMap;
use serde::Serialize;
use serde_json::Map;
use sha2::{Digest, Sha256};
use toml::{Table, Value};

use crate::archive::{self, Assets};
use crate::components::{self, Components};
use crate::error::{Result, ThemeError, fail};
use crate::palette::{self, Scheme, is_role};
use crate::{image, svg};

pub const SUPPORTED_SCHEMA_MIN: u32 = 1;
pub const SUPPORTED_SCHEMA_MAX: u32 = 4;
/// What schema 2 added: SVG icons, per-icon colors, the splash.
const FEATURE_SCHEMA: u32 = 2;
/// What schema 3 added: components beyond schema 2's, `[layout]`,
/// `background.tile`, `[variants]`.
const COMPONENT_SCHEMA: u32 = 3;
/// What schema 4 added: more than [MAX_ICONS_BEFORE_ICON_SCHEMA] icons, and
/// icon packs (`kind = "icons"`).
const ICON_SCHEMA: u32 = 4;

pub const MAX_PACKAGE_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const MAX_BACKGROUND_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_SPLASH_LOGO_BYTES: usize = 512 * 1024;
pub(crate) const MAX_ICON_BYTES: usize = 256 * 1024;
pub(crate) const MAX_MANIFEST_BYTES: usize = 64 * 1024;
const MAX_ICONS: usize = 128;
/// What a build reading only schema 3 or older accepts.
const MAX_ICONS_BEFORE_ICON_SCHEMA: usize = 48;
pub const MAX_VARIANTS: usize = 8;
/// The manifest, its icons, a background and a splash logo, and for each
/// variant a background, a splash logo and its directory entry.
pub(crate) const MAX_ASSETS: usize = MAX_ICONS + 3 + MAX_VARIANTS * 3;
const MAX_NAME_LENGTH: usize = 80;
const MAX_BACKGROUND_OPACITY: f64 = 0.6;
const MAX_BACKGROUND_BLUR: f64 = 30.0;
const MIN_BACKGROUND_TILE: f64 = 16.0;
const MAX_BACKGROUND_TILE: f64 = 1024.0;

const SECTIONS: [&str; 13] = [
    "format",
    "schema",
    "id",
    "name",
    "modes",
    "colors",
    "icons",
    "background",
    "shapes",
    "components",
    "layout",
    "splash",
    "variants",
];
/// What an icon pack may say: no colors, shapes or anything else a theme
/// draws, so it goes with whichever theme is in use.
const ICON_PACK_SECTIONS: [&str; 6] = ["format", "schema", "id", "name", "kind", "icons"];
/// An icon pack has no `style`: which built-in glyphs a missing key falls back
/// to is the theme's.
const ICON_PACK_FIELDS: [&str; 2] = ["images", "colors"];
const VARIANT_FIELDS: [&str; 8] = ["name", "colors", "icons", "background", "splash", "shapes", "components", "layout"];
const ICON_FIELDS: [&str; 3] = ["style", "images", "colors"];
const BACKGROUND_FIELDS: [&str; 5] = ["type", "image", "opacity", "blur", "tile"];
const SPLASH_FIELDS: [&str; 3] = ["color", "logo", "duration"];
pub const BACKGROUND_IMAGES: [&str; 3] = ["background.png", "background.jpg", "background.jpeg"];
const SPLASH_LOGOS: [&str; 4] = ["splash_logo.png", "splash_logo.jpg", "splash_logo.jpeg", "splash_logo.svg"];
const SPLASH_MIN_DURATION: i64 = 100;
const SPLASH_MAX_DURATION: i64 = 3000;
const SPLASH_DEFAULT_DURATION: i64 = 600;

/// A theme's id, and therefore the file a repository describes it in.
pub fn is_id(id: &str) -> bool {
    matches_pattern(id, 64, |c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
}

/// A `[variants.<key>]` key, and the directory the variant installs to.
pub fn is_variant_key(key: &str) -> bool {
    matches_pattern(key, 32, |c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '-'))
}

/// `^[a-z0-9][rest]{0,max-1}$`.
fn matches_pattern(s: &str, max: usize, rest: impl Fn(char) -> bool) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else { return false };
    (first.is_ascii_lowercase() || first.is_ascii_digit()) && s.len() <= max && chars.all(rest)
}

/// `^[a-z][a-z0-9]*(\.[a-z][a-zA-Z0-9]*)+$`: dotted lowercase words.
fn is_icon_key(key: &str) -> bool {
    let mut parts = key.split('.');
    let Some(head) = parts.next() else { return false };
    let word = |w: &str, rest: &dyn Fn(char) -> bool| {
        let mut c = w.chars();
        c.next().is_some_and(|f| f.is_ascii_lowercase()) && c.all(rest)
    };
    if !word(head, &|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        return false;
    }
    let mut more = 0;
    for part in parts {
        if !word(part, &|c| c.is_ascii_alphanumeric()) {
            return false;
        }
        more += 1;
    }
    more > 0
}

/// A directory entry an archive may carry: `icons/`, `variants/` and
/// `variants/<key>/`.
pub(crate) fn is_directory_entry(path: &str) -> bool {
    path == "icons/"
        || path == "variants/"
        || path
            .strip_prefix("variants/")
            .and_then(|rest| rest.strip_suffix('/'))
            .is_some_and(is_variant_key)
}

// ---- the installed model ---------------------------------------------------

/// A color as a manifest writes one: an ARGB integer or a palette role.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum ColorSpec {
    Argb(u32),
    Role(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Variant {
    pub key: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Icons {
    /// `classic` or `mingcute`.
    pub style: String,
    /// The keys the package carries an image for.
    pub images: Vec<String>,
    pub colors: IndexMap<String, ColorSpec>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Background {
    /// `none`, `gradient` or `image`.
    pub style: String,
    pub opacity: f64,
    pub blur: f64,
    /// The logical width one repeat of the image takes, or 0 for one copy.
    pub tile: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Shapes {
    pub card: f64,
    pub tile: f64,
    pub button: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Splash {
    pub color: ColorSpec,
    pub duration: u32,
    pub logo: Option<String>,
}

/// The files a theme installs, by kind.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Files {
    pub background: Option<Vec<u8>>,
    /// File name inside `icons/` to its bytes.
    pub icons: IndexMap<String, Vec<u8>>,
    /// The logo's file name to its bytes.
    pub splash_logo: Option<(String, Vec<u8>)>,
}

/// One theme: a package, or one of its variants drawn over its base.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Theme {
    pub variant: Option<Variant>,
    /// `light`, `dark` or both. One locks the brightness.
    pub modes: Vec<String>,
    /// The initial preference: 0 system, 1 light, 2 dark.
    pub mode: u8,
    pub seed: u32,
    pub system_color: bool,
    pub palette_light: IndexMap<String, u32>,
    pub palette_dark: IndexMap<String, u32>,
    /// What the app draws in each brightness: the seed's scheme with the
    /// palette over it.
    pub scheme_light: Scheme,
    pub scheme_dark: Scheme,
    /// The accent and neutral palettes, by tone (`palette::tones`).
    pub accent_tones: palette::Tones,
    pub neutral_tones: palette::Tones,
    pub icons: Icons,
    pub background: Background,
    pub shapes: Shapes,
    pub splash: Option<Splash>,
    pub components: Map<String, serde_json::Value>,
    pub density: Option<String>,
    #[serde(skip)]
    pub files: Files,
}

/// A checked package.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Package {
    /// SHA-256 of the package bytes, lowercase hex: what one installation is
    /// called, and what a store listing's digest is compared with.
    pub installation_id: String,
    pub id: String,
    pub name: String,
    pub schema_min: u32,
    pub schema_max: u32,
    /// One theme, or one per variant in the manifest's order; none for an
    /// icon pack.
    pub themes: Vec<Theme>,
    /// What an icon pack carries; None for a theme.
    pub icon_pack: Option<IconPack>,
}

/// An icon pack: icons chosen apart from the theme, drawn over it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IconPack {
    /// The keys the pack carries an image for.
    pub images: Vec<String>,
    pub colors: IndexMap<String, ColorSpec>,
    /// File name inside `icons/` to its bytes.
    #[serde(skip)]
    pub files: IndexMap<String, Vec<u8>>,
}

/// What `kind` a manifest gives: an icon pack, or (none) a theme.
fn is_icon_pack(data: &Table) -> Result<bool> {
    match data.get("kind") {
        None => Ok(false),
        Some(Value::String(k)) if k == "icons" => Ok(true),
        Some(_) => fail("Unknown package kind"),
    }
}

// ---- installing ------------------------------------------------------------

/// Reads and checks a `.fsbt`.
pub fn install(bytes: &[u8]) -> Result<Package> {
    if bytes.is_empty() || bytes.len() > MAX_PACKAGE_BYTES {
        return fail("Invalid theme package size");
    }
    let assets = archive::read(bytes)?;
    let installation_id = hex(&Sha256::digest(bytes));
    install_assets(&assets, installation_id)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn install_assets(assets: &Assets, installation_id: String) -> Result<Package> {
    let source = std::str::from_utf8(&assets["manifest.toml"]).map_err(|_| ThemeError::new("Invalid TOML manifest"))?;
    let data = decode_manifest(source)?;
    if !matches!(data.get("format"), Some(Value::Integer(1))) && data.get("format") != Some(&Value::Float(1.0))
        || data.contains_key("appIcon")
        || data.contains_key("font")
    {
        return fail("Unsupported theme package");
    }
    if is_icon_pack(&data)? {
        return install_icon_pack(&data, assets, installation_id);
    }
    if !data.keys().all(|k| SECTIONS.contains(&k.as_str())) {
        return fail("Unknown theme section");
    }
    let (schema_min, schema_max) = schema_range(data.get("schema"))?;

    let mut used: HashSet<String> = HashSet::from(["manifest.toml".to_string()]);
    let mut themes = Vec::new();
    if let Some(raw) = data.get("variants") {
        if schema_min < COMPONENT_SCHEMA {
            return fail(format!("This theme needs schema {COMPONENT_SCHEMA}"));
        }
        let table = map(Some(raw), "variants")?;
        if table.is_empty() || table.len() > MAX_VARIANTS {
            return fail("Invalid theme variants");
        }
        let mut base = data.clone();
        base.remove("variants");
        for (key, value) in table {
            if !is_variant_key(key) {
                return fail("Invalid variant key");
            }
            let overrides = map(Some(value), "variant")?;
            if !overrides.keys().all(|k| VARIANT_FIELDS.contains(&k.as_str())) {
                return fail("Unknown variant field");
            }
            // One set of icon files for the package.
            if let Some(Value::Table(icons)) = overrides.get("icons")
                && icons.contains_key("images")
            {
                return fail("A variant cannot carry icon images");
            }
            let variant_name = label(overrides.get("name"), "variant name")?;
            let (view, origin) = variant_assets(assets, key);
            let mut overrides = overrides.clone();
            overrides.remove("name");
            let (mut theme, theme_used) = prepare(&merge(&base, &overrides), &view)?;
            used.extend(theme_used.into_iter().map(|p| origin.get(&p).cloned().unwrap_or(p)));
            theme.variant = Some(Variant { key: key.clone(), name: variant_name });
            themes.push(theme);
        }
    } else {
        let (theme, theme_used) = prepare(&data, assets)?;
        used.extend(theme_used);
        themes.push(theme);
    }
    if assets.keys().any(|path| !is_directory_entry(path) && !used.contains(path)) {
        return fail("Unexpected theme asset");
    }
    // Checked by every theme it was prepared as.
    let id = match data.get("id") {
        Some(Value::String(id)) => id.clone(),
        _ => return fail("Invalid theme id"),
    };
    let name = label(data.get("name"), "name")?;
    Ok(Package { installation_id, id, name, schema_min, schema_max, themes, icon_pack: None })
}

fn install_icon_pack(data: &Table, assets: &Assets, installation_id: String) -> Result<Package> {
    if !data.keys().all(|k| ICON_PACK_SECTIONS.contains(&k.as_str())) {
        return fail("Unknown icon pack section");
    }
    let (schema_min, schema_max) = schema_range(data.get("schema"))?;
    if schema_min < ICON_SCHEMA {
        return fail(format!("An icon pack needs schema {ICON_SCHEMA}"));
    }
    let id = match data.get("id") {
        Some(Value::String(id)) if is_id(id) => id.clone(),
        _ => return fail("Invalid theme id"),
    };
    let name = label(data.get("name"), "name")?;
    let icons = map(data.get("icons"), "icons")?;
    if !icons.keys().all(|k| ICON_PACK_FIELDS.contains(&k.as_str())) {
        return fail("Unknown icon field");
    }
    let empty = Table::new();
    let images = map(icons.get("images"), "icon images")?;
    if images.is_empty() {
        return fail("An icon pack carries no icons");
    }
    let colors = match icons.get("colors") {
        None => &empty,
        raw => map(raw, "icon colors")?,
    };
    let checked = check_icons(images, colors, assets)?;
    if assets.keys().any(|path| !is_directory_entry(path) && path != "manifest.toml" && !checked.used.contains(path)) {
        return fail("Unexpected theme asset");
    }
    let icon_pack = IconPack { images: images.keys().cloned().collect(), colors: checked.colors, files: checked.files };
    Ok(Package { installation_id, id, name, schema_min, schema_max, themes: Vec::new(), icon_pack: Some(icon_pack) })
}

/// A package's icons, checked: the files by name inside `icons/`, their
/// colors, and the package paths they used.
struct CheckedIcons {
    files: IndexMap<String, Vec<u8>>,
    colors: IndexMap<String, ColorSpec>,
    used: HashSet<String>,
}

fn check_icons(images: &Table, colors: &Table, assets: &Assets) -> Result<CheckedIcons> {
    if images.len() > MAX_ICONS || !images.keys().all(|k| is_icon_key(k)) {
        return fail("Invalid icon keys");
    }
    let colors = icon_colors(colors, images)?;
    let mut files = IndexMap::new();
    let mut used = HashSet::new();
    for (key, value) in images {
        let path = icon_asset_path(key, value)?;
        let name = path["icons/".len()..].to_string();
        let bytes = if path.ends_with(".svg") {
            let bytes = asset_bytes(assets, &path, MAX_ICON_BYTES)?;
            svg::check(bytes)?;
            bytes
        } else {
            let bytes = image_asset(assets, &path, MAX_ICON_BYTES)?;
            if !image::is_png(bytes) {
                return fail("Icons must be PNG or SVG");
            }
            image::verify(bytes, 512, 512 * 512)?;
            bytes
        };
        files.insert(name, bytes.to_vec());
        used.insert(path);
    }
    Ok(CheckedIcons { files, colors, used })
}

/// Checks one theme — a package, or one variant drawn over its base — and
/// answers it with the package paths it used.
fn prepare(data: &Table, assets: &Assets) -> Result<(Theme, HashSet<String>)> {
    let (schema_min, _) = schema_range(data.get("schema"))?;
    match data.get("id") {
        Some(Value::String(id)) if is_id(id) => {}
        _ => return fail("Invalid theme id"),
    }
    label(data.get("name"), "name")?;
    let colors = map(data.get("colors"), "colors")?;
    let mode = integer(colors.get("mode"), 0, 2)? as u8;
    let modes = theme_modes(data.get("modes"))?;
    let seed = integer(colors.get("seed"), 0, 0xffff_ffff)? as u32;
    let Some(Value::Boolean(system_color)) = colors.get("systemColor") else {
        return fail("Invalid color mode");
    };
    let empty = Table::new();
    let palette = match colors.get("palette") {
        None => &empty,
        raw => map(raw, "palette")?,
    };
    if palette.keys().any(|k| k != "light" && k != "dark") {
        return fail("Invalid palette brightness");
    }
    let palette_light = palette_roles(palette.get("light"))?;
    let palette_dark = palette_roles(palette.get("dark"))?;
    let components = Components::parse(data.get("components"), data.get("layout"))?;
    let icons = map(data.get("icons"), "icons")?;
    if !icons.keys().all(|k| ICON_FIELDS.contains(&k.as_str())) {
        return fail("Unknown icon field");
    }
    let style = match icons.get("style") {
        Some(Value::String(s)) if s == "classic" || s == "mingcute" => s.clone(),
        _ => return fail("Invalid icon style"),
    };
    let images = match icons.get("images") {
        None => &empty,
        raw => map(raw, "icon images")?,
    };
    let checked_icons = check_icons(
        images,
        match icons.get("colors") {
            None => &empty,
            raw => map(raw, "icon colors")?,
        },
        assets,
    )?;
    let splash = splash(data.get("splash"))?;
    let background = map(data.get("background"), "background")?;
    if !background.keys().all(|k| BACKGROUND_FIELDS.contains(&k.as_str())) {
        return fail("Unknown background field");
    }
    let background_style = match background.get("type") {
        Some(Value::String(s)) if matches!(s.as_str(), "none" | "gradient" | "image") => s.clone(),
        _ => return fail("Invalid background type"),
    };
    let opacity = fraction(background.get("opacity"), MAX_BACKGROUND_OPACITY)?;
    let blur = fraction(background.get("blur"), MAX_BACKGROUND_BLUR)?;
    let tile = background_tile(background, &background_style)?;
    let shapes = map(data.get("shapes"), "shapes")?;
    let shapes = Shapes {
        card: fraction(shapes.get("card"), components::MAX_RADIUS)?,
        tile: fraction(shapes.get("tile"), components::MAX_RADIUS)?,
        button: fraction(shapes.get("button"), components::MAX_RADIUS)?,
    };

    let mut used = HashSet::new();
    let mut files = Files::default();
    if background_style == "image" {
        let path = match background.get("image") {
            Some(Value::String(p)) if BACKGROUND_IMAGES.contains(&p.as_str()) => p.clone(),
            _ => return fail("Invalid background path"),
        };
        let bytes = image_asset(assets, &path, MAX_BACKGROUND_BYTES)?;
        image::verify(bytes, 8192, 64 * 1024 * 1024)?;
        files.background = Some(bytes.to_vec());
        used.insert(path);
    } else if background.contains_key("image") {
        return fail("Unexpected background image");
    }
    let icon_files: Vec<String> = checked_icons.files.keys().cloned().collect();
    let icon_colors = checked_icons.colors;
    files.icons = checked_icons.files;
    used.extend(checked_icons.used);
    if let Some(Splash { logo: Some(logo), .. }) = &splash {
        let bytes = if logo.ends_with(".svg") {
            let bytes = asset_bytes(assets, logo, MAX_SPLASH_LOGO_BYTES)?;
            svg::check(bytes)?;
            bytes
        } else {
            let bytes = image_asset(assets, logo, MAX_SPLASH_LOGO_BYTES)?;
            image::verify(bytes, 2048, 2048 * 2048)?;
            bytes
        };
        files.splash_logo = Some((logo.clone(), bytes.to_vec()));
        used.insert(logo.clone());
    }
    require_feature_schema(schema_min, &icon_files, &icon_colors, splash.as_ref(), &components, tile)?;

    let (accent_tones, neutral_tones) = palette::tones(seed, &palette_light);
    let theme = Theme {
        variant: None,
        accent_tones,
        neutral_tones,
        scheme_light: palette::scheme(seed, false, &palette_light),
        scheme_dark: palette::scheme(seed, true, &palette_dark),
        modes,
        mode,
        seed,
        system_color: *system_color,
        palette_light,
        palette_dark,
        icons: Icons { style, images: images.keys().cloned().collect(), colors: icon_colors },
        background: Background { style: background_style, opacity, blur, tile },
        shapes,
        splash,
        components: components.tables,
        density: components.density,
        files,
    };
    Ok((theme, used))
}

/// The files one variant sees: the package's own, with any its directory
/// carries in their place, and where each replacement came from.
fn variant_assets(assets: &Assets, key: &str) -> (Assets, IndexMap<String, String>) {
    let prefix = format!("variants/{key}/");
    let mut view: Assets = assets
        .iter()
        .filter(|(path, _)| !path.starts_with("variants/"))
        .map(|(p, b)| (p.clone(), b.clone()))
        .collect();
    let mut origin = IndexMap::new();
    for (path, bytes) in assets {
        let Some(name) = path.strip_prefix(&prefix) else { continue };
        if name.is_empty() {
            continue;
        }
        view.insert(name.to_string(), bytes.clone());
        origin.insert(name.to_string(), path.clone());
    }
    (view, origin)
}

/// [base] with [overrides] over it: a table merges key by key, anything else
/// replaces.
fn merge(base: &Table, overrides: &Table) -> Table {
    let mut out = base.clone();
    for (key, value) in overrides {
        let merged = match (base.get(key), value) {
            (Some(Value::Table(a)), Value::Table(b)) => Value::Table(merge(a, b)),
            _ => value.clone(),
        };
        out.insert(key.clone(), merged);
    }
    out
}

/// What an omitted field is read as.
fn decode_manifest(source: &str) -> Result<Table> {
    let mut data: Table = source.parse().map_err(|_| ThemeError::new("Invalid TOML manifest"))?;
    data.entry("format").or_insert(Value::Integer(1));
    // An icon pack is not a theme, and is not read as one.
    if data.contains_key("kind") {
        return Ok(data);
    }
    let defaults: [(&str, Table); 4] = [
        (
            "colors",
            Table::from_iter([
                ("mode".into(), Value::Integer(0)),
                ("seed".into(), Value::Integer(0xFF88_0E4F)),
                ("systemColor".into(), Value::Boolean(false)),
            ]),
        ),
        (
            "icons",
            Table::from_iter([
                ("style".into(), Value::String("classic".into())),
                ("images".into(), Value::Table(Table::new())),
            ]),
        ),
        (
            "background",
            Table::from_iter([
                ("type".into(), Value::String("none".into())),
                ("opacity".into(), Value::Float(0.18)),
                ("blur".into(), Value::Integer(0)),
            ]),
        ),
        (
            "shapes",
            Table::from_iter([
                ("card".into(), Value::Integer(12)),
                ("tile".into(), Value::Integer(8)),
                ("button".into(), Value::Integer(10)),
            ]),
        ),
    ];
    for (key, mut values) in defaults {
        if let Some(given) = data.get(key) {
            for (k, v) in map(Some(given), key)? {
                values.insert(k.clone(), v.clone());
            }
        }
        data.insert(key.to_string(), Value::Table(values));
    }
    Ok(data)
}

fn map<'a>(value: Option<&'a Value>, field: &str) -> Result<&'a Table> {
    match value {
        Some(Value::Table(t)) => Ok(t),
        _ => fail(format!("Invalid {field}")),
    }
}

fn label(value: Option<&Value>, field: &str) -> Result<String> {
    match value {
        Some(Value::String(s))
            if !s.trim().is_empty()
                // UTF-16 code units, as the app counts a string's length.
                && s.encode_utf16().count() <= MAX_NAME_LENGTH
                && !s.chars().any(|c| (c as u32) < 0x20) =>
        {
            Ok(s.trim().to_string())
        }
        _ => fail(format!("Invalid {field}")),
    }
}

fn integer(value: Option<&Value>, min: i64, max: i64) -> Result<i64> {
    match value {
        Some(Value::Integer(i)) if (min..=max).contains(i) => Ok(*i),
        _ => fail("Invalid number"),
    }
}

fn fraction(value: Option<&Value>, max: f64) -> Result<f64> {
    match value.and_then(components::number) {
        Some(n) if (0.0..=max).contains(&n) => Ok(n),
        _ => fail("Invalid number"),
    }
}

fn theme_modes(raw: Option<&Value>) -> Result<Vec<String>> {
    const MESSAGE: &str = "Declare supported theme modes: light, dark";
    let Some(Value::Array(items)) = raw else { return fail(MESSAGE) };
    let unique: HashSet<String> = items.iter().map(|v| format!("{v:?}")).collect();
    if items.is_empty() || items.len() > 2 || unique.len() != items.len() {
        return fail(MESSAGE);
    }
    items
        .iter()
        .map(|v| match v {
            Value::String(s) if s == "light" || s == "dark" => Ok(s.clone()),
            _ => fail(MESSAGE),
        })
        .collect()
}

fn schema_range(raw: Option<&Value>) -> Result<(u32, u32)> {
    let schema = map(raw, "schema")?;
    if schema.len() != 2 || !schema.contains_key("min") || !schema.contains_key("max") {
        return fail("Invalid theme schema range");
    }
    let min = integer(schema.get("min"), 1, 0x7fff_ffff)? as u32;
    let max = integer(schema.get("max"), 1, 0x7fff_ffff)? as u32;
    if min > max || max < SUPPORTED_SCHEMA_MIN || min > SUPPORTED_SCHEMA_MAX {
        return fail("Unsupported theme schema range");
    }
    Ok((min, max))
}

fn background_tile(background: &Table, style: &str) -> Result<f64> {
    let Some(raw) = background.get("tile") else { return Ok(0.0) };
    if style != "image" {
        return fail("A background tile needs an image");
    }
    let tile = fraction(Some(raw), MAX_BACKGROUND_TILE)?;
    if tile < MIN_BACKGROUND_TILE {
        return fail("Invalid background tile");
    }
    Ok(tile)
}

fn palette_roles(raw: Option<&Value>) -> Result<IndexMap<String, u32>> {
    let Some(raw) = raw else { return Ok(IndexMap::new()) };
    let values = map(Some(raw), "palette")?;
    if !values.keys().all(|k| is_role(k)) {
        return fail("Invalid palette role");
    }
    values.iter().map(|(k, v)| Ok((k.clone(), integer(Some(v), 0, 0xffff_ffff)? as u32))).collect()
}

fn color_spec(value: &Value) -> Result<ColorSpec> {
    match value {
        Value::Integer(i) if (0..=0xffff_ffff).contains(i) => Ok(ColorSpec::Argb(*i as u32)),
        Value::String(s) if is_role(s) => Ok(ColorSpec::Role(s.clone())),
        _ => fail("Invalid color"),
    }
}

fn icon_colors(raw: &Table, images: &Table) -> Result<IndexMap<String, ColorSpec>> {
    raw.iter()
        .map(|(key, value)| {
            if !images.contains_key(key) {
                return fail("Icon color without an image");
            }
            Ok((key.clone(), color_spec(value)?))
        })
        .collect()
}

fn splash(raw: Option<&Value>) -> Result<Option<Splash>> {
    let Some(raw) = raw else { return Ok(None) };
    let table = map(Some(raw), "splash")?;
    if !table.keys().all(|k| SPLASH_FIELDS.contains(&k.as_str())) {
        return fail("Unknown splash field");
    }
    let logo = match table.get("logo") {
        None => None,
        Some(Value::String(l)) if SPLASH_LOGOS.contains(&l.as_str()) => Some(l.clone()),
        Some(_) => return fail("Invalid splash logo path"),
    };
    let duration = match table.get("duration") {
        None => SPLASH_DEFAULT_DURATION,
        raw => integer(raw, SPLASH_MIN_DURATION, SPLASH_MAX_DURATION)?,
    } as u32;
    let color = match table.get("color") {
        None => ColorSpec::Role("surface".into()),
        Some(v) => color_spec(v)?,
    };
    Ok(Some(Splash { color, duration, logo }))
}

/// Refuses a package that reaches for a newer schema's feature while saying
/// an older schema can read it: that build would install the bytes and drop
/// the feature without saying so.
fn require_feature_schema(
    min: u32,
    icon_files: &[String],
    icon_colors: &IndexMap<String, ColorSpec>,
    splash: Option<&Splash>,
    components: &Components,
    tile: f64,
) -> Result<()> {
    if min < ICON_SCHEMA && icon_files.len() > MAX_ICONS_BEFORE_ICON_SCHEMA {
        return fail(format!("This theme needs schema {ICON_SCHEMA}"));
    }
    if min < COMPONENT_SCHEMA && (components.needed_schema() >= COMPONENT_SCHEMA || tile > 0.0) {
        return fail(format!("This theme needs schema {COMPONENT_SCHEMA}"));
    }
    let uses = icon_files.iter().any(|n| n.ends_with(".svg")) || !icon_colors.is_empty() || splash.is_some();
    if uses && min < FEATURE_SCHEMA {
        return fail(format!("This theme needs schema {FEATURE_SCHEMA}"));
    }
    Ok(())
}

/// The only two names a package may give an icon, both derived from its key.
fn icon_asset_path(key: &str, value: &Value) -> Result<String> {
    let stem = key.replace('.', "_");
    match value {
        Value::String(v) if *v == format!("icons/{stem}.png") || *v == format!("icons/{stem}.svg") => Ok(v.clone()),
        _ => fail("Invalid icon path"),
    }
}

fn asset_bytes<'a>(assets: &'a Assets, path: &str, max: usize) -> Result<&'a [u8]> {
    match assets.get(path) {
        Some(b) if !b.is_empty() && b.len() <= max => Ok(b),
        _ => fail("Theme asset exceeds size limit"),
    }
}

fn image_asset<'a>(assets: &'a Assets, path: &str, max: usize) -> Result<&'a [u8]> {
    let bytes = asset_bytes(assets, path, max)?;
    if !(image::is_png(bytes) || image::is_jpeg(bytes)) {
        return fail("Use a PNG or JPEG image");
    }
    Ok(bytes)
}

// ---- uncompressed assets ---------------------------------------------------

/// Checks a theme given as its files (a development folder, or a theme the
/// app bundles), as fl_lib's `installAssets` does. Its installation id is a
/// digest of every path and its bytes, length-prefixed and in path order, so
/// the same files are the same installation however they were read.
pub fn install_files(assets: Assets) -> Result<Package> {
    let manifest = assets.get("manifest.toml");
    let total: usize = assets.values().map(Vec::len).sum();
    if manifest.is_none_or(|m| m.is_empty() || m.len() > MAX_MANIFEST_BYTES)
        || assets.len() > MAX_ASSETS
        || total > MAX_PACKAGE_BYTES
    {
        return fail("Invalid theme assets");
    }
    let mut paths: Vec<&String> = assets.keys().collect();
    paths.sort();
    let mut digest = Sha256::new();
    for path in paths {
        let content = &assets[path];
        digest.update((path.len() as u32).to_be_bytes());
        digest.update(path.as_bytes());
        digest.update((content.len() as u32).to_be_bytes());
        digest.update(content);
    }
    let installation_id = hex(&digest.finalize());
    install_assets(&assets, installation_id)
}

// ---- the installed layout --------------------------------------------------

/// Where a checked theme's background is written, whatever its format.
pub const INSTALLED_BACKGROUND: &str = "background.img";

impl Package {
    /// What installing this package writes, by path inside its installation
    /// directory: one normalized `manifest.toml` and the files it uses, or for
    /// a package with variants a manifest naming them and each variant as a
    /// complete theme under `variants/<key>/`. The normalized manifest is what
    /// `read_installed` reads back.
    pub fn layout(&self) -> Result<Vec<(String, Vec<u8>)>> {
        let mut out = Vec::new();
        if let Some(pack) = &self.icon_pack {
            self.write_icon_pack(pack, &mut out)?;
            return Ok(out);
        }
        match self.themes.as_slice() {
            [only] if only.variant.is_none() => self.write_theme(only, "", &mut out)?,
            themes => {
                let mut root = Table::new();
                root.insert("format".into(), Value::Integer(1));
                root.insert("schema".into(), self.schema());
                root.insert("id".into(), Value::String(self.id.clone()));
                root.insert("name".into(), Value::String(self.name.clone()));
                let mut list = Vec::new();
                for theme in themes {
                    let Some(v) = &theme.variant else { return fail("Invalid theme variants") };
                    let mut entry = Table::new();
                    entry.insert("key".into(), Value::String(v.key.clone()));
                    entry.insert("name".into(), Value::String(v.name.clone()));
                    list.push(Value::Table(entry));
                }
                root.insert("variants".into(), Value::Array(list));
                out.push(("manifest.toml".into(), manifest_bytes(&root)?));
                for theme in themes {
                    let key = &theme.variant.as_ref().map(|v| v.key.clone()).unwrap_or_default();
                    self.write_theme(theme, &format!("variants/{key}/"), &mut out)?;
                }
            }
        }
        Ok(out)
    }

    fn schema(&self) -> Value {
        Value::Table(Table::from_iter([
            ("min".into(), Value::Integer(self.schema_min.into())),
            ("max".into(), Value::Integer(self.schema_max.into())),
        ]))
    }

    fn write_icon_pack(&self, pack: &IconPack, out: &mut Vec<(String, Vec<u8>)>) -> Result<()> {
        let mut profile = Table::new();
        profile.insert("format".into(), Value::Integer(1));
        profile.insert("schema".into(), self.schema());
        profile.insert("id".into(), Value::String(self.id.clone()));
        profile.insert("name".into(), Value::String(self.name.clone()));
        profile.insert("kind".into(), Value::String("icons".into()));
        profile.insert("icons".into(), icons_value(&pack.images, &pack.colors, None));
        out.push(("manifest.toml".into(), manifest_bytes(&profile)?));
        for (name, bytes) in &pack.files {
            out.push((format!("icons/{name}"), bytes.clone()));
        }
        Ok(())
    }

    fn write_theme(&self, theme: &Theme, dir: &str, out: &mut Vec<(String, Vec<u8>)>) -> Result<()> {
        let mut profile = Table::new();
        profile.insert("format".into(), Value::Integer(1));
        profile.insert("schema".into(), self.schema());
        profile.insert("id".into(), Value::String(self.id.clone()));
        profile.insert("name".into(), Value::String(self.name.clone()));
        profile.insert("modes".into(), Value::Array(theme.modes.iter().cloned().map(Value::String).collect()));
        profile.insert("components".into(), components::json_to_toml(&serde_json::Value::Object(theme.components.clone()))?);
        if let Some(density) = &theme.density {
            profile.insert("layout".into(), Value::Table(Table::from_iter([("density".into(), Value::String(density.clone()))])));
        }
        let palette = |roles: &IndexMap<String, u32>| {
            Value::Table(roles.iter().map(|(k, v)| (k.clone(), Value::Integer((*v).into()))).collect())
        };
        profile.insert(
            "colors".into(),
            Value::Table(Table::from_iter([
                ("mode".into(), Value::Integer(theme.mode.into())),
                ("seed".into(), Value::Integer(theme.seed.into())),
                ("systemColor".into(), Value::Boolean(theme.system_color)),
                (
                    "palette".into(),
                    Value::Table(Table::from_iter([
                        ("light".into(), palette(&theme.palette_light)),
                        ("dark".into(), palette(&theme.palette_dark)),
                    ])),
                ),
            ])),
        );
        profile.insert("icons".into(), icons_value(&theme.icons.images, &theme.icons.colors, Some(&theme.icons.style)));
        let mut background = Table::new();
        background.insert("type".into(), Value::String(theme.background.style.clone()));
        background.insert("opacity".into(), Value::Float(theme.background.opacity));
        background.insert("blur".into(), Value::Float(theme.background.blur));
        if theme.background.tile > 0.0 {
            background.insert("tile".into(), Value::Float(theme.background.tile));
        }
        profile.insert("background".into(), Value::Table(background));
        profile.insert(
            "shapes".into(),
            Value::Table(Table::from_iter([
                ("card".into(), Value::Float(theme.shapes.card)),
                ("tile".into(), Value::Float(theme.shapes.tile)),
                ("button".into(), Value::Float(theme.shapes.button)),
            ])),
        );
        if let Some(splash) = &theme.splash {
            let mut table = Table::new();
            table.insert("color".into(), color_value(&splash.color));
            table.insert("duration".into(), Value::Integer(splash.duration.into()));
            if let Some(logo) = &splash.logo {
                table.insert("logo".into(), Value::String(logo.clone()));
            }
            profile.insert("splash".into(), Value::Table(table));
        }
        out.push((format!("{dir}manifest.toml"), manifest_bytes(&profile)?));
        if let Some(bytes) = &theme.files.background {
            out.push((format!("{dir}{INSTALLED_BACKGROUND}"), bytes.clone()));
        }
        for (name, bytes) in &theme.files.icons {
            out.push((format!("{dir}icons/{name}"), bytes.clone()));
        }
        if let Some((name, bytes)) = &theme.files.splash_logo {
            out.push((format!("{dir}{name}"), bytes.clone()));
        }
        Ok(())
    }
}

/// An installed `[icons]`: the keys carried, as a list, and their colors.
fn icons_value(images: &[String], colors: &IndexMap<String, ColorSpec>, style: Option<&str>) -> Value {
    let mut icons = Table::new();
    if let Some(style) = style {
        icons.insert("style".into(), Value::String(style.into()));
    }
    icons.insert("images".into(), Value::Array(images.iter().cloned().map(Value::String).collect()));
    if !colors.is_empty() {
        icons.insert("colors".into(), Value::Table(colors.iter().map(|(k, c)| (k.clone(), color_value(c))).collect()));
    }
    Value::Table(icons)
}

fn color_value(color: &ColorSpec) -> Value {
    match color {
        ColorSpec::Argb(v) => Value::Integer((*v).into()),
        ColorSpec::Role(r) => Value::String(r.clone()),
    }
}

fn manifest_bytes(table: &Table) -> Result<Vec<u8>> {
    let text = toml::to_string(table).map_err(|_| ThemeError::new("Invalid TOML manifest"))?;
    if text.len() > MAX_MANIFEST_BYTES {
        return fail("Normalized manifest exceeds size limit");
    }
    Ok(text.into_bytes())
}

// ---- reading an installation back -----------------------------------------

/// One installed theme as its normalized manifest describes it, for the app
/// to draw. Icons are named by key; which file each is (`.svg` or `.png`) is
/// the directory's to say, so the caller hands it in.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Installed {
    pub id: String,
    pub name: String,
    pub schema_min: u32,
    pub schema_max: u32,
    pub modes: Vec<String>,
    pub mode: u8,
    pub seed: u32,
    pub system_color: bool,
    pub palette_light: IndexMap<String, u32>,
    pub palette_dark: IndexMap<String, u32>,
    pub components: Map<String, serde_json::Value>,
    pub density: Option<String>,
    /// The schema its components and layout need (`Components::needed_schema`).
    pub components_schema: u32,
    pub icon_style: String,
    /// Key to file name inside `icons/`.
    pub icon_files: IndexMap<String, String>,
    pub icon_colors: IndexMap<String, ColorSpec>,
    pub background: Background,
    pub shapes: Shapes,
    pub splash: Option<Splash>,
}

/// The variants an installation's top manifest names, or None when it is a
/// theme of its own (`layout`).
pub fn installed_variants(manifest: &str) -> Result<Option<Vec<Variant>>> {
    let data = decode_manifest(manifest)?;
    let Some(raw) = data.get("variants") else { return Ok(None) };
    let Value::Array(list) = raw else { return fail("Invalid theme variants") };
    let variants: Vec<Variant> = list
        .iter()
        .filter_map(|raw| match raw {
            Value::Table(t) => match (t.get("key"), t.get("name")) {
                (Some(Value::String(key)), Some(Value::String(name))) if is_variant_key(key) => {
                    Some(Variant { key: key.clone(), name: name.clone() })
                }
                _ => None,
            },
            _ => None,
        })
        .collect();
    // Each key is a directory of its own, as `layout` writes them.
    let keys: HashSet<&str> = variants.iter().map(|v| v.key.as_str()).collect();
    if variants.is_empty() || variants.len() != list.len() || variants.len() > MAX_VARIANTS || keys.len() != variants.len() {
        return fail("Invalid theme variants");
    }
    Ok(Some(variants))
}

/// Reads one installed theme's normalized manifest; [icon_files] is what its
/// `icons/` directory holds, by file name. Each key the manifest names is the
/// `.svg` or else the `.png` named after it.
pub fn read_installed(manifest: &str, icon_files: &[String]) -> Result<Installed> {
    let data = decode_manifest(manifest)?;
    if !matches!(data.get("format"), Some(Value::Integer(1))) {
        return fail("Unsupported theme package");
    }
    let (schema_min, schema_max) = schema_range(data.get("schema"))?;
    let id = match data.get("id") {
        Some(Value::String(id)) if is_id(id) => id.clone(),
        _ => return fail("Invalid theme id"),
    };
    let colors = map(data.get("colors"), "colors")?;
    let empty = Table::new();
    let palette = match colors.get("palette") {
        None => &empty,
        raw => map(raw, "palette")?,
    };
    let components = Components::parse(data.get("components"), data.get("layout"))?;
    let icons = map(data.get("icons"), "icons")?;
    let background = map(data.get("background"), "background")?;
    let shapes = map(data.get("shapes"), "shapes")?;
    let (files, icon_colors) = installed_icons(icons, icon_files)?;
    let icon_style = match icons.get("style") {
        Some(Value::String(s)) if s == "classic" || s == "mingcute" => s.clone(),
        _ => return fail("Invalid icon style"),
    };
    let background_style = match background.get("type") {
        Some(Value::String(s)) if matches!(s.as_str(), "none" | "gradient" | "image") => s.clone(),
        _ => return fail("Invalid background type"),
    };
    let tile = background_tile(background, &background_style)?;
    let splash = splash(data.get("splash"))?;
    let names: Vec<String> = files.values().cloned().collect();
    require_feature_schema(schema_min, &names, &icon_colors, splash.as_ref(), &components, tile)?;
    let Some(Value::Boolean(system_color)) = colors.get("systemColor") else {
        return fail("Invalid color mode");
    };
    Ok(Installed {
        id,
        name: label(data.get("name"), "name")?,
        schema_min,
        schema_max,
        modes: theme_modes(data.get("modes"))?,
        mode: integer(colors.get("mode"), 0, 2)? as u8,
        seed: integer(colors.get("seed"), 0, 0xffff_ffff)? as u32,
        system_color: *system_color,
        palette_light: palette_roles(palette.get("light"))?,
        palette_dark: palette_roles(palette.get("dark"))?,
        components_schema: components.needed_schema(),
        components: components.tables,
        density: components.density,
        icon_style,
        icon_files: files,
        icon_colors,
        background: Background {
            style: background_style,
            opacity: fraction(background.get("opacity"), MAX_BACKGROUND_OPACITY)?,
            blur: fraction(background.get("blur"), MAX_BACKGROUND_BLUR)?,
            tile,
        },
        shapes: Shapes {
            card: fraction(shapes.get("card"), components::MAX_RADIUS)?,
            tile: fraction(shapes.get("tile"), components::MAX_RADIUS)?,
            button: fraction(shapes.get("button"), components::MAX_RADIUS)?,
        },
        splash,
    })
}

/// An installation's `[icons]` read back: key to file name inside `icons/`
/// (the `.svg`, else the `.png`, among [icon_files]), and their colors.
fn installed_icons(icons: &Table, icon_files: &[String]) -> Result<(IndexMap<String, String>, IndexMap<String, ColorSpec>)> {
    let carried: Vec<String> = match icons.get("images") {
        Some(Value::Array(keys)) => keys
            .iter()
            .map(|k| match k {
                Value::String(k) if is_icon_key(k) => Ok(k.clone()),
                _ => fail("Invalid icon keys"),
            })
            .collect::<Result<_>>()?,
        _ => return fail("Invalid icon keys"),
    };
    // A key is one file: the installer writes each once.
    if carried.iter().collect::<HashSet<_>>().len() != carried.len() {
        return fail("Invalid icon keys");
    }
    let mut files = IndexMap::new();
    for key in &carried {
        let stem = key.replace('.', "_");
        let found = [format!("{stem}.svg"), format!("{stem}.png")].into_iter().find(|n| icon_files.contains(n));
        match found {
            Some(name) => {
                files.insert(key.clone(), name);
            }
            None => return fail("Invalid icon path"),
        }
    }
    let carried_table: Table = carried.iter().map(|k| (k.clone(), Value::Boolean(true))).collect();
    let empty = Table::new();
    let colors = icon_colors(
        match icons.get("colors") {
            None => &empty,
            raw => map(raw, "icon colors")?,
        },
        &carried_table,
    )?;
    Ok((files, colors))
}

/// One installed icon pack as its normalized manifest describes it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledIconPack {
    pub id: String,
    pub name: String,
    pub schema_min: u32,
    pub schema_max: u32,
    /// Key to file name inside `icons/`.
    pub icon_files: IndexMap<String, String>,
    pub icon_colors: IndexMap<String, ColorSpec>,
}

/// Reads one installed icon pack's normalized manifest; [icon_files] is what
/// its `icons/` directory holds, by file name.
pub fn read_installed_icon_pack(manifest: &str, icon_files: &[String]) -> Result<InstalledIconPack> {
    let data = decode_manifest(manifest)?;
    if !matches!(data.get("format"), Some(Value::Integer(1))) || !is_icon_pack(&data)? {
        return fail("Unsupported theme package");
    }
    if !data.keys().all(|k| ICON_PACK_SECTIONS.contains(&k.as_str())) {
        return fail("Unknown icon pack section");
    }
    let icons = map(data.get("icons"), "icons")?;
    if !icons.keys().all(|k| ICON_PACK_FIELDS.contains(&k.as_str())) {
        return fail("Unknown icon field");
    }
    let (schema_min, schema_max) = schema_range(data.get("schema"))?;
    // Held to what installing it was, as a theme's read-back is.
    if schema_min < ICON_SCHEMA {
        return fail(format!("An icon pack needs schema {ICON_SCHEMA}"));
    }
    let id = match data.get("id") {
        Some(Value::String(id)) if is_id(id) => id.clone(),
        _ => return fail("Invalid theme id"),
    };
    let (icon_files, icon_colors) = installed_icons(icons, icon_files)?;
    if icon_files.is_empty() {
        return fail("An icon pack carries no icons");
    }
    if icon_files.len() > MAX_ICONS {
        return fail("Invalid icon keys");
    }
    Ok(InstalledIconPack { id, name: label(data.get("name"), "name")?, schema_min, schema_max, icon_files, icon_colors })
}

// ---- the format, for others to be held to ----------------------------------

/// What a package may say and how much it may carry, for a test to hold
/// another reader of the format (fl_lib's constants, the JSON schema) to.
pub fn format() -> serde_json::Value {
    serde_json::json!({
        "supportedSchemaMin": SUPPORTED_SCHEMA_MIN,
        "supportedSchemaMax": SUPPORTED_SCHEMA_MAX,
        "featureSchema": FEATURE_SCHEMA,
        "componentSchema": COMPONENT_SCHEMA,
        "iconSchema": ICON_SCHEMA,
        "maxPackageBytes": MAX_PACKAGE_BYTES,
        "maxBackgroundBytes": MAX_BACKGROUND_BYTES,
        "maxSplashLogoBytes": MAX_SPLASH_LOGO_BYTES,
        "maxIconBytes": MAX_ICON_BYTES,
        "maxManifestBytes": MAX_MANIFEST_BYTES,
        "maxIcons": MAX_ICONS,
        "maxAssets": MAX_ASSETS,
        "maxVariants": MAX_VARIANTS,
        "maxNameLength": MAX_NAME_LENGTH,
        "maxBackgroundOpacity": MAX_BACKGROUND_OPACITY,
        "maxBackgroundBlur": MAX_BACKGROUND_BLUR,
        "minBackgroundTile": MIN_BACKGROUND_TILE,
        "maxBackgroundTile": MAX_BACKGROUND_TILE,
        "splashMinDuration": SPLASH_MIN_DURATION,
        "splashMaxDuration": SPLASH_MAX_DURATION,
        "splashDefaultDuration": SPLASH_DEFAULT_DURATION,
        "sections": SECTIONS,
        "iconPackSections": ICON_PACK_SECTIONS,
        "iconPackFields": ICON_PACK_FIELDS,
        "variantFields": VARIANT_FIELDS,
        "iconFields": ICON_FIELDS,
        "backgroundFields": BACKGROUND_FIELDS,
        "splashFields": SPLASH_FIELDS,
        "backgroundImages": BACKGROUND_IMAGES,
        "splashLogos": SPLASH_LOGOS,
        "modes": ["light", "dark"],
        "iconStyles": ["classic", "mingcute"],
        "backgroundStyles": ["none", "gradient", "image"],
        "components": components::format(),
        "repo": crate::repo::format(),
    })
}
