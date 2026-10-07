use crate::model::*;
use chrono::Timelike;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
fn token_hash(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}
use crate::theme;
use std::{
    collections::HashMap,
    net::ToSocketAddrs,
    path::{Path, PathBuf},
    time::Instant,
};

pub struct Store {
    conn: Connection,
    clocks: HashMap<String, (Instant, i64, bool)>,
    last_cleanup: i64,
    changes: tokio::sync::watch::Sender<u64>,
    styles_dir: Option<PathBuf>,
}
fn parse(s: String) -> Result<Value> {
    Ok(serde_json::from_str(&s)?)
}
/// Replace integer 0/1 with real booleans for a known bool field, marking the
/// row dirty so the caller can self-heal the persisted payload.
fn coerce_int_bool(map: &mut serde_json::Map<String, Value>, key: &str, dirty: &mut bool) {
    if let Some(Value::Number(number)) = map.get(key) {
        if matches!(number.as_i64(), Some(0 | 1)) {
            map.insert(key.to_string(), Value::Bool(number.as_i64() == Some(1)));
            *dirty = true;
        }
    }
}
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .ok_or_else(|| ApiError::invalid(format!("{key} required")))
}
fn event(tx: &Transaction<'_>, id_: &str, kind: &str, data: Value, at: i64) -> Result<()> {
    let (source, revision, payload): (String, i64, String) = tx.query_row(
        "SELECT source,revision,payload FROM notifications WHERE id=?",
        [id_],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let eid = id();
    tx.execute("INSERT INTO events(event_id,notification_id,source,revision,type,data,created_at) VALUES(?,?,?,?,?,?,?)", params![eid,id_,source,revision,kind,data.to_string(),at])?;
    let seq = tx.last_insert_rowid();
    let payload: Create = serde_json::from_str(&payload)?;
    if let Some(endpoint) = payload.callback_endpoint_id {
        let body = json!({"event_id":eid,"seq":seq,"notification_id":id_,"revision":revision,"type":kind,"data":data,"created_at":at});
        tx.execute("INSERT INTO deliveries(event_id,endpoint_id,source,body,next_attempt_at) VALUES(?,?,?,?,?)", params![eid,endpoint,source,body.to_string(),at])?;
    }
    Ok(())
}
impl Store {
    pub fn open(path: &Path, styles_dir: Option<&Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(3))?;
        let _: String = conn.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
        conn.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            return Err(ApiError::new(
                "unavailable",
                "database schema is newer than this application",
            ));
        }
        conn.execute_batch("BEGIN;
          CREATE TABLE IF NOT EXISTS notifications(id TEXT PRIMARY KEY,source TEXT NOT NULL,client_id TEXT NOT NULL,original TEXT NOT NULL,payload TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,level TEXT NOT NULL,group_key TEXT NOT NULL,dedupe_key TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 1,read_at INTEGER,archived_at INTEGER,UNIQUE(source,client_id));
          CREATE TABLE IF NOT EXISTS presentations(notification_id TEXT PRIMARY KEY REFERENCES notifications(id) ON DELETE CASCADE,state TEXT NOT NULL,reason TEXT NOT NULL DEFAULT '',scheduled_at INTEGER NOT NULL,displayed_at INTEGER,closed_at INTEGER,merge_count INTEGER NOT NULL DEFAULT 1);
          CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,notification_id TEXT NOT NULL,source TEXT NOT NULL,revision INTEGER NOT NULL,type TEXT NOT NULL,data TEXT NOT NULL,created_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS endpoints(id TEXT PRIMARY KEY,source TEXT NOT NULL,url TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS deliveries(id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT NOT NULL,endpoint_id TEXT NOT NULL REFERENCES endpoints(id),source TEXT NOT NULL,body TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at INTEGER NOT NULL,status TEXT NOT NULL DEFAULT 'pending',last_error TEXT,UNIQUE(event_id,endpoint_id));
          CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,token TEXT NOT NULL UNIQUE);
          CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
          INSERT OR IGNORE INTO metadata VALUES('event_floor',0);
          INSERT OR IGNORE INTO metadata VALUES('summary_ack',0);
          INSERT OR IGNORE INTO metadata VALUES('summary_shown_at',0);
          CREATE INDEX IF NOT EXISTS notification_order ON notifications(created_at DESC,id DESC);
          CREATE INDEX IF NOT EXISTS notification_source ON notifications(source,created_at);
          CREATE INDEX IF NOT EXISTS notification_group ON notifications(source,group_key);
          CREATE INDEX IF NOT EXISTS event_source ON events(source,seq);
          CREATE INDEX IF NOT EXISTS delivery_pending ON deliveries(status,next_attempt_at);
          CREATE INDEX IF NOT EXISTS event_notification ON events(notification_id,seq);
          CREATE INDEX IF NOT EXISTS event_type_time ON events(type,created_at);
          CREATE INDEX IF NOT EXISTS presentation_state ON presentations(state,scheduled_at);
          CREATE INDEX IF NOT EXISTS notification_unread ON notifications(created_at DESC) WHERE read_at IS NULL AND archived_at IS NULL;
          CREATE VIRTUAL TABLE IF NOT EXISTS notification_fts USING fts5(title,body,content='notifications',content_rowid='rowid');
          CREATE TRIGGER IF NOT EXISTS notification_ai AFTER INSERT ON notifications BEGIN INSERT INTO notification_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body); END;
          CREATE TRIGGER IF NOT EXISTS notification_ad AFTER DELETE ON notifications BEGIN INSERT INTO notification_fts(notification_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body); END;
          CREATE TRIGGER IF NOT EXISTS notification_au AFTER UPDATE OF title,body ON notifications BEGIN INSERT INTO notification_fts(notification_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body); INSERT INTO notification_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body); END;
          PRAGMA user_version=1; COMMIT;")?;
        conn.execute(
            "INSERT OR IGNORE INTO settings VALUES(1,?)",
            [serde_json::to_string(&Settings::default())?],
        )?;
        let (changes, _) = tokio::sync::watch::channel(0u64);
        Ok(Self {
            conn,
            clocks: HashMap::new(),
            last_cleanup: 0,
            changes,
            styles_dir: styles_dir.map(Path::to_path_buf),
        })
    }
    /// In-process change signal; bumped only after commits that alter persisted state.
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<u64> {
        self.changes.subscribe()
    }
    fn changed(&self) {
        self.changes.send_modify(|value| *value += 1);
    }
    /// Settings plus the active theme pack: toast appearance fields are
    /// derived from the theme file, which is their single source of truth.
    fn decorated_settings(&self) -> Result<Value> {
        let mut settings = self.settings()?;
        let mut value = serde_json::to_value(&settings)?;
        if let Some(dir) = self.styles_dir.clone() {
            let theme = theme::Theme::load(Some(&dir), &settings.theme_id);
            theme.derive(&mut settings);
            value = serde_json::to_value(&settings)?;
            value["style"] = json!({"theme": theme});
        }
        Ok(value)
    }
    /// Unread count driving the tray badge, plus whether the badge is on.
    pub fn tray_state(&self) -> Result<Value> {
        let enabled = self.settings()?.tray_badge_enabled;
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM notifications WHERE read_at IS NULL AND archived_at IS NULL",
            [],
            |r| r.get(0),
        )?;
        Ok(json!({"count": count, "enabled": enabled}))
    }
    pub fn settings(&self) -> Result<Settings> {
        let payload: String =
            self.conn
                .query_row("SELECT payload FROM settings WHERE id=1", [], |r| {
                    r.get::<_, String>(0)
                })?;
        let mut value: Value = serde_json::from_str(&payload)?;
        let mut dirty = false;
        // Retired settings keys must not fail the strict parse of older rows.
        if let Some(map) = value.as_object_mut() {
            for key in ["presenter", "window_style", "bezel_enabled", "layout_id"] {
                dirty |= map.remove(key).is_some();
            }
        }
        // Rows saved before the frosted-glass removal still carry those keys,
        // which are now unknown fields and would fail parsing.
        if let Some(toast) = value.get_mut("toast").and_then(Value::as_object_mut) {
            let material = toast.remove("material").is_some();
            let tint = toast.remove("tint_opacity").is_some();
            dirty = dirty || material || tint;
        }
        // Payloads touched by one-off experiments may hold 0/1 where booleans
        // belong; a strict parse would fail every tick until manually repaired.
        // Coerce them and self-heal the row in the same pass.
        if let Some(map) = value.as_object_mut() {
            for key in ["reduced_motion", "tray_badge_enabled"] {
                coerce_int_bool(map, key, &mut dirty);
            }
        }
        if let Some(toast) = value.get_mut("toast").and_then(Value::as_object_mut) {
            for key in [
                "header_separator",
                "show_icon",
                "show_time",
                "show_level",
                "level_accent",
                "shadow",
                "show_body",
                "show_progress",
                "show_tags",
                "show_history",
            ] {
                coerce_int_bool(toast, key, &mut dirty);
            }
        }
        if dirty {
            self.conn.execute(
                "UPDATE settings SET payload=? WHERE id=1",
                [value.to_string()],
            )?;
        }
        Ok(serde_json::from_value(value)?)
    }
    pub fn authenticate(&self, token: &str) -> Result<Value> {
        let source: Option<String> = self
            .conn
            .query_row(
                "SELECT id FROM sources WHERE token=?",
                [token_hash(token)],
                |r| r.get(0),
            )
            .optional()?;
        source
            .map(|s| json!(s))
            .ok_or_else(|| ApiError::new("unauthorized", "invalid token"))
    }
    fn authorize(&self, source: Option<&str>, id_: &str) -> Result<()> {
        let owner: Option<String> = self
            .conn
            .query_row("SELECT source FROM notifications WHERE id=?", [id_], |r| {
                r.get(0)
            })
            .optional()?;
        match owner {
            Some(s) if source.is_none_or(|x| x == s) => Ok(()),
            _ => Err(ApiError::new("not_found", "notification not found")),
        }
    }
    pub fn command(&mut self, source: Option<&str>, op: &str, data: Value) -> Result<Value> {
        match op {
            "notification.create" => self.create(
                source.unwrap_or("desktop"),
                serde_json::from_value(data)?,
                now(),
            ),
            "notification.update" => self.update(source, data),
            "notification.get" => {
                let id_ = string(&data, "id")?;
                self.authorize(source, id_)?;
                self.get(id_)
            }
            "notification.list" => self.list(source, &data),
            "notification.cancel" => {
                let id_ = string(&data, "id")?;
                self.authorize(source, id_)?;
                self.finish(id_, None, "cancelled", json!({}), now())
            }
            "notification.mark_read" | "notification.archive" => {
                let ids = data["ids"]
                    .as_array()
                    .ok_or_else(|| ApiError::invalid("ids array required"))?;
                if ids.len() > 500 {
                    return Err(ApiError::invalid("maximum 500 ids"));
                }
                for id_ in ids {
                    self.authorize(
                        source,
                        id_.as_str()
                            .ok_or_else(|| ApiError::invalid("invalid id"))?,
                    )?;
                }
                // Omitted flags preserve the existing mark-read/archive API.
                // Explicit false restores unread/unarchived state atomically.
                let flag = if op.ends_with("archive") { "archived" } else { "read" };
                let enabled = match data.get(flag) {
                    None => true,
                    Some(value) => value.as_bool().ok_or_else(|| ApiError::invalid("state flag must be boolean"))?,
                };
                let tx = self.conn.transaction()?;
                let at = enabled.then_some(now());
                for id_ in ids {
                    tx.execute(
                        if op.ends_with("archive") {
                            "UPDATE notifications SET archived_at=? WHERE id=?"
                        } else {
                            "UPDATE notifications SET read_at=? WHERE id=?"
                        },
                        params![at, id_.as_str()],
                    )?;
                }
                tx.commit()?;
                self.changed();
                Ok(json!({"updated":ids.len()}))
            }
            "events.subscribe" | "events.list" => {
                self.events(source, data["after_seq"].as_i64().unwrap_or(0))
            }
            "settings.get" if source.is_none() => self.decorated_settings(),
            "settings.set" if source.is_none() => {
                let incoming: Settings = serde_json::from_value(data)?;
                incoming.validate()?;
                if let Some(dir) = self.styles_dir.clone() {
                    // The theme file is the appearance source of truth: field
                    // edits write through into the active theme. A theme
                    // switch resets appearance wholesale, so stale form values
                    // never leak into the newly selected theme.
                    let stored = self.settings()?;
                    if incoming.theme_id == stored.theme_id {
                        let mut active = theme::Theme::load(Some(&dir), &incoming.theme_id);
                        let mut baseline = stored;
                        active.derive(&mut baseline);
                        if active.merge_edits(&baseline, &incoming) {
                            active.write(&dir)?;
                        }
                    }
                }
                self.conn.execute(
                    "UPDATE settings SET payload=? WHERE id=1",
                    [serde_json::to_string(&incoming)?],
                )?;
                self.changed();
                self.decorated_settings()
            }
            "themes.list" if source.is_none() => {
                Ok(json!(theme::Theme::list(self.styles_dir.as_deref())))
            }
            "sources.list" if source.is_none() => {
                let mut stmt = self.conn.prepare("SELECT id FROM sources ORDER BY id")?;
                let ids = stmt
                    .query_map([], |r| r.get::<_, String>(0))?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                Ok(json!(ids))
            }
            "sources.create" if source.is_none() => {
                let name = string(&data, "id")?;
                if name.is_empty()
                    || name.len() > 80
                    || !name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
                    || name == "desktop"
                {
                    return Err(ApiError::invalid("source id must be 1-80 ASCII letters, digits, hyphen or underscore; desktop reserved"));
                }
                let token = format!("{}{}", id(), id());
                self.conn
                    .execute(
                        "INSERT INTO sources(id,token) VALUES(?,?)",
                        params![name, token_hash(&token)],
                    )
                    .map_err(|_| ApiError::new("conflict", "source already exists"))?;
                self.changed();
                Ok(json!({"id":name,"token":token}))
            }
            "endpoints.list" if source.is_none() => {
                let mut stmt = self
                    .conn
                    .prepare("SELECT id,source,url FROM endpoints ORDER BY id")?;
                let rows=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"source":r.get::<_,String>(1)?,"url":r.get::<_,String>(2)?})))?.collect::<std::result::Result<Vec<_>,_>>()?;
                Ok(json!(rows))
            }
            "endpoints.create" if source.is_none() => {
                let id_ = string(&data, "id")?;
                let src = string(&data, "source")?;
                let url = string(&data, "url")?;
                let parsed = reqwest::Url::parse(url).map_err(ApiError::invalid)?;
                if id_.is_empty()
                    || id_.len() > 100
                    || !["http", "https"].contains(&parsed.scheme())
                    || parsed.host_str().is_none()
                    || !parsed.username().is_empty()
                    || parsed.password().is_some()
                    || parsed.fragment().is_some()
                {
                    return Err(ApiError::invalid("invalid endpoint"));
                }
                // Webhook targets must stay on this machine unless the operator
                // explicitly opts into LAN delivery; blocks SSRF from any
                // authenticated source towards internal nets or cloud metadata.
                // DNS is resolved at registration time only; reqwest re-resolves later.
                let allow_lan =
                    std::env::var("MAC_NOTIFY_ALLOW_LAN_CALLBACKS").as_deref() == Ok("1");
                let host = parsed.host_str().unwrap_or_default().to_string();
                let port = parsed.port_or_known_default().unwrap_or(80);
                let resolved = (host.as_str(), port)
                    .to_socket_addrs()
                    .map_err(|_| ApiError::invalid("endpoint host cannot be resolved"))?
                    .collect::<Vec<_>>();
                if resolved.is_empty()
                    || resolved.iter().any(|addr| {
                        let allowed = match addr.ip() {
                            std::net::IpAddr::V4(ip) => {
                                ip.is_loopback()
                                    || (allow_lan && (ip.is_private() || ip.is_link_local()))
                            }
                            std::net::IpAddr::V6(ip) => {
                                ip.is_loopback()
                                    || (allow_lan
                                        && (ip.is_unique_local() || ip.is_unicast_link_local()))
                            }
                        };
                        !allowed
                    })
                {
                    return Err(ApiError::invalid(
                        "endpoint must address loopback; set MAC_NOTIFY_ALLOW_LAN_CALLBACKS=1 to allow LAN targets",
                    ));
                }
                let exists = src == "desktop"
                    || self.conn.query_row(
                        "SELECT EXISTS(SELECT 1 FROM sources WHERE id=?)",
                        [src],
                        |r| r.get::<_, bool>(0),
                    )?;
                if !exists {
                    return Err(ApiError::invalid("unknown source"));
                }
                self.conn.execute("INSERT INTO endpoints(id,source,url) VALUES(?,?,?)",params![id_,src,url]).map_err(|_|ApiError::new("conflict","endpoint already exists; create a new id to preserve pending delivery destinations"))?;
                self.changed();
                Ok(json!({"id":id_}))
            }
            "deliveries.retry" if source.is_none() => {
                let id_ = data["id"]
                    .as_i64()
                    .ok_or_else(|| ApiError::invalid("id required"))?;
                let n=self.conn.execute("UPDATE deliveries SET status='pending',attempts=0,next_attempt_at=? WHERE id=? AND status='failed'",params![now(),id_])?;
                if n > 0 {
                    self.changed();
                }
                Ok(json!({"updated":n}))
            }
            "toast.snapshot" if source.is_none() => self.snapshot(),
            "summary.dismiss" if source.is_none() => {
                let seq = data["through_seq"]
                    .as_i64()
                    .ok_or_else(|| ApiError::invalid("through_seq required"))?;
                let max:i64=self.conn.query_row("SELECT MAX((SELECT value FROM metadata WHERE key='event_floor'),COALESCE(MAX(seq),0)) FROM events",[],|r|r.get(0))?;
                if seq > max {
                    return Err(ApiError::invalid("invalid summary cursor"));
                }
                self.conn.execute(
                    "UPDATE metadata SET value=MAX(value,?) WHERE key='summary_ack'",
                    [seq],
                )?;
                self.conn.execute(
                    "UPDATE metadata SET value=? WHERE key='summary_shown_at'",
                    [now()],
                )?;
                self.changed();
                Ok(json!({}))
            }
            "toast.displayed" if source.is_none() => self.displayed(&data),
            // Bezel flashes record history only: they never claim a showing
            // slot and never substitute for the main presenter's acknowledgment.
            "toast.interact" if source.is_none() => {
                let id_ = string(&data, "id")?;
                let rev = data["revision"]
                    .as_i64()
                    .ok_or_else(|| ApiError::invalid("revision required"))?;
                let kind = string(&data, "kind")?;
                if !["dismissed", "action_invoked"].contains(&kind) {
                    return Err(ApiError::invalid("invalid interaction"));
                }
                if kind == "action_invoked" {
                    let n = self.get(id_)?;
                    let action = string(&data, "action_id")?;
                    if !n["actions"]
                        .as_array()
                        .is_some_and(|a| a.iter().any(|v| v["id"] == action))
                    {
                        return Err(ApiError::new("invalid_request", "unknown action"));
                    }
                    // Acting on a notification is the strongest read signal:
                    // mark it read in the same stroke as the finish event.
                    self.conn.execute(
                        "UPDATE notifications SET read_at=? WHERE id=? AND read_at IS NULL",
                        params![now(), id_],
                    )?;
                }
                self.finish(
                    id_,
                    Some(rev),
                    kind,
                    json!({"action_id":data["action_id"]}),
                    now(),
                )
            }
            "toast.hover" if source.is_none() => {
                let id_ = string(&data, "id")?;
                if let Some((last, remaining, paused)) = self.clocks.get_mut(id_) {
                    if !*paused {
                        *remaining -= last.elapsed().as_millis() as i64;
                    }
                    *last = Instant::now();
                    *paused = data["paused"].as_bool().unwrap_or(false);
                }
                Ok(json!({}))
            }
            _ => Err(ApiError::new(
                "invalid_request",
                "unknown or forbidden command",
            )),
        }
    }
    pub fn create(&mut self, source: &str, input: Create, at: i64) -> Result<Value> {
        input.validate()?;
        let original = serde_json::to_string(&input)?;
        let existing: Option<(String, String)> = self
            .conn
            .query_row(
                "SELECT id,original FROM notifications WHERE source=? AND client_id=?",
                params![source, input.client_message_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((id_, previous)) = existing {
            if previous != original {
                return Err(ApiError::new(
                    "conflict",
                    "client_message_id already used with different payload",
                ));
            }
            return Ok(json!({"notification_id":id_,"accepted":true,"duplicate":true}));
        }
        if let Some(endpoint) = &input.callback_endpoint_id {
            let valid: bool = self.conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM endpoints WHERE id=? AND source=?)",
                params![endpoint, source],
                |r| r.get(0),
            )?;
            if !valid {
                return Err(ApiError::invalid(
                    "callback endpoint not registered for this source",
                ));
            }
        }
        let settings = self.settings()?;
        let local = chrono::Local::now();
        let minute = local.hour() * 60 + local.minute();
        let quiet = quiet_at(&settings, minute);
        let mut reason = if settings.muted_sources.iter().any(|s| s == source)
            || settings
                .muted_groups
                .contains(&format!("{source}/{}", input.group_key))
        {
            "muted"
        } else if quiet {
            "quiet_hours"
        } else {
            ""
        };
        let tx = self.conn.transaction()?;
        let merged: Option<(String, i64)> = if reason.is_empty()
            && !input.dedupe_key.is_empty()
            && settings.merge_window_ms > 0
        {
            tx.query_row("SELECT n.id,p.merge_count FROM notifications n JOIN presentations p ON n.id=p.notification_id WHERE n.source=? AND n.dedupe_key=? AND n.created_at>=? AND p.state IN ('queued','showing') ORDER BY n.created_at DESC LIMIT 1",params![source,input.dedupe_key,at-settings.merge_window_ms],|r|Ok((r.get(0)?,r.get(1)?))).optional()?
        } else {
            None
        };
        if reason.is_empty() && merged.is_none() {
            let global: i64 = tx.query_row(
                "SELECT COUNT(*) FROM events WHERE type='scheduled' AND created_at>?",
                [at - 60_000],
                |r| r.get(0),
            )?;
            let local: i64 = tx.query_row(
                "SELECT COUNT(*) FROM events WHERE type='scheduled' AND created_at>? AND source=?",
                params![at - 60_000, source],
                |r| r.get(0),
            )?;
            if global >= settings.global_per_minute as i64
                || local >= settings.source_per_minute as i64
            {
                reason = "rate_limited";
            }
            let queued: i64 = tx.query_row(
                "SELECT COUNT(*) FROM presentations WHERE state='queued'",
                [],
                |r| r.get(0),
            )?;
            if queued >= settings.queue_limit as i64 {
                reason = "queue_full";
            }
        }
        let id_ = id();
        tx.execute("INSERT INTO notifications(id,source,client_id,original,payload,title,body,level,group_key,dedupe_key,created_at,updated_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",params![id_,source,input.client_message_id,original,original,input.title,input.body,input.level,input.group_key,input.dedupe_key,at,at,at+input.ttl_ms])?;
        tx.execute("INSERT INTO presentations(notification_id,state,reason,scheduled_at,merge_count) VALUES(?,?,?,?,?)",params![id_,if reason.is_empty(){"queued"}else{"suppressed"},reason,at,merged.as_ref().map_or(1,|(_,n)|n+1)])?;
        event(&tx, &id_, "accepted", json!({}), at)?;
        if let Some((ref previous, _)) = merged {
            tx.execute("UPDATE presentations SET state='suppressed',reason='merged',closed_at=? WHERE notification_id=?",params![at,previous])?;
            event(
                &tx,
                previous,
                "suppressed",
                json!({"reason":"merged","into":id_}),
                at,
            )?;
            self.clocks.remove(previous);
        }
        if reason.is_empty() {
            event(
                &tx,
                &id_,
                if merged.is_some() {
                    "coalesced"
                } else {
                    "scheduled"
                },
                json!({}),
                at,
            )?;
        } else {
            event(&tx, &id_, "suppressed", json!({"reason":reason}), at)?;
        }
        tx.commit()?;
        self.changed();
        Ok(
            json!({"notification_id":id_,"accepted":true,"duplicate":false,"presentation":if reason.is_empty(){"queued"}else{"suppressed"},"reason":reason}),
        )
    }
    fn get(&self, id_: &str) -> Result<Value> {
        let mut n: Value = self
            .conn
            .query_row("SELECT payload FROM notifications WHERE id=?", [id_], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .ok_or_else(|| ApiError::new("not_found", "notification not found"))
            .and_then(parse)?;
        let meta:Value=self.conn.query_row("SELECT n.source,n.created_at,n.updated_at,n.revision,n.read_at,n.archived_at,p.state,p.reason,p.merge_count FROM notifications n JOIN presentations p ON n.id=p.notification_id WHERE n.id=?",[id_],|r|Ok(json!({"id":id_,"source":r.get::<_,String>(0)?,"created_at":r.get::<_,i64>(1)?,"updated_at":r.get::<_,i64>(2)?,"revision":r.get::<_,i64>(3)?,"read_at":r.get::<_,Option<i64>>(4)?,"archived_at":r.get::<_,Option<i64>>(5)?,"state":r.get::<_,String>(6)?,"reason":r.get::<_,String>(7)?,"merge_count":r.get::<_,i64>(8)?})))?;
        n.as_object_mut()
            .unwrap()
            .extend(meta.as_object().unwrap().clone());
        let mut stmt=self.conn.prepare("SELECT seq,event_id,type,data,created_at FROM events WHERE notification_id=? ORDER BY seq DESC LIMIT 100")?;
        let events = stmt
            .query_map([id_], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, i64>(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        n["events"]=json!(events.into_iter().map(|(seq,eid,kind,data,at)|json!({"seq":seq,"event_id":eid,"type":kind,"data":serde_json::from_str::<Value>(&data).unwrap_or(Value::Null),"created_at":at})).collect::<Vec<_>>());
        let mut stmt=self.conn.prepare("SELECT d.id,d.event_id,d.status,d.attempts,d.last_error FROM deliveries d JOIN events e ON e.event_id=d.event_id WHERE e.notification_id=? ORDER BY d.id DESC LIMIT 100")?;
        n["deliveries"]=json!(stmt.query_map([id_],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"event_id":r.get::<_,String>(1)?,"status":r.get::<_,String>(2)?,"attempts":r.get::<_,i64>(3)?,"last_error":r.get::<_,Option<String>>(4)?})))?.collect::<std::result::Result<Vec<_>,_>>()?);
        Ok(n)
    }
    fn list(&self, source: Option<&str>, data: &Value) -> Result<Value> {
        use rusqlite::types::Value as Sql;
        let mut where_ = vec!["1=1".to_string()];
        let mut args: Vec<Sql> = vec![];
        let scope = source.or_else(|| data["source"].as_str().filter(|s| !s.is_empty()));
        if let Some(src) = scope {
            where_.push("n.source=?".into());
            args.push(src.to_string().into());
        }
        for (key, column) in [
            ("group_key", "n.group_key"),
            ("level", "n.level"),
            ("state", "p.state"),
        ] {
            if let Some(v) = data[key]
                .as_str()
                .filter(|s| key == "group_key" || !s.is_empty())
            {
                where_.push(format!("{column}=?"));
                args.push(v.to_string().into());
            }
        }
        for (key, column) in [("unread", "n.read_at"), ("archived", "n.archived_at")] {
            if let Some(v) = data[key].as_bool() {
                where_.push(format!(
                    "{column} IS {}NULL",
                    if (key == "unread" && v) || (key == "archived" && !v) {
                        ""
                    } else {
                        "NOT "
                    }
                ));
            }
        }
        for (key, op) in [("since", ">="), ("until", "<=")] {
            if let Some(v) = data[key].as_i64() {
                where_.push(format!("n.created_at{op}?"));
                args.push(v.into());
            }
        }
        if let Some(tag) = data["tag"].as_str().filter(|s| !s.is_empty()) {
            where_.push("EXISTS(SELECT 1 FROM json_each(n.payload,'$.tags') WHERE value=?)".into());
            args.push(tag.to_string().into());
        }
        if data["callback_failed"].as_bool() == Some(true) {
            where_.push("EXISTS(SELECT 1 FROM deliveries d JOIN events e ON d.event_id=e.event_id WHERE e.notification_id=n.id AND d.status='failed')".into());
        }
        if let Some(q) = data["q"].as_str().filter(|s| !s.trim().is_empty()) {
            if q.len() > 500 {
                return Err(ApiError::invalid("search too long"));
            }
            where_.push(
                "n.rowid IN (SELECT rowid FROM notification_fts WHERE notification_fts MATCH ?)"
                    .into(),
            );
            args.push(format!("\"{}\"", q.replace('"', "\"\"")).into());
        }
        let base = where_.join(" AND ");
        let total:i64=self.conn.query_row(&format!("SELECT COUNT(*) FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE {base}"),rusqlite::params_from_iter(args.iter()),|r|r.get(0))?;
        let mut stmt=self.conn.prepare(&format!("SELECT n.source,n.group_key,COUNT(*),SUM(n.read_at IS NULL),(SELECT COUNT(*) FROM notifications a WHERE a.source=n.source AND a.group_key=n.group_key) FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE {base} GROUP BY n.source,n.group_key ORDER BY MAX(n.created_at) DESC LIMIT 200"))?;
        let groups=stmt.query_map(rusqlite::params_from_iter(args.iter()),|r|Ok(json!({"source":r.get::<_,String>(0)?,"group_key":r.get::<_,String>(1)?,"matched":r.get::<_,i64>(2)?,"unread":r.get::<_,i64>(3)?,"total":r.get::<_,i64>(4)?})))?.collect::<std::result::Result<Vec<_>,_>>()?;
        if let Some(cursor) = data["cursor"].as_object() {
            let at = cursor
                .get("created_at")
                .and_then(Value::as_i64)
                .ok_or_else(|| ApiError::invalid("invalid cursor"))?;
            let id_ = cursor
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| ApiError::invalid("invalid cursor"))?;
            where_.push("(n.created_at<? OR (n.created_at=? AND n.id<?))".into());
            args.extend([at.into(), at.into(), id_.to_string().into()]);
        }
        let limit = data["limit"].as_i64().unwrap_or(30).clamp(1, 100);
        args.push((limit + 1).into());
        let sql = format!(
            "SELECT n.id,n.payload,n.source,n.created_at,n.updated_at,n.revision,n.read_at,n.archived_at,p.state,p.reason,p.merge_count \
             FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE {} \
             ORDER BY n.created_at DESC,n.id DESC LIMIT ?",
            where_.join(" AND ")
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(args.iter()), |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    json!({
                        "source": r.get::<_, String>(2)?,
                        "created_at": r.get::<_, i64>(3)?,
                        "updated_at": r.get::<_, i64>(4)?,
                        "revision": r.get::<_, i64>(5)?,
                        "read_at": r.get::<_, Option<i64>>(6)?,
                        "archived_at": r.get::<_, Option<i64>>(7)?,
                        "state": r.get::<_, String>(8)?,
                        "reason": r.get::<_, String>(9)?,
                        "merge_count": r.get::<_, i64>(10)?,
                    }),
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let more = rows.len() > limit as usize;
        let mut items = Vec::with_capacity(rows.len().min(limit as usize));
        for (id_, payload, meta) in rows {
            let mut n: Value = parse(payload)?;
            n["id"] = json!(id_);
            n.as_object_mut()
                .unwrap()
                .extend(meta.as_object().unwrap().clone());
            items.push(n);
        }
        items.truncate(limit as usize);
        let cursor = if more {
            items
                .last()
                .map(|n| json!({"created_at":n["created_at"],"id":n["id"]}))
        } else {
            None
        };
        let seq:i64=self.conn.query_row("SELECT MAX((SELECT value FROM metadata WHERE key='event_floor'),COALESCE(MAX(seq),0)) FROM events",[],|r|r.get(0))?;
        Ok(
            json!({"items":items,"total":total,"groups":groups,"next_cursor":cursor,"watermark":seq}),
        )
    }
    fn update(&mut self, source: Option<&str>, data: Value) -> Result<Value> {
        let id_ = string(&data, "id")?;
        self.authorize(source, id_)?;
        let expected = data["expected_revision"]
            .as_i64()
            .ok_or_else(|| ApiError::invalid("expected_revision required"))?;
        let mut old: Value = parse(self.conn.query_row(
            "SELECT payload FROM notifications WHERE id=?",
            [id_],
            |r| r.get(0),
        )?)?;
        let patch = data["patch"]
            .as_object()
            .ok_or_else(|| ApiError::invalid("patch object required"))?;
        for (key, value) in patch {
            if !["title", "body", "level", "progress", "actions", "tags"].contains(&key.as_str()) {
                return Err(ApiError::invalid(
                    "only title/body/level/progress/actions/tags can be updated",
                ));
            }
            old[key] = value.clone();
        }
        let new: Create = serde_json::from_value(old)?;
        new.validate()?;
        let tx = self.conn.transaction()?;
        let at = now();
        let n=tx.execute("UPDATE notifications SET payload=?,title=?,body=?,level=?,revision=revision+1,updated_at=? WHERE id=? AND revision=?",params![serde_json::to_string(&new)?,new.title,new.body,new.level,at,id_,expected])?;
        if n == 0 {
            return Err(ApiError::new("conflict", "stale revision"));
        }
        event(&tx, id_, "updated", json!({}), at)?;
        tx.commit()?;
        self.changed();
        Ok(json!({"notification_id":id_,"revision":expected+1}))
    }
    fn finish(
        &mut self,
        id_: &str,
        revision: Option<i64>,
        kind: &str,
        data: Value,
        at: i64,
    ) -> Result<Value> {
        let tx = self.conn.transaction()?;
        let rev: i64 = tx
            .query_row(
                "SELECT revision FROM notifications WHERE id=?",
                [id_],
                |r| r.get(0),
            )
            .optional()?
            .ok_or_else(|| ApiError::new("not_found", "notification not found"))?;
        if revision.is_some_and(|r| r != rev) {
            return Err(ApiError::new("conflict", "stale notification revision"));
        }
        let state = if kind == "expired" {
            "expired"
        } else {
            "closed"
        };
        let n=tx.execute("UPDATE presentations SET state=?,reason=?,closed_at=? WHERE notification_id=? AND state IN ('queued','showing')",params![state,kind,at,id_])?;
        if n == 0 {
            return Err(ApiError::new("conflict", "presentation already finished"));
        }
        event(&tx, id_, kind, data, at)?;
        tx.commit()?;
        self.clocks.remove(id_);
        self.changed();
        Ok(json!({"notification_id":id_,"state":state}))
    }
    fn displayed(&mut self, data: &Value) -> Result<Value> {
        let id_ = string(data, "id")?;
        let rev = data["revision"]
            .as_i64()
            .ok_or_else(|| ApiError::invalid("revision required"))?;
        let tx = self.conn.transaction()?;
        let payload:Option<String>=tx.query_row("SELECT n.payload FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE n.id=? AND n.revision=? AND p.state='showing' AND p.displayed_at IS NULL",params![id_,rev],|r|r.get(0)).optional()?;
        if let Some(payload) = payload {
            let input: Create = serde_json::from_str(&payload)?;
            let at = now();
            tx.execute(
                "UPDATE presentations SET displayed_at=? WHERE notification_id=?",
                params![at, id_],
            )?;
            event(&tx, id_, "displayed", json!({}), at)?;
            tx.commit()?;
            self.changed();
            self.clocks.insert(
                id_.into(),
                (Instant::now(), input.display_duration_ms, false),
            );
        }
        Ok(json!({}))
    }
    fn events(&self, source: Option<&str>, after: i64) -> Result<Value> {
        let floor: i64 = self.conn.query_row(
            "SELECT value FROM metadata WHERE key='event_floor'",
            [],
            |r| r.get(0),
        )?;
        if after < floor {
            return Err(ApiError::new(
                "cursor_expired",
                "event cursor expired; load notification snapshot and resume from watermark",
            ));
        }
        let mut stmt=self.conn.prepare("SELECT seq,event_id,notification_id,revision,type,data,created_at FROM events WHERE seq>? AND (? IS NULL OR source=?) ORDER BY seq LIMIT 100")?;
        let rows = stmt
            .query_map(params![after, source, source], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, i64>(6)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let items=rows.into_iter().map(|(seq,eid,nid,rev,kind,data,at)|json!({"kind":"event","seq":seq,"event_id":eid,"notification_id":nid,"revision":rev,"type":kind,"data":serde_json::from_str::<Value>(&data).unwrap_or(Value::Null),"created_at":at})).collect::<Vec<_>>();
        let next = items
            .last()
            .and_then(|v| v["seq"].as_i64())
            .unwrap_or(after);
        Ok(json!({"events":items,"next_seq":next}))
    }
    pub fn recover(&mut self) -> Result<()> {
        let mut stmt = self.conn.prepare(
            "SELECT notification_id,state FROM presentations WHERE state IN ('queued','showing')",
        )?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        for (id_, state) in rows {
            self.finish(
                &id_,
                None,
                if state == "showing" {
                    "interrupted"
                } else {
                    "cancelled"
                },
                json!({"reason":"app_restarted"}),
                now(),
            )?;
        }
        self.conn.execute(
            "UPDATE deliveries SET status='pending' WHERE status='sending'",
            [],
        )?;
        self.changed();
        Ok(())
    }
    pub fn tick(&mut self) -> Result<()> {
        let at = now();
        let expired = {
            let mut s=self.conn.prepare("SELECT n.id FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE p.state='queued' AND n.expires_at<=?")?;
            let rows = s
                .query_map([at], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        for id_ in expired {
            self.finish(&id_, None, "expired", json!({}), at)?;
        }
        let elapsed = self
            .clocks
            .iter()
            .filter(|(_, (last, left, paused))| {
                !*paused && last.elapsed().as_millis() as i64 >= *left
            })
            .map(|(id_, _)| id_.clone())
            .collect::<Vec<_>>();
        for id_ in elapsed {
            self.finish(&id_, None, "timed_out", json!({}), at)?;
        }
        let no_renderer = {
            let mut s=self.conn.prepare("SELECT notification_id FROM presentations WHERE state='showing' AND displayed_at IS NULL AND scheduled_at<?")?;
            let rows = s
                .query_map([at - 10_000], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        for id_ in no_renderer {
            self.finish(
                &id_,
                None,
                "interrupted",
                json!({"reason":"renderer_unavailable"}),
                at,
            )?;
        }
        let settings = self.settings()?;
        let local = chrono::Local::now();
        let quiet = quiet_at(&settings, local.hour() * 60 + local.minute());
        let mut stmt=self.conn.prepare("SELECT n.id,n.source,n.group_key FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE p.state IN ('queued','showing')")?;
        let active = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        for (id_, source, group) in active {
            let reason = if settings.muted_sources.contains(&source)
                || settings.muted_groups.contains(&format!("{source}/{group}"))
            {
                Some("muted")
            } else if quiet {
                Some("quiet_hours")
            } else {
                None
            };
            if let Some(reason) = reason {
                let tx = self.conn.transaction()?;
                tx.execute("UPDATE presentations SET state='suppressed',reason=?,closed_at=? WHERE notification_id=?",params![reason,at,id_])?;
                event(&tx, &id_, "suppressed", json!({"reason":reason}), at)?;
                tx.commit()?;
                self.clocks.remove(&id_);
                self.changed();
            }
        }
        if !quiet {
            // Slots belong to groups, not individual messages. Bound each group so
            // a busy producer cannot create an unbounded native surface.
            let mut stmt = self.conn.prepare("SELECT n.id,n.source,n.group_key,n.level,p.state FROM notifications n JOIN presentations p ON p.notification_id=n.id WHERE p.state IN ('showing','queued') ORDER BY CASE WHEN p.state='showing' THEN 0 ELSE 1 END,CASE WHEN n.created_at<? THEN 0 WHEN n.level='error' THEN 1 WHEN n.level='warning' THEN 2 ELSE 3 END,n.created_at,n.id")?;
            let active = stmt
                .query_map([at - 30_000], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            drop(stmt);
            let mut groups = HashMap::new();
            let mut promoted = 0;
            for (id, source, group, level, state) in active {
                let key = (
                    source,
                    !group.is_empty(),
                    if group.is_empty() { level } else { group },
                );
                if state == "showing" {
                    *groups.entry(key).or_insert(0usize) += 1;
                } else if groups.get(&key).is_some_and(|count| *count < 5)
                    || (!groups.contains_key(&key) && groups.len() < 3)
                {
                    promoted += self.conn.execute("UPDATE presentations SET state='showing',scheduled_at=? WHERE notification_id=? AND state='queued'", params![at, id])?;
                    *groups.entry(key).or_insert(0) += 1;
                }
            }
            if promoted > 0 {
                self.changed();
            }
        }
        if at - self.last_cleanup > 3_600_000 {
            self.cleanup(at, settings.retention_days)?;
            self.last_cleanup = at;
        }
        Ok(())
    }
    fn cleanup(&mut self, at: i64, days: u32) -> Result<()> {
        let cutoff = at - days as i64 * 86_400_000;
        let tx = self.conn.transaction()?;
        // Preserve pending and failed delivery payloads independently of history retention.
        tx.execute("DELETE FROM deliveries WHERE status='delivered' AND event_id IN (SELECT event_id FROM events WHERE created_at<?)",[cutoff])?;
        let floor:i64=tx.query_row("SELECT MAX((SELECT value FROM metadata WHERE key='event_floor'),COALESCE(MAX(seq),0)) FROM events WHERE created_at<? AND seq<COALESCE((SELECT MIN(seq) FROM events WHERE created_at>=?),9223372036854775807)",params![cutoff,cutoff],|r|r.get(0))?;
        tx.execute(
            "UPDATE metadata SET value=MAX(value,?) WHERE key='event_floor'",
            [floor],
        )?;
        tx.execute("DELETE FROM events WHERE seq<=? AND NOT EXISTS(SELECT 1 FROM deliveries d WHERE d.event_id=events.event_id AND d.status!='delivered')",[floor])?;
        tx.execute("DELETE FROM notifications WHERE updated_at<? AND id IN (SELECT notification_id FROM presentations WHERE state NOT IN ('showing','queued')) AND NOT EXISTS(SELECT 1 FROM deliveries d WHERE json_extract(d.body,'$.notification_id')=notifications.id AND d.status!='delivered')",[cutoff])?;
        tx.commit()?;
        Ok(())
    }
    fn snapshot(&self) -> Result<Value> {
        let mut stmt=self.conn.prepare("SELECT notification_id FROM presentations WHERE state='showing' ORDER BY scheduled_at,notification_id")?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut items = vec![];
        for id_ in ids {
            items.push(self.get(&id_)?);
        }
        let settings = self.settings()?;
        let decorated = self.decorated_settings()?;
        let local = chrono::Local::now();
        let ack: i64 = self.conn.query_row(
            "SELECT value FROM metadata WHERE key='summary_ack'",
            [],
            |r| r.get(0),
        )?;
        let dismissed_at: i64 = self.conn.query_row(
            "SELECT value FROM metadata WHERE key='summary_shown_at'",
            [],
            |r| r.get(0),
        )?;
        let summary: Option<Value> = if items.is_empty()
            && !quiet_at(&settings, local.hour() * 60 + local.minute())
            && now() - dismissed_at >= 60_000
        {
            let (count,seq):(i64,i64)=self.conn.query_row("SELECT COUNT(*),COALESCE(MAX(seq),0) FROM events WHERE seq>? AND created_at<=? AND ((type='suppressed' AND json_extract(data,'$.reason') IN ('quiet_hours','rate_limited','queue_full')) OR (type IN ('interrupted','cancelled') AND json_extract(data,'$.reason')='app_restarted'))",params![ack,now()-2000],|r|Ok((r.get(0)?,r.get(1)?)))?;
            if count > 0 {
                Some(json!({"count":count,"through_seq":seq}))
            } else {
                None
            }
        } else {
            None
        };
        Ok(json!({"items":items,"settings":decorated,"summary":summary}))
    }
    pub fn claim_delivery(&mut self) -> Result<Value> {
        let tx = self.conn.transaction()?;
        let row:Option<Value>=tx.query_row("SELECT d.id,d.body,e.url FROM deliveries d JOIN endpoints e ON e.id=d.endpoint_id WHERE d.status='pending' AND d.next_attempt_at<=? AND NOT EXISTS(SELECT 1 FROM deliveries busy WHERE busy.endpoint_id=d.endpoint_id AND busy.status='sending') ORDER BY d.next_attempt_at,d.id LIMIT 1",[now()],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"body":r.get::<_,String>(1)?,"url":r.get::<_,String>(2)?}))).optional()?;
        if let Some(row) = row {
            tx.execute(
                "UPDATE deliveries SET status='sending',attempts=attempts+1 WHERE id=?",
                [row["id"].as_i64()],
            )?;
            tx.commit()?;
            Ok(row)
        } else {
            Ok(Value::Null)
        }
    }
    pub fn delivery_result(&mut self, data: Value) -> Result<Value> {
        let id_ = data["id"]
            .as_i64()
            .ok_or_else(|| ApiError::invalid("id required"))?;
        let attempts: i64 =
            self.conn
                .query_row("SELECT attempts FROM deliveries WHERE id=?", [id_], |r| {
                    r.get(0)
                })?;
        let success = data["success"].as_bool() == Some(true);
        let status = if success {
            "delivered"
        } else if attempts >= 8 {
            "failed"
        } else {
            "pending"
        };
        let delay = (1_i64 << attempts.min(12)) * 1000 + (now() % 997);
        self.conn.execute(
            "UPDATE deliveries SET status=?,last_error=?,next_attempt_at=? WHERE id=?",
            params![status, data["error"].as_str(), now() + delay, id_],
        )?;
        if success || status == "failed" {
            self.changed();
        }
        Ok(json!({}))
    }
}
pub fn quiet_at(settings: &Settings, minute: u32) -> bool {
    match (settings.quiet_start, settings.quiet_end) {
        (Some(start), Some(end)) if start < end => minute >= start && minute < end,
        (Some(start), Some(end)) if start > end => minute >= start || minute < end,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Store {
        Store::open(Path::new(":memory:"), None).unwrap()
    }
    fn styled_db() -> (Store, PathBuf) {
        let dir = std::env::temp_dir().join(format!("mdn-store-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(Path::new(":memory:"), Some(&dir)).unwrap();
        (store, dir)
    }
    fn input(key: &str) -> Create {
        Create {
            client_message_id: key.into(),
            title: "构建失败".into(),
            ..Create::default()
        }
    }
    #[test]
    fn toast_groups_share_slots_and_keep_individual_lifecycles() {
        let mut s = db();
        let mut ids = vec![];
        for i in 0..6 {
            ids.push(
                s.create("build", input(&format!("msg-{i}")), now())
                    .unwrap()["notification_id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
        }
        let mut warning = input("warning");
        warning.level = "warning".into();
        s.create("build", warning, now()).unwrap();
        s.create("other", input("other"), now()).unwrap();
        s.create("fourth", input("fourth"), now()).unwrap();
        // Bypass rate policy for this scheduler-only fixture.
        s.conn
            .execute("UPDATE presentations SET state='queued',reason=''", [])
            .unwrap();
        s.tick().unwrap();
        let snapshot = s.snapshot().unwrap();
        let items = snapshot["items"].as_array().unwrap();
        assert_eq!(items.len(), 7);
        assert_eq!(
            items
                .iter()
                .filter(|n| n["source"] == "build" && n["level"] == "info")
                .count(),
            5
        );
        let shown = items
            .iter()
            .find(|n| n["source"] == "build" && n["level"] == "info")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        s.finish(&shown, None, "dismissed", json!({}), now())
            .unwrap();
        s.tick().unwrap();
        assert_eq!(s.snapshot().unwrap()["items"].as_array().unwrap().len(), 7);
        assert_eq!(
            s.conn
                .query_row("SELECT COUNT(*) FROM notifications", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            9
        );
    }

    #[test]
    fn integer_bools_in_settings_self_heal_instead_of_failing_every_tick() {
        let mut s = db();
        // A payload touched by a one-off experiment: 0/1 where booleans belong.
        s.conn
            .execute(
                "UPDATE settings SET payload=? WHERE id=1",
                [r#"{"theme":"system","tray_badge_enabled":1,"reduced_motion":0,"toast":{"shadow":1,"border_width":1}}"#],
            )
            .unwrap();
        let healed = s.settings().unwrap();
        assert!(healed.tray_badge_enabled);
        assert!(!healed.reduced_motion);
        assert!(healed.toast.shadow);
        assert_eq!(healed.toast.border_width, 1, "genuine numbers stay numbers");
        // The row itself is rewritten with real booleans, so the heal happens once.
        let stored: Value = serde_json::from_str(
            &s.conn
                .query_row("SELECT payload FROM settings WHERE id=1", [], |r| {
                    r.get::<_, String>(0)
                })
                .unwrap(),
        )
        .unwrap();
        assert_eq!(stored["tray_badge_enabled"], json!(true));
        assert_eq!(stored["reduced_motion"], json!(false));
        assert_eq!(stored["toast"]["shadow"], json!(true));
        assert_eq!(stored["toast"]["border_width"], json!(1));
        // And the healed payload round-trips through a strict settings.set.
        let mut edited = serde_json::to_value(s.settings().unwrap()).unwrap();
        edited["tray_badge_enabled"] = json!(false);
        assert!(s.command(None, "settings.set", edited).is_ok());
    }
    #[test]
    fn explicit_group_overrides_level_but_never_source() {
        let mut s = db();
        for (i, source, group, level) in [
            (0, "a", "job", "info"),
            (1, "a", "job", "error"),
            (2, "b", "job", "info"),
            (3, "a", "", "job"),
        ] {
            let mut n = input(&i.to_string());
            n.group_key = group.into();
            // Last message uses a valid level matching a different explicit group below.
            n.level = if level == "job" { "info" } else { level }.into();
            s.create(source, n, now()).unwrap();
        }
        s.tick().unwrap();
        assert_eq!(s.snapshot().unwrap()["items"].as_array().unwrap().len(), 4);
    }

    #[test]
    fn appearance_survives_legacy_settings_and_rejected_save() {
        let mut s = db();
        // A settings row from before toast appearance existed remains usable.
        s.conn
            .execute(
                "UPDATE settings SET payload=? WHERE id=1",
                [r##"{"theme":"dark","width":420,"muted_sources":["build"]}"##],
            )
            .unwrap();
        let legacy = s.settings().unwrap();
        assert_eq!(legacy.width, 420);
        assert_eq!(legacy.toast.header, "full");
        // Rows saved before the frosted-glass removal carry obsolete keys.
        s.conn
            .execute(
                "UPDATE settings SET payload=? WHERE id=1",
                [r#"{"theme":"dark","toast":{"material":"popover","tint_opacity":20,"shadow":true}}"#],
            )
            .unwrap();
        let migrated = s.settings().unwrap();
        assert_eq!(migrated.toast.background, "theme");
        assert!(migrated.toast.shadow);
        let stored: Value = serde_json::from_str(
            &s.conn
                .query_row("SELECT payload FROM settings WHERE id=1", [], |r| {
                    r.get::<_, String>(0)
                })
                .unwrap(),
        )
        .unwrap();
        assert!(stored["toast"]["material"].is_null());
        assert!(stored["toast"]["tint_opacity"].is_null());
        let mut updated = serde_json::to_value(legacy).unwrap();
        updated["toast"]["header_label"] = json!("我的构建");
        updated["toast"]["border_color"] = json!("#12ABef");
        updated["toast"]["background"] = json!("#244832");
        updated["toast"]["shadow"] = json!(true);
        s.command(None, "settings.set", updated.clone()).unwrap();
        assert_eq!(s.command(None, "settings.get", json!({})).unwrap(), updated);
        for (key, value) in [
            // Removed appearance keys are unknown fields now and must be rejected.
            ("material", json!("popover")),
            ("border_color", json!("url(file://bad)")),
            ("body_lines", json!(0)),
            ("line_height", json!(5)),
        ] {
            let mut bad = updated.clone();
            bad["toast"][key] = value;
            assert!(s.command(None, "settings.set", bad).is_err());
            assert_eq!(s.command(None, "settings.get", json!({})).unwrap(), updated);
        }
        assert_eq!(s.settings().unwrap().muted_sources, vec!["build"]);
    }
    #[test]
    fn partial_toast_style_uses_defaults() {
        let s: Settings = serde_json::from_value(json!({"toast":{"header":"hidden"}})).unwrap();
        s.validate().unwrap();
        assert_eq!(s.toast.header, "hidden");
        assert!(s.toast.show_body);
        assert_eq!(s.toast.border_width, 1);
        assert!(serde_json::from_value::<Settings>(json!({"toast":{"typo":true}})).is_err());
    }
    #[test]
    fn idempotency_conflict_and_source_isolation() {
        let mut s = db();
        let a = s.create("a", input("1"), now()).unwrap();
        assert_eq!(
            s.create("a", input("1"), now()).unwrap()["notification_id"],
            a["notification_id"]
        );
        let mut n = input("1");
        n.body = "changed".into();
        assert_eq!(s.create("a", n, now()).unwrap_err().code, "conflict");
        assert!(s.create("b", input("1"), now()).is_ok());
        assert!(s
            .command(
                Some("b"),
                "notification.get",
                json!({"id":a["notification_id"]})
            )
            .is_err());
    }
    #[test]
    fn transaction_ends_presentation_once() {
        let mut s = db();
        let a = s.create("a", input("1"), now()).unwrap();
        let id_ = a["notification_id"].as_str().unwrap();
        s.finish(id_, Some(1), "dismissed", json!({}), now())
            .unwrap();
        assert_eq!(
            s.finish(id_, None, "timed_out", json!({}), now())
                .unwrap_err()
                .code,
            "conflict"
        );
        let ev = s.events(Some("a"), 0).unwrap();
        assert_eq!(
            ev["events"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|e| e["type"] == "dismissed")
                .count(),
            1
        );
    }
    #[test]
    fn merged_notifications_keep_history() {
        let mut s = db();
        let mut a = input("1");
        a.dedupe_key = "same".into();
        s.create("a", a.clone(), now()).unwrap();
        a.client_message_id = "2".into();
        let second = s.create("a", a, now()).unwrap();
        assert_eq!(s.list(Some("a"), &json!({})).unwrap()["total"], 2);
        assert_eq!(
            s.get(second["notification_id"].as_str().unwrap()).unwrap()["merge_count"],
            2
        );
    }
    #[test]
    fn rate_limits_preserve_accepted_messages() {
        let mut s = db();
        for i in 0..1000 {
            s.create("a", input(&i.to_string()), now()).unwrap();
        }
        let all = s.list(Some("a"), &json!({})).unwrap();
        assert_eq!(all["total"], 1000);
        let suppressed = s.list(Some("a"), &json!({"state":"suppressed"})).unwrap();
        assert_eq!(suppressed["total"], 994);
    }
    #[test]
    fn revision_rejects_stale_action() {
        let mut s = db();
        let a = s.create("a", input("1"), now()).unwrap();
        let id_ = a["notification_id"].as_str().unwrap();
        s.update(
            Some("a"),
            json!({"id":id_,"expected_revision":1,"patch":{"body":"new"}}),
        )
        .unwrap();
        assert_eq!(
            s.finish(id_, Some(1), "dismissed", json!({}), now())
                .unwrap_err()
                .code,
            "conflict"
        );
    }
    #[test]
    fn pagination_and_filters() {
        let mut s = db();
        for i in 0..15 {
            s.create("a", input(&i.to_string()), 1000).unwrap();
        }
        let a = s.list(None, &json!({"limit":10,"q":"构建失败"})).unwrap();
        let b = s
            .list(None, &json!({"limit":10,"cursor":a["next_cursor"]}))
            .unwrap();
        assert_eq!(a["items"].as_array().unwrap().len(), 10);
        assert_eq!(b["items"].as_array().unwrap().len(), 5);
        for n in a["items"].as_array().unwrap() {
            assert!(!b["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m["id"] == n["id"]));
        }
    }
    #[test]
    fn quiet_hours_cross_midnight() {
        let s = Settings {
            quiet_start: Some(22 * 60),
            quiet_end: Some(8 * 60),
            ..Settings::default()
        };
        assert!(quiet_at(&s, 23 * 60));
        assert!(quiet_at(&s, 60));
        assert!(!quiet_at(&s, 12 * 60));
    }
    #[test]
    fn recovery_does_not_replay_toasts() {
        let mut s = db();
        s.create("a", input("1"), now()).unwrap();
        s.tick().unwrap();
        s.recover().unwrap();
        assert_eq!(s.snapshot().unwrap()["items"], json!([]));
        assert_eq!(
            s.list(None, &json!({})).unwrap()["items"][0]["reason"],
            "interrupted"
        );
    }
    #[test]
    fn tray_counts_unread_and_action_marks_read() {
        let mut s = db();
        let a = s.create("a", input("1"), now()).unwrap();
        let id_ = a["notification_id"].as_str().unwrap();
        // Bypass scheduling so the message counts as displayed.
        s.conn
            .execute("UPDATE presentations SET state='showing'", [])
            .unwrap();
        assert_eq!(s.tray_state().unwrap()["count"], json!(1));
        s.command(None, "notification.mark_read", json!({"ids":[id_]}))
            .unwrap();
        assert_eq!(s.tray_state().unwrap()["count"], json!(0));
        assert_eq!(s.tray_state().unwrap()["enabled"], json!(true));

        // Acting on a toast button closes the presentation AND marks it read.
        let b = s
            .create(
                "a",
                Create {
                    title: "with actions".into(),
                    actions: vec![Action {
                        id: "confirm".into(),
                        label: "确认收到".into(),
                    }],
                    ..input("2")
                },
                now(),
            )
            .unwrap();
        let id2 = b["notification_id"].as_str().unwrap();
        s.conn
            .execute(
                "UPDATE presentations SET state='showing' WHERE notification_id=?",
                [id2],
            )
            .unwrap();
        assert_eq!(s.tray_state().unwrap()["count"], json!(1));
        s.command(
            None,
            "toast.interact",
            json!({"id":id2,"revision":1,"kind":"action_invoked","action_id":"confirm"}),
        )
        .unwrap();
        let detail = s.get(id2).unwrap();
        assert_eq!(detail["state"], json!("closed"));
        assert!(detail["read_at"].is_i64(), "action click marks read");
        assert_eq!(s.tray_state().unwrap()["count"], json!(0));
    }
    #[test]
    fn snapshot_carries_style_theme() {
        let (mut s, _dir) = styled_db();
        s.create("a", input("1"), now()).unwrap();
        s.tick().unwrap();
        let snapshot = s.snapshot().unwrap();
        assert_eq!(
            snapshot["settings"]["style"]["theme"]["id"],
            json!("default")
        );
        assert!(snapshot["settings"]["style"]["theme"]["pillHeight"].is_u64());
    }
    #[test]
    fn theme_pack_derives_and_writes_through() {
        let (mut s, dir) = styled_db();
        // settings.get derives appearance from the active theme.
        let current = s.command(None, "settings.get", json!({})).unwrap();
        assert_eq!(current["style"]["theme"]["id"], json!("default"));
        assert_eq!(current["style"]["theme"]["source"], json!("builtin"));
        assert_eq!(current["toast"]["title_size"], json!(15));
        // Appearance edits land in the theme file (write-through) and persist.
        let mut edited = current.clone();
        edited["toast"]["title_size"] = json!(22);
        edited.as_object_mut().unwrap().remove("style");
        let saved = s.command(None, "settings.set", edited).unwrap();
        assert_eq!(saved["toast"]["title_size"], json!(22));
        let file = dir.join("themes").join("default.json");
        let pack: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(pack["titleSize"], json!(22));
        assert_eq!(
            s.command(None, "settings.get", json!({})).unwrap()["toast"]["title_size"],
            json!(22)
        );
        // A theme switch ignores stale form values: midnight answers wholesale.
        let mut switch = s.command(None, "settings.get", json!({})).unwrap();
        switch["theme_id"] = json!("midnight");
        switch.as_object_mut().unwrap().remove("style");
        let switched = s.command(None, "settings.set", switch).unwrap();
        assert_eq!(switched["style"]["theme"]["id"], json!("midnight"));
        assert_eq!(switched["toast"]["title_size"], json!(15));
        assert_eq!(switched["radius"], json!(18));
        assert!(!file_for(&dir, "midnight").exists());
        // themes.list merges builtins and user copies.
        let listed = s.command(None, "themes.list", json!({})).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 4);
    }
    fn file_for(dir: &Path, id: &str) -> PathBuf {
        dir.join("themes").join(format!("{id}.json"))
    }
    #[test]
    fn callback_outbox_atomic_and_stable() {
        let mut s = db();
        s.command(
            None,
            "endpoints.create",
            json!({"id":"cb","source":"desktop","url":"http://127.0.0.1:9999/cb"}),
        )
        .unwrap();
        let mut n = input("1");
        n.callback_endpoint_id = Some("cb".into());
        s.create("desktop", n, now()).unwrap();
        let d = s.claim_delivery().unwrap();
        let body = d["body"].clone();
        s.delivery_result(json!({"id":d["id"],"success":false,"error":"timeout"}))
            .unwrap();
        s.conn
            .execute("UPDATE deliveries SET next_attempt_at=0", [])
            .unwrap();
        assert_eq!(s.claim_delivery().unwrap()["body"], body);
    }
}
