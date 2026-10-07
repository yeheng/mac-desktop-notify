//! Layout node DSL (opt-in): `styles/layouts/<id>.json` holds one node tree
//! per presenter surface. Rust only moves bytes — size cap, JSON shape and a
//! surface-name closed set — while the TS renderer validates nodes and falls
//! back per surface. No file (or `layout_id: "default"`) means the built-in
//! TS layouts, which is today's code path.

use serde::Serialize;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// Surfaces a layout file may define; anything else is dropped with a note.
pub const SURFACES: [&str; 4] = ["card", "island.pill", "island.panel", "bezel"];

/// Embedded example proving the DSL end to end (pill + panel, midnight look).
const EMBEDDED_MIDNIGHT: &str = r##"{
  "name": "午夜示例",
  "surfaces": {
    "island.pill": {
      "type": "hstack", "spacing": 8, "padding": 14, "background": "@pillFill", "clip": true,
      "children": [
        {"type": "icon", "name": "$icon"},
        {"type": "text", "text": "$title", "marquee": true, "frame": {"flex": 1}},
        {"type": "badge", "text": "$unread", "if": "manyUnread"}
      ]
    },
    "island.panel": {
      "type": "vstack", "spacing": 10, "padding": 14, "background": "@panelFill", "clip": true,
      "children": [
        {"type": "hstack", "spacing": 8, "children": [
          {"type": "text", "text": "$unread", "frame": {"flex": 1}},
          {"type": "text", "text": "$time", "opacity": 0.6}
        ]},
        {"type": "slot", "slot": "messageBody"},
        {"type": "divider", "if": "hasBody"},
        {"type": "slot", "slot": "list"},
        {"type": "slot", "slot": "actions"}
      ]
    }
  }
}"##;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub id: String,
    pub name: String,
    pub source: &'static str,
    /// Surface name → node tree, passed through verbatim.
    pub surfaces: Map<String, Value>,
    pub diagnostics: Vec<String>,
}

impl Layout {
    /// `default` is not a file: it selects the built-in TS layouts.
    pub fn load(dir: Option<&Path>, id: &str) -> Option<Self> {
        if id == "default" {
            return None;
        }
        let id = if crate::theme::valid_id(id) {
            id
        } else {
            return None;
        };
        let read = |raw: &str, source: &'static str| -> Self {
            let mut diagnostics = vec![];
            let parsed: Value = match serde_json::from_str(raw) {
                Ok(value) => value,
                Err(_) => {
                    return Self::builtin_malformed(id, source, "is not valid JSON");
                }
            };
            let surfaces_value = &parsed["surfaces"];
            let Some(surface_map) = surfaces_value.as_object() else {
                return Self::builtin_malformed(id, source, "has no surfaces object");
            };
            let surfaces = surface_map
                .iter()
                .filter(|(name, tree)| {
                    let known = SURFACES.contains(&name.as_str()) && tree.is_object();
                    if !known {
                        diagnostics.push(format!("layouts/{id}.json: surface {name} dropped"));
                    }
                    known
                })
                .map(|(name, tree)| (name.clone(), tree.clone()))
                .collect::<Map<String, Value>>();
            let name = parsed["name"]
                .as_str()
                .filter(|s| !s.is_empty() && s.chars().count() <= 40)
                .unwrap_or(id)
                .to_string();
            Self {
                id: id.into(),
                name,
                source,
                surfaces,
                diagnostics,
            }
        };
        if let Some(dir) = dir {
            let path = dir.join("layouts").join(format!("{id}.json"));
            if let Ok(raw) = std::fs::read_to_string(&path) {
                if raw.len() > 64 * 1024 {
                    let mut layout = read(&raw, "user");
                    layout.surfaces.clear();
                    layout.diagnostics.push(format!(
                        "layouts/{id}.json exceeds 64KB; falling back to built-in"
                    ));
                    return Some(layout);
                }
                return Some(read(&raw, "user"));
            }
        }
        if id == "midnight" {
            return Some(read(EMBEDDED_MIDNIGHT, "builtin"));
        }
        None
    }

    fn builtin_malformed(id: &str, source: &str, why: &str) -> Self {
        Self {
            id: id.into(),
            name: id.into(),
            source: "user",
            surfaces: Map::new(),
            diagnostics: vec![format!("layouts/{id}.json ({source}) {why}")],
        }
    }

    /// Selectable layouts: the built-in default plus embedded and user files.
    pub fn list(dir: Option<&Path>) -> Vec<Value> {
        let mut items = vec![json!({"id": "default", "name": "内置布局", "source": "builtin"})];
        let mut user_ids: Vec<String> = vec![];
        if let Some(dir) = dir {
            if let Ok(entries) = dir.join("layouts").read_dir() {
                let mut files: Vec<PathBuf> = entries
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| {
                        p.extension().is_some_and(|e| e == "json")
                            && p.file_stem()
                                .and_then(|s| s.to_str())
                                .is_some_and(crate::theme::valid_id)
                    })
                    .collect();
                files.sort();
                for path in files {
                    let id = path.file_stem().unwrap().to_string_lossy().into_owned();
                    if let Some(layout) = Self::load(Some(dir), &id) {
                        user_ids.push(id.clone());
                        items.push(json!({"id": id, "name": layout.name, "source": "user"}));
                    }
                }
            }
        }
        // The embedded example only answers when no user file owns the id.
        if !user_ids.iter().any(|id| id == "midnight") {
            items.push(json!({"id": "midnight", "name": "午夜示例", "source": "builtin"}));
        }
        items
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mdn-layout-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn default_selects_builtin_ts_and_embedded_example_parses() {
        assert!(Layout::load(None, "default").is_none());
        let midnight = Layout::load(None, "midnight").expect("embedded example exists");
        assert_eq!(midnight.source, "builtin");
        assert_eq!(midnight.diagnostics, Vec::<String>::new());
        assert_eq!(midnight.surfaces.len(), 2);
        assert!(midnight.surfaces.contains_key("island.pill"));
        assert_eq!(midnight.surfaces["island.panel"]["type"], "vstack");
    }

    #[test]
    fn user_files_override_and_bad_files_survive() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("layouts")).unwrap();
        std::fs::write(
            dir.join("layouts").join("midnight.json"),
            r##"{"name":"我的午夜","surfaces":{"island.pill":{"type":"text","text":"$title"},"bogus":{"type":"text"},"bezel":"not-a-tree"}}"##,
        )
        .unwrap();
        let layout = Layout::load(Some(&dir), "midnight").unwrap();
        assert_eq!(layout.source, "user");
        assert_eq!(layout.name, "我的午夜");
        assert_eq!(layout.surfaces.len(), 1);
        assert_eq!(layout.diagnostics.len(), 2);
        // Malformed JSON degrades to an empty layout with diagnostics intact.
        std::fs::write(dir.join("layouts").join("midnight.json"), "{oops").unwrap();
        let broken = Layout::load(Some(&dir), "midnight").unwrap();
        assert!(broken.surfaces.is_empty());
        assert_eq!(broken.diagnostics.len(), 1);
        assert!(!broken.diagnostics[0].is_empty());
        // Oversized files fall back whole.
        let huge = format!("{{\"surfaces\":{{\"card\":{}}}}}", "[1,".repeat(40000));
        std::fs::write(dir.join("layouts").join("midnight.json"), huge).unwrap();
        let oversized = Layout::load(Some(&dir), "midnight").unwrap();
        assert!(oversized.surfaces.is_empty());
        assert!(oversized.diagnostics.iter().any(|d| d.contains("64KB")));
    }

    #[test]
    fn list_merges_builtin_and_user_entries() {
        let dir = tempdir();
        std::fs::create_dir_all(dir.join("layouts")).unwrap();
        std::fs::write(
            dir.join("layouts").join("custom.json"),
            r##"{"name":"自定义","surfaces":{"card":{"type":"text","text":"$title"}}}"##,
        )
        .unwrap();
        std::fs::write(
            dir.join("layouts").join("midnight.json"),
            r##"{"surfaces":{}}"##,
        )
        .unwrap();
        let items = Layout::list(Some(&dir));
        let ids: Vec<&str> = items
            .iter()
            .map(|v| v["id"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(ids.len(), 3);
        assert!(ids.contains(&"default") && ids.contains(&"midnight") && ids.contains(&"custom"));
        // A user midnight replaces the embedded entry rather than duplicating it.
        assert_eq!(
            items.iter().filter(|v| v["id"] == "midnight").count(),
            1usize
        );
        assert_eq!(
            items.iter().find(|v| v["id"] == "midnight").unwrap()["source"],
            "user"
        );
    }
}
