//! What an installation writes: the files and its normalized manifest.

use super::*;

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

    pub(super) fn schema(&self) -> Value {
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

