#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cargo build --release --locked
bundle="target/NcReplica.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp target/release/nc-replica "$bundle/Contents/MacOS/nc-replica"
host=$(target/release/nc-replica --script-host-path)
cp "$host" "$bundle/Contents/Resources/nc-script-host"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.nc-replica</string>
<key>CFBundleName</key><string>NcReplica</string>
<key>CFBundleExecutable</key><string>nc-replica</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>Notification ingress</string>
<key>CFBundleURLSchemes</key><array><string>notch-notify</string></array>
</dict></array>
</dict></plist>
PLIST
printf '%s\n' "Built $bundle"
