fn main() {
    println!("cargo:rerun-if-changed=native/ScriptHost.swift");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let output =
        std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("nc-script-host");
    let status = std::process::Command::new("xcrun")
        .args(["swiftc", "-O", "native/ScriptHost.swift", "-o"])
        .arg(&output)
        .status()
        .expect("Swift compiler is required for the JavaScriptCore host");
    assert!(status.success(), "failed to compile JavaScriptCore host");
    println!("cargo:rustc-env=NC_SCRIPT_HOST={}", output.display());
}
