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

mod install;
mod installed;
mod layout;
mod manifest;
pub use install::install;
use install::*;
pub use installed::{Installed, InstalledIconPack, installed_variants, read_installed, read_installed_icon_pack};
pub use layout::{INSTALLED_BACKGROUND, install_files};
use manifest::*;

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
