//! Reading an installation back.

use super::*;

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
