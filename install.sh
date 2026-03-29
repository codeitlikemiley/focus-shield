#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────────────────────────────
# Focus Shield — Install Script
# Builds a proper .app bundle and installs to /Applications
# ──────────────────────────────────────────────────────────────────────

APP_NAME="Focus Shield"
BUNDLE_ID="com.focusshield.macos"
BUILD_DIR=".build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
APP_SOURCE_BUNDLE="${APP_SOURCE_BUNDLE:-}"

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

# ── Handle --uninstall flag (check early) ────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
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
    osascript -e "do shell script \"rm -f /usr/local/bin/focusshield-helper; rm -f /usr/local/bin/focusshield-dns; rm -f /etc/sudoers.d/focusshield; rm -f /etc/pf.anchors/com.focusshield; rm -f /tmp/focusshield-dns.pid; rm -rf /usr/local/lib/focusshield; if grep -q 'FocusShield' /etc/hosts 2>/dev/null; then sed -i '' '/# FocusShield START/,/# FocusShield END/d' /etc/hosts; dscacheutil -flushcache; fi\" with administrator privileges" 2>/dev/null || true
    rm -rf ~/Library/Application\ Support/FocusShield
    print_success "Focus Shield uninstalled (DNS restored)"
    exit 0
fi

# ── Step 1: Build the binary ─────────────────────────────────────────
if [ -n "$APP_SOURCE_BUNDLE" ]; then
    print_step "Using prebuilt app bundle..."
    if [ ! -d "$APP_SOURCE_BUNDLE" ]; then
        print_error "Prebuilt app bundle not found at $APP_SOURCE_BUNDLE"
        exit 1
    fi
    APP_BUNDLE="$APP_SOURCE_BUNDLE"
    if [ -f "$APP_BUNDLE/Contents/Info.plist" ]; then
        BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "$BUNDLE_ID")
    fi
    print_success "Using app bundle at $APP_BUNDLE"
else
    if [ "${ALLOW_SPM_INSTALL:-0}" != "1" ]; then
        print_error "Direct SwiftPM install is disabled because it omits the embedded system extension."
        print_warn "Use ./build.sh install-macos-signed [TEAM_ID] for installs that can activate the Network Extension."
        print_warn "Set ALLOW_SPM_INSTALL=1 only for local development without system extension coverage."
        exit 1
    fi

    print_warn "Installing a SwiftPM-built app without the system extension (development only)."
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
fi

# ── Step 7: Install to /Applications ─────────────────────────────────
# System extensions require the app to be owned by root:wheel in /Applications.
# Without root ownership, sysextd rejects the activation request.
print_step "Installing to /Applications (requires admin)..."

# Build the shell commands to run as admin
INSTALL_CMDS="rm -rf '/Applications/$APP_NAME.app' && ditto '${APP_BUNDLE}' '/Applications/$APP_NAME.app' && chown -R root:wheel '/Applications/$APP_NAME.app' && xattr -cr '/Applications/$APP_NAME.app'"

if osascript -e "do shell script \"${INSTALL_CMDS}\" with administrator privileges" 2>/dev/null; then
    print_success "Installed to $INSTALL_PATH (root:wheel)"
    # Force LaunchServices to recognise the /Applications copy
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$INSTALL_PATH" 2>/dev/null
    print_success "LaunchServices updated"
else
    print_warn "Admin install failed — falling back to user install (NE may not activate)"
    if [ -d "$INSTALL_PATH" ]; then rm -rf "$INSTALL_PATH"; fi
    ditto "$APP_BUNDLE" "$INSTALL_PATH"
    print_success "Installed to $INSTALL_PATH"
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

# Create helper script v5 — handles hosts, pf, proxy settings, CLI wrappers, and browser policy files
WRAPPER_DIR="/usr/local/lib/focusshield/wrappers"
SUPPORT_DIR="/usr/local/lib/focusshield"
ALIAS_SCRIPT_SRC="$SCRIPT_DIR/update_aliases.sh"
CLI_GUARD_SRC="$SCRIPT_DIR/focusshield-cli-guard.sh"
DOMAIN_ADD_SRC="$SCRIPT_DIR/focusshield-domain-add.sh"
HELPER_TMP=$(mktemp)
cat > "$HELPER_TMP" << 'HELPEREOF'
#!/bin/bash
# FocusShield privileged helper v5
# Usage: focusshield-helper <hosts_tmp> <pf_tmp> <pac_url|disable> <enable|disable> [wrappers_tmp_dir] [browser_policies_tmp_dir]
set -e
HOSTS_TMP="$1"
PF_TMP="$2"
PAC_URL="$3"
PROXY_MODE="$4"
WRAPPERS_TMP="$5"   # optional: dir containing wrapper scripts to install/refresh
BROWSER_POLICIES_TMP="$6"   # optional: dir containing browser managed-policy files

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

# --- PAC Proxy ---
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

# --- CLI Wrapper Scripts ---
# Wrapper scripts live in WRAPPER_STORE and are symlinked into /usr/local/bin/.
# /usr/local/bin appears BEFORE /usr/bin in the default macOS PATH, so our
# wrappers shadow the real binary. If a real binary exists at /usr/local/bin/{tool},
# we save it to SAVED_DIR so it can be restored on deactivation.
WRAPPER_STORE="/usr/local/lib/focusshield/wrappers"
SAVED_DIR="/usr/local/lib/focusshield/saved"
if [ -n "$WRAPPERS_TMP" ] && [ -d "$WRAPPERS_TMP" ]; then
    mkdir -p "$WRAPPER_STORE" "$SAVED_DIR"
    ACTIVE_TOOLS=""
    for wrapper in "$WRAPPERS_TMP"/*; do
        [ -f "$wrapper" ] || continue
        TOOL=$(basename "$wrapper")
        ACTIVE_TOOLS="$ACTIVE_TOOLS $TOOL"
        DEST="$WRAPPER_STORE/$TOOL"
        LINK="/usr/local/bin/$TOOL"
        cp "$wrapper" "$DEST"
        chmod 755 "$DEST"
        # If a real (non-symlink) binary exists at the link location, save it first
        if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
            cp "$LINK" "$SAVED_DIR/$TOOL"
        fi
        # Always create/overwrite symlink so our wrapper takes priority
        ln -sf "$DEST" "$LINK"
    done

    # Update aliases after installing wrappers
    if [ -n "$SUDO_USER" ] && [ -x "/usr/local/lib/focusshield/update_aliases.sh" ]; then
        sudo -u $SUDO_USER /usr/local/lib/focusshield/update_aliases.sh || true
    fi
    # Remove stale wrappers and restore saved originals for tools no longer in list
    if [ -d "$WRAPPER_STORE" ]; then
        for existing in "$WRAPPER_STORE"/*; do
            [ -f "$existing" ] || continue
            TOOL=$(basename "$existing")
            case " $ACTIVE_TOOLS " in
                *" $TOOL "*) ;;
                *)
                    rm -f "$existing" "/usr/local/bin/$TOOL"
                    [ -f "$SAVED_DIR/$TOOL" ] && mv "$SAVED_DIR/$TOOL" "/usr/local/bin/$TOOL"
                    ;;
            esac
        done
    fi
elif [ "$PROXY_MODE" = "disable" ]; then

    # Also remove aliases on disable
    if [ -x "/usr/local/lib/focusshield/update_aliases.sh" ]; then
        sudo -u $SUDO_USER /usr/local/lib/focusshield/update_aliases.sh --remove || true
    fi

    # On deactivation: remove all wrappers and restore any saved originals
    if [ -d "$WRAPPER_STORE" ]; then
        for wrapper in "$WRAPPER_STORE"/*; do
            [ -f "$wrapper" ] || continue
            TOOL=$(basename "$wrapper")
            rm -f "$wrapper" "/usr/local/bin/$TOOL"
            [ -f "$SAVED_DIR/$TOOL" ] && mv "$SAVED_DIR/$TOOL" "/usr/local/bin/$TOOL"
        done
    fi
fi

# --- Browser managed policies ---
MANAGED_PREFS_DIR="/Library/Managed Preferences"
FIREFOX_POLICY_DEST="/Library/Application Support/Mozilla/managed-policies.json"
if [ -n "$BROWSER_POLICIES_TMP" ] && [ -d "$BROWSER_POLICIES_TMP" ]; then
    mkdir -p "$MANAGED_PREFS_DIR" "$(dirname "$FIREFOX_POLICY_DEST")"
    ACTIVE_POLICY_IDS=""
    for policy in "$BROWSER_POLICIES_TMP"/*; do
        [ -f "$policy" ] || continue
        BASE=$(basename "$policy")
        case "$BASE" in
            *.plist)
                BUNDLE_ID="${BASE%.plist}"
                ACTIVE_POLICY_IDS="$ACTIVE_POLICY_IDS $BUNDLE_ID"
                cp "$policy" "$MANAGED_PREFS_DIR/$BASE"
                chmod 644 "$MANAGED_PREFS_DIR/$BASE"
                ;;
            org.mozilla.firefox.json)
                ACTIVE_POLICY_IDS="$ACTIVE_POLICY_IDS org.mozilla.firefox"
                cp "$policy" "$FIREFOX_POLICY_DEST"
                chmod 644 "$FIREFOX_POLICY_DEST"
                ;;
        esac
    done

    for existing in "$MANAGED_PREFS_DIR"/*.plist; do
        [ -f "$existing" ] || continue
        BUNDLE_ID=$(basename "$existing" .plist)
        case " $ACTIVE_POLICY_IDS " in
            *" $BUNDLE_ID "*) ;;
            *) rm -f "$existing" ;;
        esac
    done

    case " $ACTIVE_POLICY_IDS " in
        *" org.mozilla.firefox "*) ;;
        *) rm -f "$FIREFOX_POLICY_DEST" ;;
    esac
else
    rm -f "$MANAGED_PREFS_DIR"/com.google.Chrome.plist \
          "$MANAGED_PREFS_DIR"/company.thebrowser.Browser.plist \
          "$MANAGED_PREFS_DIR"/com.brave.Browser.plist \
          "$MANAGED_PREFS_DIR"/com.microsoft.edgemac.plist \
          "$MANAGED_PREFS_DIR"/com.operasoftware.Opera.plist \
          "$MANAGED_PREFS_DIR"/com.vivaldi.Vivaldi.plist \
          "$MANAGED_PREFS_DIR"/org.chromium.Chromium.plist \
          "$FIREFOX_POLICY_DEST"
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

# Always reinstall helper to ensure v4 + DNS proxy is in place
echo ""
print_warn "Admin password required (one-time only — enables password-free toggling):"

# Build a temporary install script with strict error handling instead of fragile && chain.
INSTALL_SCRIPT_TMP=$(mktemp /tmp/focusshield_install.XXXXXX)
cat > "$INSTALL_SCRIPT_TMP" << 'INSTALL_SCRIPT_HEADER'
#!/bin/bash
set -e
INSTALL_SCRIPT_HEADER

cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_SCRIPT_BODY
# Step 1: Install helper binary
mkdir -p /usr/local/bin '$SUPPORT_DIR'
cp '$HELPER_TMP' '$HELPER_PATH'
chmod 755 '$HELPER_PATH'
chown root:wheel '$HELPER_PATH'
INSTALL_SCRIPT_BODY

if [ -f "$ALIAS_SCRIPT_SRC" ]; then
    cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_ALIAS
# Step 2a: Install alias manager
cp '$ALIAS_SCRIPT_SRC' '$SUPPORT_DIR/update_aliases.sh'
chmod 755 '$SUPPORT_DIR/update_aliases.sh'
chown root:wheel '$SUPPORT_DIR/update_aliases.sh'
INSTALL_ALIAS
fi

if [ -f "$CLI_GUARD_SRC" ]; then
    cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_GUARD
# Step 2b: Install CLI guard
cp '$CLI_GUARD_SRC' '$SUPPORT_DIR/focusshield-cli-guard'
chmod 755 '$SUPPORT_DIR/focusshield-cli-guard'
chown root:wheel '$SUPPORT_DIR/focusshield-cli-guard'
INSTALL_GUARD
fi

if [ -f "$DOMAIN_ADD_SRC" ]; then
    cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_DOMAIN_ADD
# Step 2d: Install domain-add helper (used by CLI guard for l=w/l=b env var support)
cp '$DOMAIN_ADD_SRC' '$SUPPORT_DIR/focusshield-domain-add'
chmod 755 '$SUPPORT_DIR/focusshield-domain-add'
chown root:wheel '$SUPPORT_DIR/focusshield-domain-add'
INSTALL_DOMAIN_ADD
fi

if [ -f "$DNS_BINARY" ]; then
    cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_DNS
# Step 2c: Install DNS proxy
cp '$DNS_BINARY' '$DNS_PROXY_PATH'
chmod 755 '$DNS_PROXY_PATH'
chown root:wheel '$DNS_PROXY_PATH'
INSTALL_DNS
fi

cat >> "$INSTALL_SCRIPT_TMP" << INSTALL_SUDOERS
# Step 3: Install sudoers with validation
cp '$SUDOERS_TMP' '$SUDOERS_PATH'
chmod 440 '$SUDOERS_PATH'
chown root:wheel '$SUDOERS_PATH'

# Step 4: Validate sudoers syntax — remove and abort if invalid
if ! /usr/sbin/visudo -c -f '$SUDOERS_PATH' 2>/dev/null; then
    rm -f '$SUDOERS_PATH'
    echo 'FOCUSSHIELD_ERROR: sudoers validation failed' >&2
    exit 10
fi

# Step 5: Final verification
if [ ! -f '$SUDOERS_PATH' ]; then
    echo 'FOCUSSHIELD_ERROR: sudoers file missing after install' >&2
    exit 11
fi
INSTALL_SUDOERS

chmod 755 "$INSTALL_SCRIPT_TMP"

if osascript -e "do shell script \"/bin/bash '$INSTALL_SCRIPT_TMP'\" with administrator privileges" 2>/dev/null; then
    rm -f "$INSTALL_SCRIPT_TMP"
    # Post-install verification from userland
    if [ -f "$SUDOERS_PATH" ] && [ -f "$HELPER_PATH" ]; then
        print_success "Helper v4 + DNS proxy installed — no more password prompts!"
    else
        print_warn "Helper install reported success but artifacts are missing — try running install again"
    fi
else
    rm -f "$INSTALL_SCRIPT_TMP"
    print_warn "Helper install skipped — you can run the install script again later"
fi

rm -f "$HELPER_TMP" "$SUDOERS_TMP"

# ── Step 9: Register with Launch Services ────────────────────────────
print_step "Registering with system..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH" 2>/dev/null || true
print_success "Registered with Launch Services"

print_step "Resetting stale Accessibility permission cache..."
if /usr/bin/tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1; then
    print_success "Accessibility permission cache reset for $BUNDLE_ID"
else
    print_warn "Could not reset Accessibility permission cache automatically"
fi

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
