//! Theme token DSL: a flat token table that derives `settings.toast` plus
//! `--mdn-*` CSS variables. User files under `styles/themes/<id>.json`
//! override the embedded builtin of the same id. Decoding is lenient by
//! design: unknown tokens are ignored, numbers clamp, invalid values fall
//! back to the builtin default and surface as diagnostics.

use crate::model::{ApiError, Result, Settings};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// Card fill: "auto" (follow light/dark surface), one hex, or a light/dark pair.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum Fill {
    Flat(String),
    Split { light: String, dark: String },
}

fn hex_color(value: &str, alpha: bool) -> bool {
    let digits: &[usize] = if alpha { &[6, 8] } else { &[6] };
    value.starts_with('#')
        && digits.contains(&(value.len() - 1))
        && value[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    pub accent: String,
    pub card_fill: Fill,
    pub text_fill: String,
    pub card_radius: u32,
    pub title_size: u32,
    pub title_weight: u32,
    pub body_size: u32,
    pub line_height: f64,
    pub body_lines: u32,
    pub padding: u32,
    pub gap: u32,
    pub border_style: String,
    pub border_width: u32,
    pub border_color: String,
    pub level_accent: bool,
    pub shadow: bool,
    pub header: String,
    pub header_label: String,
    pub header_separator: bool,
    pub show_icon: bool,
    pub show_time: bool,
    pub show_level: bool,
    pub text_align: String,
    pub show_body: bool,
    pub show_progress: bool,
    pub show_tags: bool,
    pub show_history: bool,
    pub actions_layout: String,
    pub level_success: String,
    pub level_warning: String,
    pub level_error: String,
    pub bezel_fill: String,
    pub bezel_icon_size: u32,
    pub pill_fill: String,
    pub pill_height: u32,
    pub panel_fill: String,
    pub panel_max_height: u32,
}

impl Default for Tokens {
    /// Today's literal appearance — the migration baseline. The default theme
    /// derives back to these values pixel-for-pixel.
    fn default() -> Self {
        Self {
            accent: "#7c6cf0".into(),
            card_fill: Fill::Flat("auto".into()),
            text_fill: "auto".into(),
            card_radius: 16,
            title_size: 15,
            title_weight: 600,
            body_size: 14,
            line_height: 1.6,
            body_lines: 5,
            padding: 16,
            gap: 8,
            border_style: "solid".into(),
            border_width: 1,
            border_color: "auto".into(),
            level_accent: true,
            shadow: false,
            header: "full".into(),
            header_label: String::new(),
            header_separator: false,
            show_icon: true,
            show_time: false,
            show_level: true,
            text_align: "left".into(),
            show_body: true,
            show_progress: true,
            show_tags: false,
            show_history: true,
            actions_layout: "inline".into(),
            level_success: "#49a88b".into(),
            level_warning: "#c89743".into(),
            level_error: "#df6e7b".into(),
            bezel_fill: "#000000c4".into(),
            bezel_icon_size: 48,
            pill_fill: "#000000d9".into(),
            pill_height: 32,
            panel_fill: "#000000e6".into(),
            panel_max_height: 420,
        }
    }
}

/// Embedded style pack shipped with the app; same-name user files override.
const EMBEDDED: [(&str, &str, &str); 4] = [
    ("default", "默认", r##"{"name":"默认"}"##),
    (
        "midnight",
        "午夜",
        r##"{"name":"午夜","accent":"#8f7ff5","cardFill":"#17171f","textFill":"#ececf4","cardRadius":18,"borderColor":"#2f2f3a","shadow":true,"pillFill":"#0b0b10e6","panelFill":"#101018f2","bezelFill":"#0b0b10e0"}"##,
    ),
    (
        "minimal",
        "极简",
        r##"{"name":"极简","header":"hidden","borderStyle":"none","padding":12,"cardRadius":12,"showLevel":false,"levelAccent":false}"##,
    ),
    (
        "glass",
        "玻璃",
        r##"{"name":"玻璃","cardFill":"#20202acc","textFill":"#f4f4f8","borderColor":"#ffffff30","cardRadius":20,"shadow":true,"pillFill":"#101014b8","panelFill":"#16161ecc"}"##,
    ),
];

const NUMBER_TOKENS: [&str; 12] = [
    "cardRadius",
    "titleSize",
    "titleWeight",
    "bodySize",
    "bodyLines",
    "padding",
    "gap",
    "borderWidth",
    "lineHeight",
    "bezelIconSize",
    "pillHeight",
    "panelMaxHeight",
];

fn coerce_number(value: &Value, min: f64, max: f64, int: bool) -> Option<Value> {
    let n = value.as_f64()?;
    if !n.is_finite() {
        return None;
    }
    let clamped = n.clamp(min, max);
    Some(if int {
        json!(clamped.round() as i64)
    } else {
        json!(clamped)
    })
}

fn coerce_enum(value: &Value, set: &[&str]) -> Option<Value> {
    value.as_str().filter(|s| set.contains(s)).map(|s| json!(s))
}

/// Per-token coercion: value → canonical form, or None when it must fall back.
/// Names outside the table are unknown tokens and also yield None.
fn coerce(name: &str, value: &Value) -> Option<Value> {
    let auto_or_hex = |v: &Value, allow_auto: bool| match v.as_str() {
        Some(s) if allow_auto && s == "auto" => Some(json!("auto")),
        Some(s) if hex_color(s, true) => Some(json!(s)),
        _ => None,
    };
    match name {
        "accent" | "levelSuccess" | "levelWarning" | "levelError" => auto_or_hex(value, false),
        "textFill" | "borderColor" => auto_or_hex(value, true),
        "cardFill" => match value {
            Value::String(s) if s == "auto" || hex_color(s, true) => Some(json!(s)),
            Value::Object(o) => match (o.get("light"), o.get("dark")) {
                (Some(light), Some(dark))
                    if hex_color(light.as_str()?, true) && hex_color(dark.as_str()?, true) =>
                {
                    Some(json!({"light": light, "dark": dark}))
                }
                _ => None,
            },
            _ => None,
        },
        "bezelFill" | "pillFill" | "panelFill" => value
            .as_str()
            .filter(|s| hex_color(s, true))
            .map(|s| json!(s)),
        "headerLabel" => value
            .as_str()
            .filter(|s| s.chars().count() <= 80)
            .map(|s| json!(s)),
        "header" => coerce_enum(value, &["full", "compact", "hidden"]),
        "textAlign" => coerce_enum(value, &["left", "center"]),
        "actionsLayout" => coerce_enum(value, &["inline", "stacked"]),
        "borderStyle" => coerce_enum(value, &["none", "solid", "dashed"]),
        "titleWeight" => coerce_number(value, 400.0, 700.0, true)
            .filter(|v| [400, 500, 600, 700].contains(&v.as_i64().unwrap_or(0))),
        "cardRadius" => coerce_number(value, 0.0, 32.0, true),
        "titleSize" => coerce_number(value, 12.0, 28.0, true),
        "bodySize" => coerce_number(value, 12.0, 20.0, true),
        "bodyLines" => coerce_number(value, 1.0, 12.0, true),
        "padding" => coerce_number(value, 8.0, 32.0, true),
        "gap" => coerce_number(value, 0.0, 24.0, true),
        "borderWidth" => coerce_number(value, 0.0, 4.0, true),
        "lineHeight" => coerce_number(value, 1.2, 2.0, false),
        "bezelIconSize" => coerce_number(value, 24.0, 96.0, true),
        "pillHeight" => coerce_number(value, 24.0, 48.0, true),
        "panelMaxHeight" => coerce_number(value, 240.0, 640.0, true),
        "levelAccent" | "shadow" | "headerSeparator" | "showIcon" | "showTime" | "showLevel"
        | "showBody" | "showProgress" | "showTags" | "showHistory" => {
            value.as_bool().map(|b| json!(b))
        }
        _ => None,
    }
}

/// Lenient merge: coerce known tokens over the defaults, drop the rest.
fn complete(partial: Value, origin: &str) -> (Tokens, Vec<String>) {
    let mut diagnostics = vec![];
    let mut merged = serde_json::to_value(Tokens::default()).unwrap_or_else(|_| json!({}));
    if let Some(map) = partial.as_object() {
        for (key, value) in map {
            if key == "name" {
                continue;
            }
            // Explicit null means "not set" (e.g. an Option token) — not an error.
            if value.is_null() {
                continue;
            }
            match coerce(key, value) {
                Some(coerced) => {
                    if coerced != *value && NUMBER_TOKENS.contains(&key.as_str()) {
                        diagnostics.push(format!("{origin}: token {key} clamped into range"));
                    }
                    merged[key] = coerced;
                }
                None => diagnostics.push(format!(
                    "{origin}: token {key} ignored (unknown name or invalid value)"
                )),
            }
        }
    }
    match serde_json::from_value(merged) {
        Ok(tokens) => (tokens, diagnostics),
        Err(_) => (
            Tokens::default(),
            vec![format!("{origin}: fell back to default tokens")],
        ),
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Theme {
    pub id: String,
    pub name: String,
    #[serde(flatten)]
    pub tokens: Tokens,
    /// "builtin" or "user" — which copy answered the load.
    pub source: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<String>,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

fn builtin_fallback() -> (&'static str, &'static str, &'static str) {
    ("default", "默认", r##"{"name":"默认"}"##)
}

impl Theme {
    fn builtin(id: &str) -> Self {
        let (_, name, body) = EMBEDDED
            .iter()
            .find(|(builtin, _, _)| *builtin == id)
            .copied()
            .unwrap_or_else(builtin_fallback);
        let (tokens, diagnostics) = complete(
            serde_json::from_str(body).unwrap_or_else(|_| json!({})),
            "builtin",
        );
        Self {
            id: id.into(),
            name: name.to_string(),
            tokens,
            source: "builtin".into(),
            diagnostics,
        }
    }

    /// Resolve a theme: a user file wins over the builtin of the same id; a
    /// bad user file falls back to the builtin instead of failing the load.
    pub fn load(dir: Option<&Path>, id: &str) -> Self {
        let id = if valid_id(id) { id } else { "default" };
        let builtin = Self::builtin(id);
        let Some(dir) = dir else { return builtin };
        let path = dir.join("themes").join(format!("{id}.json"));
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return builtin;
        };
        if raw.len() > 64 * 1024 {
            let mut theme = builtin;
            theme.diagnostics.push(format!(
                "themes/{id}.json exceeds 64KB; using the builtin theme"
            ));
            return theme;
        }
        match serde_json::from_str::<Value>(&raw) {
            Ok(partial) if partial.is_object() => {
                let name = partial["name"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.chars().count() <= 40)
                    .unwrap_or(&builtin.name)
                    .to_string();
                let (tokens, diagnostics) = complete(partial, &format!("themes/{id}.json"));
                Self {
                    id: id.into(),
                    name,
                    tokens,
                    source: "user".into(),
                    diagnostics,
                }
            }
            _ => {
                let mut theme = builtin;
                theme.diagnostics.push(format!(
                    "themes/{id}.json is not a JSON object; using the builtin theme"
                ));
                theme
            }
        }
    }

    /// All selectable themes: builtins plus user files in styles/themes/.
    pub fn list(dir: Option<&Path>) -> Vec<Value> {
        let mut items: Vec<Value> = EMBEDDED
            .iter()
            .map(|(id, name, _)| json!({"id": id, "name": name, "source": "builtin"}))
            .collect();
        if let Some(dir) = dir {
            if let Ok(entries) = dir.join("themes").read_dir() {
                let mut user: Vec<PathBuf> = entries
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| {
                        p.extension().is_some_and(|e| e == "json")
                            && p.file_stem().and_then(|s| s.to_str()).is_some_and(valid_id)
                    })
                    .collect();
                user.sort();
                for path in user {
                    let id = path.file_stem().unwrap().to_string_lossy().into_owned();
                    let theme = Self::load(Some(dir), &id);
                    let entry = json!({"id": id, "name": theme.name, "source": "user"});
                    match items.iter().position(|v| v["id"] == entry["id"]) {
                        Some(index) => items[index] = entry,
                        None => items.push(entry),
                    }
                }
            }
        }
        items
    }

    /// Persist tokens as the user copy of this theme (write-through target).
    pub fn write(&self, dir: &Path) -> Result<()> {
        let themes = dir.join("themes");
        std::fs::create_dir_all(&themes)
            .map_err(|e| ApiError::new("unavailable", format!("cannot create styles dir: {e}")))?;
        let mut body = serde_json::to_value(&self.tokens)?;
        body["name"] = json!(self.name);
        std::fs::write(themes.join(format!("{}.json", self.id)), body.to_string())
            .map_err(|e| ApiError::new("unavailable", format!("cannot write theme: {e}")))?;
        Ok(())
    }

    /// Overwrite appearance-related settings fields from the tokens. The theme
    /// file is the single source of truth for these fields.
    pub fn derive(&self, settings: &mut Settings) {
        let t = &self.tokens;
        settings.accent = t.accent.clone();
        settings.radius = t.card_radius;
        settings.font_size = t.body_size;
        let toast = &mut settings.toast;
        toast.title_size = t.title_size;
        toast.title_weight = t.title_weight;
        toast.body_lines = t.body_lines;
        toast.line_height = t.line_height;
        toast.padding = t.padding;
        toast.gap = t.gap;
        toast.border_style = t.border_style.clone();
        toast.border_width = t.border_width;
        toast.border_color = flatten_fill(&t.border_color);
        toast.background = match &t.card_fill {
            Fill::Flat(s) if s == "auto" => "theme".into(),
            Fill::Flat(s) => s.clone(),
            Fill::Split { .. } => "theme".into(),
        };
        toast.text_color = flatten_fill(&t.text_fill);
        toast.level_accent = t.level_accent;
        toast.shadow = t.shadow;
        toast.header = t.header.clone();
        toast.header_label = t.header_label.clone();
        toast.header_separator = t.header_separator;
        toast.show_icon = t.show_icon;
        toast.show_time = t.show_time;
        toast.show_level = t.show_level;
        toast.text_align = t.text_align.clone();
        toast.show_body = t.show_body;
        toast.show_progress = t.show_progress;
        toast.show_tags = t.show_tags;
        toast.show_history = t.show_history;
        toast.actions_layout = t.actions_layout.clone();
    }

    /// Push settings-field edits back into the tokens where they differ from
    /// the derived baseline. Returns true when any token changed.
    pub fn merge_edits(&mut self, baseline: &Settings, edited: &Settings) -> bool {
        let before = serde_json::to_value(&self.tokens).unwrap_or_default();
        *self.tokens_mut() = tokens_from_mix(&self.tokens, baseline, edited);
        serde_json::to_value(&self.tokens).unwrap_or_default() != before
    }

    fn tokens_mut(&mut self) -> &mut Tokens {
        &mut self.tokens
    }
}

fn flatten_fill(value: &str) -> String {
    if value == "auto" {
        "theme".into()
    } else {
        value.to_string()
    }
}

fn lift_fill(value: &str) -> String {
    if value == "theme" {
        "auto".into()
    } else {
        value.to_string()
    }
}

/// Rebuild tokens from stored settings fields where the caller changed them.
fn tokens_from_mix(current: &Tokens, baseline: &Settings, edited: &Settings) -> Tokens {
    let mut tokens = tokens_from(edited);
    // Keep new-surface tokens untouched by settings edits.
    tokens.level_success = current.level_success.clone();
    tokens.level_warning = current.level_warning.clone();
    tokens.level_error = current.level_error.clone();
    tokens.bezel_fill = current.bezel_fill.clone();
    tokens.bezel_icon_size = current.bezel_icon_size;
    tokens.pill_fill = current.pill_fill.clone();
    tokens.pill_height = current.pill_height;
    tokens.panel_fill = current.panel_fill.clone();
    tokens.panel_max_height = current.panel_max_height;
    tokens.card_fill = if baseline.toast.background == edited.toast.background {
        current.card_fill.clone()
    } else if edited.toast.background == "theme" {
        Fill::Flat("auto".into())
    } else {
        Fill::Flat(edited.toast.background.clone())
    };
    tokens.accent = if baseline.accent == edited.accent {
        current.accent.clone()
    } else {
        edited.accent.clone()
    };
    tokens
}

/// Inverse of derive: rebuild the token table from stored settings fields.
pub fn tokens_from(settings: &Settings) -> Tokens {
    let t = &settings.toast;
    Tokens {
        accent: settings.accent.clone(),
        card_fill: if t.background == "theme" {
            Fill::Flat("auto".into())
        } else {
            Fill::Flat(t.background.clone())
        },
        text_fill: lift_fill(&t.text_color),
        card_radius: settings.radius,
        title_size: t.title_size,
        title_weight: t.title_weight,
        body_size: settings.font_size,
        line_height: t.line_height,
        body_lines: t.body_lines,
        padding: t.padding,
        gap: t.gap,
        border_style: t.border_style.clone(),
        border_width: t.border_width,
        border_color: lift_fill(&t.border_color),
        level_accent: t.level_accent,
        shadow: t.shadow,
        header: t.header.clone(),
        header_label: t.header_label.clone(),
        header_separator: t.header_separator,
        show_icon: t.show_icon,
        show_time: t.show_time,
        show_level: t.show_level,
        text_align: t.text_align.clone(),
        show_body: t.show_body,
        show_progress: t.show_progress,
        show_tags: t.show_tags,
        show_history: t.show_history,
        actions_layout: t.actions_layout.clone(),
        ..Tokens::default()
    }
}

/// First-launch migration: export the persisted toast appearance as the user's
/// default.json so the theme file becomes the single source of truth.
pub fn export_default_if_absent(dir: &Path, settings: &Settings) -> Result<()> {
    let themes = dir.join("themes");
    let path = themes.join("default.json");
    if path.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(&themes)
        .map_err(|e| ApiError::new("unavailable", format!("cannot create styles dir: {e}")))?;
    let mut body = serde_json::to_value(tokens_from(settings))?;
    body["name"] = json!("默认");
    std::fs::write(&path, body.to_string())
        .map_err(|e| ApiError::new("unavailable", format!("cannot export theme: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mdn-theme-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn default_theme_derives_today_pixel_for_pixel() {
        let theme = Theme::load(None, "default");
        assert_eq!(theme.diagnostics, Vec::<String>::new());
        let mut settings = Settings::default();
        let before = serde_json::to_value(&settings).unwrap();
        theme.derive(&mut settings);
        assert_eq!(before, serde_json::to_value(&settings).unwrap());
    }

    #[test]
    fn explicit_null_tokens_mean_unset_not_errors() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("themes")).unwrap();
        std::fs::write(
            dir.join("themes").join("midnight.json"),
            r#"{"name":"X","titleSize":null}"#,
        )
        .unwrap();
        let theme = Theme::load(Some(&dir), "midnight");
        assert_eq!(
            theme.tokens.title_size, 15,
            "null falls back to the default"
        );
        assert_eq!(theme.diagnostics, Vec::<String>::new());
    }

    #[test]
    fn embedded_pack_loads_clean_and_derives_valid_settings() {
        for id in EMBEDDED.iter().map(|(id, _, _)| *id) {
            let theme = Theme::load(None, id);
            assert_eq!(theme.diagnostics, Vec::<String>::new(), "{id}");
            let mut settings = Settings::default();
            theme.derive(&mut settings);
            settings
                .validate()
                .unwrap_or_else(|e| panic!("{id}: {e:?}"));
        }
    }

    #[test]
    fn lenient_decode_ignores_unknowns_clamps_numbers_and_rejects_bad_colors() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("themes")).unwrap();
        std::fs::write(
            dir.join("themes").join("midnight.json"),
            r#"{"name":"X","titleSize":99,"padding":2,"accent":"red","typo":1,"header":"weird","pillHeight":40}"#,
        )
        .unwrap();
        let theme = Theme::load(Some(&dir), "midnight");
        assert_eq!(theme.source, "user");
        assert_eq!(theme.tokens.title_size, 28);
        assert_eq!(theme.tokens.padding, 8);
        assert_eq!(theme.tokens.accent, "#7c6cf0");
        assert_eq!(theme.tokens.header, "full");
        assert_eq!(theme.tokens.pill_height, 40);
        assert!(theme.diagnostics.iter().any(|d| d.contains("typo")));
        assert!(theme.diagnostics.iter().any(|d| d.contains("accent")));
        assert!(theme.diagnostics.iter().any(|d| d.contains("titleSize")));
    }

    #[test]
    fn corrupt_user_file_keeps_builtin() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("themes")).unwrap();
        std::fs::write(dir.join("themes").join("midnight.json"), "{not json").unwrap();
        let theme = Theme::load(Some(&dir), "midnight");
        assert_eq!(theme.source, "builtin");
        assert!(!theme.diagnostics.is_empty());
        assert_eq!(theme.tokens.card_radius, 18);
    }

    #[test]
    fn write_through_round_trips() {
        let dir = tempdir();
        let mut edited = Theme::load(None, "default");
        edited.tokens.title_size = 22;
        edited.write(&dir).unwrap();
        let reloaded = Theme::load(Some(&dir), "default");
        assert_eq!(reloaded.source, "user");
        assert_eq!(reloaded.tokens.title_size, 22);
        assert_eq!(reloaded.tokens.gap, 8);
    }

    #[test]
    fn merge_edits_only_touches_changed_fields() {
        let dir = tempdir();
        let mut theme = Theme::load(Some(&dir), "default");
        theme.tokens.pill_fill = "#111111".into();
        let mut baseline = Settings::default();
        theme.derive(&mut baseline);
        let mut edited = baseline.clone();
        edited.toast.title_size = 22;
        assert!(theme.merge_edits(&baseline, &edited));
        assert_eq!(theme.tokens.title_size, 22);
        assert_eq!(theme.tokens.pill_fill, "#111111");
        // No-op edits against a fresh theme leave it untouched.
        let mut fresh = Theme::load(None, "default");
        let mut base = Settings::default();
        fresh.derive(&mut base);
        assert!(!fresh.merge_edits(&base, &base));
    }

    #[test]
    fn migration_exports_stored_appearance_once() {
        let dir = tempdir();
        let mut settings = Settings::default();
        settings.toast.title_size = 22;
        settings.accent = "#123456".into();
        export_default_if_absent(&dir, &settings).unwrap();
        let theme = Theme::load(Some(&dir), "default");
        assert_eq!(theme.source, "user");
        assert_eq!(theme.tokens.title_size, 22);
        assert_eq!(theme.tokens.accent, "#123456");
        // Second run must not overwrite user tweaks.
        let mut drift = settings.clone();
        drift.accent = "#abcdef".into();
        export_default_if_absent(&dir, &drift).unwrap();
        assert_eq!(Theme::load(Some(&dir), "default").tokens.accent, "#123456");
    }

    #[test]
    fn list_merges_user_files_over_builtins() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("themes")).unwrap();
        std::fs::write(
            dir.join("themes").join("default.json"),
            r#"{"name":"我的默认","tokens":{}}"#,
        )
        .unwrap();
        std::fs::write(
            dir.join("themes").join("custom.json"),
            r#"{"name":"自定义"}"#,
        )
        .unwrap();
        let items = Theme::list(Some(&dir));
        assert_eq!(items.len(), 5);
        let names: Vec<&str> = items
            .iter()
            .map(|v| v["name"].as_str().unwrap_or_default())
            .collect();
        assert!(names.contains(&"我的默认"));
        assert!(names.contains(&"自定义"));
        assert!(names.contains(&"午夜"));
        let custom = items.iter().find(|v| v["id"] == "custom").unwrap();
        assert_eq!(custom["source"], "user");
        let default = items.iter().find(|v| v["id"] == "default").unwrap();
        assert_eq!(default["source"], "user");
    }
}
