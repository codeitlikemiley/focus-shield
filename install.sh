#!/bin/bash
set -e

# ──────────────────────────────────────────────────────────────────────
# Focus Shield — Install Script
# Builds a proper .app bundle and installs to /Applications
# ──────────────────────────────────────────────────────────────────────

APP_NAME="Focus Shield"
BUNDLE_ID="com.focusshield.app"
BUILD_DIR=".build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "${BLUE}▸${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Focus Shield — Installer           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Build the binary ─────────────────────────────────────────
print_step "Building Focus Shield..."
swift build -c release 2>&1 | tail -3
BINARY_PATH=$(swift build -c release --show-bin-path)/FocusShield
if [ ! -f "$BINARY_PATH" ]; then
    print_error "Build failed — binary not found at $BINARY_PATH"
    exit 1
fi
print_success "Binary built at $BINARY_PATH"

# ── Step 2: Create .app bundle structure ─────────────────────────────
print_step "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/FocusShield"

# ── Step 3: Create Info.plist ────────────────────────────────────────
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FocusShield</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# ── Step 4: Create app icon (using SF Symbol via swift script) ───────
print_step "Generating app icon..."

# Create a simple icon using sips from a tiff
# First, create an iconset
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Generate icon using a Swift script that renders the shield symbol
cat > /tmp/generate_icon.swift << 'ICONSCRIPT'
import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let outputDir = CommandLine.arguments[1]

for (size, name) in sizes {
    let imgSize = NSSize(width: size, height: size)
    let image = NSImage(size: imgSize, flipped: false) { rect in
        // Background: gradient circle
        let gradient = NSGradient(colors: [
            NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0),
            NSColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1.0),
        ])!
        let circlePath = NSBezierPath(ovalIn: rect.insetBy(dx: CGFloat(size) * 0.05, dy: CGFloat(size) * 0.05))
        gradient.draw(in: circlePath, angle: -45)

        // Shield symbol
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.5, weight: .bold)
        if let shield = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolSize = shield.size
            let x = (rect.width - symbolSize.width) / 2
            let y = (rect.height - symbolSize.height) / 2
            NSColor.white.setFill()
            shield.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return true
    }

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else { continue }

    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try? pngData.write(to: url)
}
ICONSCRIPT

swift /tmp/generate_icon.swift "$ICONSET_DIR" 2>/dev/null || true

# Convert iconset to icns
if [ -f "$ICONSET_DIR/icon_512x512@2x.png" ]; then
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null
    # Update Info.plist to reference the icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    print_success "App icon generated"
else
    print_warn "Could not generate icon (will use default)"
fi

# ── Step 5: Create entitlements ──────────────────────────────────────
cat > "$BUILD_DIR/entitlements.plist" << ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# ── Step 6: Sign the app ────────────────────────────────────────────
print_step "Code signing..."
codesign --force --deep --sign - \
    --entitlements "$BUILD_DIR/entitlements.plist" \
    "$APP_BUNDLE" 2>/dev/null
print_success "App signed (ad-hoc)"

# ── Step 7: Install to /Applications ─────────────────────────────────
print_step "Installing to /Applications..."

if [ -d "$INSTALL_PATH" ]; then
    print_warn "Existing installation found — replacing..."
    rm -rf "$INSTALL_PATH"
fi

cp -R "$APP_BUNDLE" "$INSTALL_PATH"
print_success "Installed to $INSTALL_PATH"

# ── Handle --uninstall flag (check early) ────────────────────────────
if [ "$1" = "--uninstall" ]; then
    echo ""
    print_step "Uninstalling Focus Shield..."
    rm -rf "$INSTALL_PATH"
    # Disable proxy on all services
    SERVICES=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
    while IFS= read -r SERVICE; do
        networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
    done <<< "$SERVICES"
    # Stop DNS proxy and restore DNS
    sudo pkill -f focusshield-dns 2>/dev/null || true
    # Restore original DNS if saved
    ORIG_DNS_FILE="$HOME/Library/Application Support/FocusShield/original-dns.txt"
    if [ -f "$ORIG_DNS_FILE" ]; then
        ORIG_DNS=$(cat "$ORIG_DNS_FILE")
        if [ "$ORIG_DNS" = "empty" ]; then
            sudo networksetup -setdnsservers Wi-Fi Empty 2>/dev/null || true
        else
            sudo networksetup -setdnsservers Wi-Fi "$ORIG_DNS" 2>/dev/null || true
        fi
    fi
    osascript -e "do shell script \"rm -f /usr/local/bin/focusshield-helper; rm -f /usr/local/bin/focusshield-dns; rm -f /etc/sudoers.d/focusshield; rm -f /etc/pf.anchors/com.focusshield; rm -f /tmp/focusshield-dns.pid; if grep -q 'FocusShield' /etc/hosts 2>/dev/null; then sed -i '' '/# FocusShield START/,/# FocusShield END/d' /etc/hosts; dscacheutil -flushcache; fi\" with administrator privileges" 2>/dev/null || true
    rm -rf ~/Library/Application\ Support/FocusShield
    print_success "Focus Shield uninstalled (DNS restored)"
    exit 0
fi

# ── Step 8: Install the privileged helper + DNS proxy ──
print_step "Installing privileged helper v3 + DNS proxy..."

HELPER_PATH="/usr/local/bin/focusshield-helper"
DNS_PROXY_PATH="/usr/local/bin/focusshield-dns"
SUDOERS_PATH="/etc/sudoers.d/focusshield"
CURRENT_USER=$(whoami)

# Build DNS proxy binary
print_step "Building DNS proxy..."
swift build -c release --product FocusShieldDNS 2>&1 | tail -2
DNS_BINARY=".build/arm64-apple-macosx/release/FocusShieldDNS"
if [ ! -f "$DNS_BINARY" ]; then
    DNS_BINARY=".build/release/FocusShieldDNS"
fi
if [ ! -f "$DNS_BINARY" ]; then
    print_warn "DNS proxy binary not found — skipping"
else
    print_success "DNS proxy built"
fi

# Create helper script v3 — handles hosts, pf, AND proxy settings (via HTTP URL)
HELPER_TMP=$(mktemp)
cat > "$HELPER_TMP" << 'HELPEREOF'
#!/bin/bash
# FocusShield privileged helper v3
# Usage: focusshield-helper <hosts_tmp> <pf_tmp> <pac_url|disable> <enable|disable>
set -e
HOSTS_TMP="$1"
PF_TMP="$2"
PAC_URL="$3"
PROXY_MODE="$4"

# --- Hosts file ---
if [ -f "$HOSTS_TMP" ]; then
    cp "$HOSTS_TMP" /etc/hosts
    chmod 644 /etc/hosts
fi

# --- PF firewall ---
if [ -f "$PF_TMP" ]; then
    mkdir -p /etc/pf.anchors
    cp "$PF_TMP" /etc/pf.anchors/com.focusshield
    chmod 644 /etc/pf.anchors/com.focusshield
fi
if ! grep -q 'com.focusshield' /etc/pf.conf 2>/dev/null; then
    echo 'anchor "com.focusshield"' >> /etc/pf.conf
    echo 'load anchor "com.focusshield" from "/etc/pf.anchors/com.focusshield"' >> /etc/pf.conf
fi
pfctl -a com.focusshield -f /etc/pf.anchors/com.focusshield 2>/dev/null || true
pfctl -e 2>/dev/null || true

# --- DNS cache flush ---
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

# --- PAC Proxy (for Safari/DoH browsers) ---
SERVICES=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

if [ "$PROXY_MODE" = "enable" ] && [ "$PAC_URL" != "disable" ]; then
    while IFS= read -r SERVICE; do
        networksetup -setautoproxyurl "$SERVICE" "$PAC_URL" 2>/dev/null || true
        networksetup -setautoproxystate "$SERVICE" on 2>/dev/null || true
    done <<< "$SERVICES"
else
    while IFS= read -r SERVICE; do
        networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
    done <<< "$SERVICES"
fi
HELPEREOF

SUDOERS_TMP=$(mktemp)
cat > "$SUDOERS_TMP" << SUDEOF
$CURRENT_USER ALL=(root) NOPASSWD: $HELPER_PATH
$CURRENT_USER ALL=(root) NOPASSWD: $DNS_PROXY_PATH *
$CURRENT_USER ALL=(root) NOPASSWD: /bin/kill *
$CURRENT_USER ALL=(root) NOPASSWD: /usr/bin/pkill -f focusshield-dns
$CURRENT_USER ALL=(root) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
$CURRENT_USER ALL=(root) NOPASSWD: /usr/sbin/networksetup -setdnsservers *
SUDEOF

# Always reinstall helper to ensure v3 + DNS proxy is in place
echo ""
print_warn "Admin password required (one-time only — enables password-free toggling):"

# Build install command
INSTALL_CMD="mkdir -p /usr/local/bin && cp '$HELPER_TMP' '$HELPER_PATH' && chmod 755 '$HELPER_PATH' && chown root:wheel '$HELPER_PATH'"

# Add DNS proxy if built
if [ -f "$DNS_BINARY" ]; then
    INSTALL_CMD="$INSTALL_CMD && cp '$DNS_BINARY' '$DNS_PROXY_PATH' && chmod 755 '$DNS_PROXY_PATH' && chown root:wheel '$DNS_PROXY_PATH'"
fi

INSTALL_CMD="$INSTALL_CMD && cp '$SUDOERS_TMP' '$SUDOERS_PATH' && chmod 440 '$SUDOERS_PATH' && chown root:wheel '$SUDOERS_PATH' && visudo -c -f '$SUDOERS_PATH' || rm -f '$SUDOERS_PATH'"

osascript -e "do shell script \"$INSTALL_CMD\" with administrator privileges" 2>/dev/null
if [ $? -eq 0 ]; then
    print_success "Helper v3 + DNS proxy installed — no more password prompts!"
else
    print_warn "Helper install skipped — you can run the install script again later"
fi

rm -f "$HELPER_TMP" "$SUDOERS_TMP"

# ── Step 9: Register with Launch Services ────────────────────────────
print_step "Registering with system..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH" 2>/dev/null || true
print_success "Registered with Launch Services"

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Installation Complete! 🛡️           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Open from Spotlight:${NC}  ⌘Space → \"Focus Shield\""
echo -e "  ${BLUE}Open from terminal:${NC}   open -a 'Focus Shield'"
echo -e "  ${BLUE}Uninstall:${NC}            ./install.sh --uninstall"
echo ""
echo -e "  ${YELLOW}After opening, go to:${NC}"
echo -e "  System Settings → Privacy & Security → Accessibility"
echo -e "  and enable ${GREEN}Focus Shield${NC} for global hotkey support."
echo ""

