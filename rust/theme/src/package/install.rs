//! Installing a `.fsbt`: checked, its assets prepared.

use super::*;

/// Reads and checks a `.fsbt`.
pub fn install(bytes: &[u8]) -> Result<Package> {
    if bytes.is_empty() || bytes.len() > MAX_PACKAGE_BYTES {
        return fail("Invalid theme package size");
    }
    let assets = archive::read(bytes)?;
    let installation_id = hex(&Sha256::digest(bytes));
    install_assets(&assets, installation_id)
}

pub(super) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(super) fn install_assets(assets: &Assets, installation_id: String) -> Result<Package> {
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
    pub(super) files: IndexMap<String, Vec<u8>>,
    pub(super) colors: IndexMap<String, ColorSpec>,
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
