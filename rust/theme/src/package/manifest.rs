//! Reading `manifest.toml`: its sections, fields and assets.

use super::*;

/// What an omitted field is read as.
pub(super) fn decode_manifest(source: &str) -> Result<Table> {
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

pub(super) fn map<'a>(value: Option<&'a Value>, field: &str) -> Result<&'a Table> {
    match value {
        Some(Value::Table(t)) => Ok(t),
        _ => fail(format!("Invalid {field}")),
    }
}

pub(super) fn label(value: Option<&Value>, field: &str) -> Result<String> {
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

pub(super) fn integer(value: Option<&Value>, min: i64, max: i64) -> Result<i64> {
    match value {
        Some(Value::Integer(i)) if (min..=max).contains(i) => Ok(*i),
        _ => fail("Invalid number"),
    }
}

pub(super) fn fraction(value: Option<&Value>, max: f64) -> Result<f64> {
    match value.and_then(components::number) {
        Some(n) if (0.0..=max).contains(&n) => Ok(n),
        _ => fail("Invalid number"),
    }
}

pub(super) fn theme_modes(raw: Option<&Value>) -> Result<Vec<String>> {
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

pub(super) fn schema_range(raw: Option<&Value>) -> Result<(u32, u32)> {
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

pub(super) fn background_tile(background: &Table, style: &str) -> Result<f64> {
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

pub(super) fn palette_roles(raw: Option<&Value>) -> Result<IndexMap<String, u32>> {
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

pub(super) fn icon_colors(raw: &Table, images: &Table) -> Result<IndexMap<String, ColorSpec>> {
    raw.iter()
        .map(|(key, value)| {
            if !images.contains_key(key) {
                return fail("Icon color without an image");
            }
            Ok((key.clone(), color_spec(value)?))
        })
        .collect()
}

pub(super) fn splash(raw: Option<&Value>) -> Result<Option<Splash>> {
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
pub(super) fn require_feature_schema(
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
pub(super) fn icon_asset_path(key: &str, value: &Value) -> Result<String> {
    let stem = key.replace('.', "_");
    match value {
        Value::String(v) if *v == format!("icons/{stem}.png") || *v == format!("icons/{stem}.svg") => Ok(v.clone()),
        _ => fail("Invalid icon path"),
    }
}

pub(super) fn asset_bytes<'a>(assets: &'a Assets, path: &str, max: usize) -> Result<&'a [u8]> {
    match assets.get(path) {
        Some(b) if !b.is_empty() && b.len() <= max => Ok(b),
        _ => fail("Theme asset exceeds size limit"),
    }
}

pub(super) fn image_asset<'a>(assets: &'a Assets, path: &str, max: usize) -> Result<&'a [u8]> {
    let bytes = asset_bytes(assets, path, max)?;
    if !(image::is_png(bytes) || image::is_jpeg(bytes)) {
        return fail("Use a PNG or JPEG image");
    }
    Ok(bytes)
}

