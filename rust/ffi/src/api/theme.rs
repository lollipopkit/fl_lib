//! Theme packages and the theme store for Dart (`fl_theme`): everything that
//! reads or checks what a package or a repository says. Dart keeps the IO
//! (downloading, writing an installation, reading assets) and the drawing.
//!
//! Refusals carry the installer's own words (`ThemeFailure.message`), the ones
//! Dart showed before this moved here. Structured answers Dart has its own
//! model for (a listing, an installed theme) come back as JSON in that
//! model's shape (`fromJson`).

use flutter_rust_bridge::frb;
use indexmap::IndexMap;

/// A file by its path: inside a package, an installation or a repository.
pub struct ThemeFile {
    pub path: String,
    pub bytes: Vec<u8>,
}

/// A theme or a repository refused, and why.
#[derive(Debug)]
pub struct ThemeFailure {
    pub message: String,
}

impl From<fl_theme::ThemeError> for ThemeFailure {
    fn from(e: fl_theme::ThemeError) -> Self {
        Self { message: e.0 }
    }
}

/// A checked package: what to call the installation, and what installing it
/// writes inside that directory (`Package::layout`).
pub struct PreparedTheme {
    /// SHA-256, lowercase hex: of the `.fsbt`, or of the files given.
    pub installation_id: String,
    pub id: String,
    pub name: String,
    /// An icon pack rather than a theme: installed and chosen apart.
    pub icon_pack: bool,
    pub files: Vec<ThemeFile>,
}

pub struct ThemeVariantInfo {
    pub key: String,
    pub name: String,
}

pub struct ThemeCatalogInfo {
    pub name: Option<String>,
    /// Each repository's address, resolved, deduplicated, in order.
    pub repos: Vec<String>,
}

/// One repository's tree, read.
pub struct ThemeRepoTree {
    pub name: Option<String>,
    /// The listings, a JSON array in `ThemeListing.toJson`'s shape.
    pub listings: String,
    /// The `.fsbt` files the tree carries, by repository path.
    pub packages: Vec<ThemeFile>,
}

fn prepared(package: fl_theme::Package) -> Result<PreparedTheme, ThemeFailure> {
    let files = package.layout()?.into_iter().map(|(path, bytes)| ThemeFile { path, bytes }).collect();
    Ok(PreparedTheme {
        icon_pack: package.icon_pack.is_some(),
        installation_id: package.installation_id,
        id: package.id,
        name: package.name,
        files,
    })
}

fn files_map(files: Vec<ThemeFile>) -> IndexMap<String, Vec<u8>> {
    files.into_iter().map(|f| (f.path, f.bytes)).collect()
}

fn json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("theme models serialize")
}

/// Checks a `.fsbt`.
pub fn prepare_theme_package(bytes: Vec<u8>) -> Result<PreparedTheme, ThemeFailure> {
    prepared(fl_theme::install(&bytes)?)
}

/// Checks a theme given as its files (a development folder, a bundled theme).
pub fn prepare_theme_files(files: Vec<ThemeFile>) -> Result<PreparedTheme, ThemeFailure> {
    prepared(fl_theme::install_files(files_map(files))?)
}

/// The variants an installation's top manifest names, or none for a theme of
/// its own.
#[frb(sync)]
pub fn installed_theme_variants(manifest: String) -> Result<Option<Vec<ThemeVariantInfo>>, ThemeFailure> {
    Ok(fl_theme::installed_variants(&manifest)?
        .map(|list| list.into_iter().map(|v| ThemeVariantInfo { key: v.key, name: v.name }).collect()))
}

/// Reads one installed theme's normalized manifest, as JSON
/// (`fl_theme::Installed`). [icon_files] is what its `icons/` holds, by name.
#[frb(sync)]
pub fn read_installed_theme(manifest: String, icon_files: Vec<String>) -> Result<String, ThemeFailure> {
    Ok(json(&fl_theme::read_installed(&manifest, &icon_files)?))
}

/// Reads one installed icon pack's normalized manifest, as JSON
/// (`fl_theme::InstalledIconPack`). [icon_files] is what its `icons/` holds.
#[frb(sync)]
pub fn read_installed_icon_pack(manifest: String, icon_files: Vec<String>) -> Result<String, ThemeFailure> {
    Ok(json(&fl_theme::read_installed_icon_pack(&manifest, &icon_files)?))
}

/// Checks `[components]` and `[layout]` given as JSON (null for absent), and
/// answers them checked as JSON: `{ components, density, neededSchema }`.
#[frb(sync)]
pub fn check_theme_components(components: Option<String>, layout: Option<String>) -> Result<String, ThemeFailure> {
    let parse = |raw: Option<String>| -> Result<Option<serde_json::Value>, ThemeFailure> {
        raw.map(|r| serde_json::from_str(&r).map_err(|_| ThemeFailure { message: "Invalid component table".into() }))
            .transpose()
    };
    let (raw, layout) = (parse(components)?, parse(layout)?);
    let checked = fl_theme::components::Components::parse_json(raw.as_ref(), layout.as_ref())?;
    Ok(json(&serde_json::json!({
        "components": checked.tables,
        "density": checked.density,
        "neededSchema": checked.needed_schema(),
    })))
}

/// Reads the store's catalog; [base] resolves a relative repository address.
#[frb(sync)]
pub fn parse_theme_catalog(bytes: Vec<u8>, base: Option<String>) -> Result<ThemeCatalogInfo, ThemeFailure> {
    let base = match base {
        Some(b) => Some(url::Url::parse(&b).map_err(|_| ThemeFailure { message: format!("Invalid catalog address: {b}") })?),
        None => None,
    };
    let catalog = fl_theme::repo::Catalog::parse(&bytes, base.as_ref())?;
    Ok(ThemeCatalogInfo { name: catalog.name, repos: catalog.repos })
}

/// Reads one theme's file in a repository; [path] is where it was found.
#[frb(sync)]
pub fn parse_theme_listing(text: String, path: String) -> Result<String, ThemeFailure> {
    Ok(json(&fl_theme::repo::Listing::parse(&text, &path)?))
}

/// Reads a repository's files.
#[frb(sync)]
pub fn read_theme_repo(files: Vec<ThemeFile>) -> Result<ThemeRepoTree, ThemeFailure> {
    let index = fl_theme::repo::Index::from_files(&files_map(files))?;
    Ok(ThemeRepoTree {
        name: index.name,
        listings: json(&index.listings),
        packages: index.packages.into_iter().map(|(path, bytes)| ThemeFile { path, bytes }).collect(),
    })
}

/// A repository's tarball unpacked, bounded, its top directory stripped.
#[frb(sync)]
pub fn read_theme_repo_archive(bytes: Vec<u8>) -> Result<Vec<ThemeFile>, ThemeFailure> {
    Ok(fl_theme::repo::read_archive(&bytes)?.into_iter().map(|(path, bytes)| ThemeFile { path, bytes }).collect())
}

/// Where a repository's tree is fetched from.
#[frb(sync)]
pub fn theme_repo_archive_url(address: String) -> String {
    fl_theme::repo::archive_url_of(&address)
}

/// `a` against `b` as theme versions: negative, zero or positive.
#[frb(sync)]
pub fn compare_theme_versions(a: String, b: String) -> i32 {
    fl_theme::repo::compare_versions(&a, &b) as i32
}

/// What the format allows, as JSON (`fl_theme::package::format`): for a test
/// holding this side's constants and drawing tables to the reader's.
#[frb(sync)]
pub fn theme_format() -> String {
    fl_theme::package::format().to_string()
}
