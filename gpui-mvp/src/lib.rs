// The spike compiles the production backend unchanged. Extract a shared core
// crate only after the GPUI feasibility gate; do not fork business rules.
#[path = "../../src-tauri/src/model.rs"]
pub mod model;
#[path = "../../src-tauri/src/service.rs"]
pub mod service;
#[path = "../../src-tauri/src/store.rs"]
pub mod store;
#[path = "../../src-tauri/src/theme.rs"]
pub mod theme;

pub mod desktop;
pub mod inbox;
mod platform;
#[path = "../../src-tauri/src/transport/mod.rs"]
pub mod transport;
pub mod tray;
