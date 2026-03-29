#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Focus Shield — Build & Run Scripts
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
XCODEPROJ="$PROJECT_DIR/FocusShield.xcodeproj"
DERIVED_DATA="$PROJECT_DIR/.build/DerivedData"
ENV_FILE="$PROJECT_DIR/.env"
SYSEXT_BUNDLE_ID="com.focusshield.macos.filter-data"
SYSEXT_BUNDLE_NAME="$SYSEXT_BUNDLE_ID.systemextension"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
}

set_signed_xcode_flags() {
    local TEAM_ID="${1:-}"
    SIGNED_XCODE_FLAGS=(
        -derivedDataPath "$DERIVED_DATA"
        "DEVELOPMENT_TEAM=$TEAM_ID"
    )
}

verify_embedded_system_extension() {
    local APP_PATH="$1"
    local SYSEXT_PATH="$APP_PATH/Contents/Library/SystemExtensions/$SYSEXT_BUNDLE_NAME"
    local INFO_PLIST="$SYSEXT_PATH/Contents/Info.plist"

    echo -e "${BLUE}▸ Verifying embedded system extension...${NC}"

    if [ ! -d "$SYSEXT_PATH" ]; then
        echo -e "${RED}❌ Expected system extension not found at:${NC} $SYSEXT_PATH"
        if [ -d "$APP_PATH/Contents/Library/SystemExtensions" ]; then
            echo -e "${YELLOW}Available embedded system extensions:${NC}"
            find "$APP_PATH/Contents/Library/SystemExtensions" -maxdepth 1 -mindepth 1 -type d -print
        fi
        return 1
    fi

    if [ ! -f "$INFO_PLIST" ]; then
        echo -e "${RED}❌ Embedded system extension is missing Info.plist${NC}"
        return 1
    fi

    local BUNDLE_ID
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || true)
    local PACKAGE_TYPE
    PACKAGE_TYPE=$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$INFO_PLIST" 2>/dev/null || true)
    local EXECUTABLE_NAME
    EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null || true)

    if [ "$BUNDLE_ID" != "$SYSEXT_BUNDLE_ID" ]; then
        echo -e "${RED}❌ Embedded system extension bundle ID mismatch:${NC} $BUNDLE_ID"
        return 1
    fi

    if [ "$PACKAGE_TYPE" != "SYSX" ]; then
        echo -e "${RED}❌ Embedded system extension package type is not SYSX:${NC} $PACKAGE_TYPE"
        return 1
    fi

    if [ -z "$EXECUTABLE_NAME" ] || [ ! -x "$SYSEXT_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]; then
        echo -e "${RED}❌ Embedded system extension executable is missing:${NC} $EXECUTABLE_NAME"
        return 1
    fi

    echo -e "${GREEN}  ✓ Embedded system extension verified${NC}"
}

resolve_team_id() {
    local OVERRIDE="${1:-}"
    if [ -n "$OVERRIDE" ]; then
        printf '%s\n' "$OVERRIDE"
        return 0
    fi
    if [ -n "${TEAM_ID:-}" ]; then
        printf '%s\n' "$TEAM_ID"
        return 0
    fi
    return 1
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  🛡️  Focus Shield — $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

load_env

# ─────────────────────────────────────────────────────────────
# Generate Xcode Project (if needed)
# ─────────────────────────────────────────────────────────────
generate_project() {
    print_header "Generating Xcode Project"
    if ! command -v xcodegen &>/dev/null; then
        echo -e "${YELLOW}Installing xcodegen...${NC}"
        brew install xcodegen
    fi
    cd "$PROJECT_DIR"
    xcodegen generate
    echo -e "${GREEN}✅ Xcode project generated${NC}"
}

# ─────────────────────────────────────────────────────────────
# macOS — Quick build via Swift PM
# ─────────────────────────────────────────────────────────────
build_macos_spm() {
    print_header "Building macOS (Swift PM)"
    cd "$PROJECT_DIR"
    echo -e "${YELLOW}⚠ Swift PM builds do not include the system extension.${NC}"
    swift build
    echo -e "${GREEN}✅ macOS build complete${NC}"
    echo -e "   Binary: $(swift build --show-bin-path)/FocusShield"
}

run_macos_spm() {
    print_header "Running macOS (Swift PM)"
    cd "$PROJECT_DIR"
    echo -e "${YELLOW}⚠ Swift PM runs do not include the system extension.${NC}"
    swift build
    "$(swift build --show-bin-path)/FocusShield"
}

# ─────────────────────────────────────────────────────────────
# macOS — Xcode build
# ─────────────────────────────────────────────────────────────
build_macos_xcode() {
    print_header "Building macOS (Xcode)"
    ensure_xcodeproj
    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        build | xcbeautify 2>/dev/null || xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        build
    echo -e "${GREEN}✅ macOS Xcode build complete${NC}"
}

run_macos_xcode() {
    print_header "Running macOS (Xcode)"
    build_macos_xcode
    APP_PATH=$(find "$DERIVED_DATA" -name "Focus Shield.app" -type d | head -1)
    if [ -n "$APP_PATH" ]; then
        echo -e "${GREEN}Launching: $APP_PATH${NC}"
        open "$APP_PATH"
    else
        echo -e "${RED}❌ Could not find built app${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# iOS Simulator
# ─────────────────────────────────────────────────────────────
list_ios_simulators() {
    print_header "Available iOS Simulators"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
}

boot_ios_simulator() {
    local DEVICE="${1:-iPhone 16}"
    print_header "Booting iOS Simulator: $DEVICE"

    # Find the device UDID
    local UDID
    UDID=$(xcrun simctl list devices available | grep "$DEVICE" | head -1 | grep -oE '[A-F0-9-]{36}')

    if [ -z "$UDID" ]; then
        echo -e "${RED}❌ Simulator '$DEVICE' not found. Available devices:${NC}"
        list_ios_simulators
        exit 1
    fi

    xcrun simctl boot "$UDID" 2>/dev/null || true
    open -a Simulator
    echo -e "${GREEN}✅ Simulator booted: $DEVICE ($UDID)${NC}"
    echo "$UDID"
}

build_ios_simulator() {
    local DEVICE="${1:-iPhone 16}"
    print_header "Building iOS (Simulator: $DEVICE)"
    ensure_xcodeproj
    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -derivedDataPath "$DERIVED_DATA" \
        build | xcbeautify 2>/dev/null || xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -derivedDataPath "$DERIVED_DATA" \
        build
    echo -e "${GREEN}✅ iOS Simulator build complete${NC}"
}

run_ios_simulator() {
    local DEVICE="${1:-iPhone 16}"
    print_header "Building & Running on iOS Simulator: $DEVICE"
    ensure_xcodeproj

    # Boot simulator
    local UDID
    UDID=$(xcrun simctl list devices available | grep "$DEVICE" | head -1 | grep -oE '[A-F0-9-]{36}')
    xcrun simctl boot "$UDID" 2>/dev/null || true
    open -a Simulator

    # Build and install
    build_ios_simulator "$DEVICE"

    # Find the .app
    APP_PATH=$(find "$DERIVED_DATA" -path "*/Debug-iphonesimulator/Focus Shield.app" -type d | head -1)
    if [ -n "$APP_PATH" ]; then
        echo -e "${GREEN}Installing on simulator...${NC}"
        xcrun simctl install "$UDID" "$APP_PATH"
        xcrun simctl launch "$UDID" com.focusshield.ios
        echo -e "${GREEN}✅ App launched on simulator${NC}"
    else
        echo -e "${RED}❌ Could not find built app${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# iOS Device (requires signing)
# ─────────────────────────────────────────────────────────────
build_ios_device() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Building iOS (Device)"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Missing TEAM_ID. Put TEAM_ID=... in .env or pass it explicitly.${NC}"
        exit 1
    fi

    local -a SIGNED_XCODE_FLAGS
    set_signed_xcode_flags "$TEAM_ID"

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Debug \
        -destination "generic/platform=iOS" \
        "${SIGNED_XCODE_FLAGS[@]}" \
        build
    echo -e "${GREEN}✅ iOS device build complete${NC}"
}

# ─────────────────────────────────────────────────────────────
# macOS Device (sign for distribution)
# ─────────────────────────────────────────────────────────────
build_macos_signed() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Building macOS (Signed)"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Missing TEAM_ID. Put TEAM_ID=... in .env or pass it explicitly.${NC}"
        exit 1
    fi

    local -a SIGNED_XCODE_FLAGS
    set_signed_xcode_flags "$TEAM_ID"

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        "${SIGNED_XCODE_FLAGS[@]}" \
        clean build
    echo -e "${GREEN}✅ macOS signed build complete${NC}"

    APP_PATH=$(find "$DERIVED_DATA" -name "Focus Shield.app" -type d | head -1)
    echo -e "   App: $APP_PATH"
}

install_macos_signed() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Installing macOS (Signed)"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Missing TEAM_ID. Put TEAM_ID=... in .env or pass it explicitly.${NC}"
        exit 1
    fi

    local -a SIGNED_XCODE_FLAGS
    set_signed_xcode_flags "$TEAM_ID"

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        "${SIGNED_XCODE_FLAGS[@]}" \
        clean build | xcbeautify 2>/dev/null || xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        "${SIGNED_XCODE_FLAGS[@]}" \
        clean build

    APP_PATH=$(find "$DERIVED_DATA" -path "*/Release/Focus Shield.app" -type d | head -1)
    if [ -z "$APP_PATH" ]; then
        echo -e "${RED}❌ Could not find signed app bundle${NC}"
        exit 1
    fi

    echo -e "${GREEN}Signed app bundle:${NC} $APP_PATH"
    verify_embedded_system_extension "$APP_PATH"

    # Notarize with Apple (required for system extension activation)
    local APPLE_ID="${NOTARIZE_APPLE_ID:-}"
    local NOTARIZE_PASS="${NOTARIZE_PASSWORD:-}"
    local NOTARIZE_TEAM="${NOTARIZE_TEAM_ID:-$TEAM_ID}"

    if [ -n "$APPLE_ID" ] && [ -n "$NOTARIZE_PASS" ]; then
        echo -e "${BLUE}▸ Submitting for notarization...${NC}"
        local ZIP_PATH="/tmp/FocusShield-notarize.zip"
        ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

        local NOTARIZE_OUTPUT
        NOTARIZE_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$NOTARIZE_PASS" \
            --team-id "$NOTARIZE_TEAM" \
            --wait 2>&1) || true
        echo "$NOTARIZE_OUTPUT"

        if echo "$NOTARIZE_OUTPUT" | grep -q "status: Invalid"; then
            echo -e "${RED}❌ Notarization rejected — check log above${NC}"
            local SUBMISSION_ID
            SUBMISSION_ID=$(echo "$NOTARIZE_OUTPUT" | grep -m1 "id:" | awk '{print $2}')
            if [ -n "$SUBMISSION_ID" ]; then
                echo -e "${YELLOW}▸ Fetching rejection details...${NC}"
                xcrun notarytool log "$SUBMISSION_ID" \
                    --apple-id "$APPLE_ID" \
                    --password "$NOTARIZE_PASS" \
                    --team-id "$NOTARIZE_TEAM" 2>&1
            fi
            rm -f "$ZIP_PATH"
            exit 1
        fi

        rm -f "$ZIP_PATH"
        echo -e "${GREEN}  ✓ Notarization accepted${NC}"

        xcrun stapler staple "$APP_PATH" 2>&1
        echo -e "${GREEN}  ✓ Notarization ticket stapled${NC}"
    else
        echo -e "${YELLOW}⚠ Skipping notarization (set NOTARIZE_APPLE_ID + NOTARIZE_PASSWORD in .env)${NC}"
    fi

    APP_SOURCE_BUNDLE="$APP_PATH" ./install.sh
}

run_macos_signed() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Running macOS (Signed)"
    install_macos_signed "$TEAM_ID"
    open -a "/Applications/Focus Shield.app"
}

# ─────────────────────────────────────────────────────────────
# Archive for distribution
# ─────────────────────────────────────────────────────────────
archive_macos() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Archiving macOS"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Missing TEAM_ID. Put TEAM_ID=... in .env or pass it explicitly.${NC}"
        exit 1
    fi

    local -a SIGNED_XCODE_FLAGS
    set_signed_xcode_flags "$TEAM_ID"

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        -archivePath "$PROJECT_DIR/.build/FocusShield-macOS.xcarchive" \
        "${SIGNED_XCODE_FLAGS[@]}" \
        clean archive
    echo -e "${GREEN}✅ macOS archive complete: .build/FocusShield-macOS.xcarchive${NC}"
}

archive_ios() {
    local TEAM_ID
    TEAM_ID="$(resolve_team_id "${1:-}")" || true
    print_header "Archiving iOS"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Missing TEAM_ID. Put TEAM_ID=... in .env or pass it explicitly.${NC}"
        exit 1
    fi

    local -a SIGNED_XCODE_FLAGS
    set_signed_xcode_flags "$TEAM_ID"

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Release \
        -destination "generic/platform=iOS" \
        -archivePath "$PROJECT_DIR/.build/FocusShield-iOS.xcarchive" \
        "${SIGNED_XCODE_FLAGS[@]}" \
        archive
    echo -e "${GREEN}✅ iOS archive complete: .build/FocusShield-iOS.xcarchive${NC}"
}

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
ensure_xcodeproj() {
    if [ ! -d "$XCODEPROJ" ]; then
        echo -e "${YELLOW}Xcode project not found, generating...${NC}"
        generate_project
        return
    fi

    if [ "$PROJECT_DIR/project.yml" -nt "$XCODEPROJ/project.pbxproj" ]; then
        echo -e "${YELLOW}project.yml is newer than the generated Xcode project, regenerating...${NC}"
        generate_project
    fi
}

clean() {
    print_header "Cleaning"
    rm -rf "$DERIVED_DATA"
    rm -rf "$PROJECT_DIR/.build"
    swift package clean 2>/dev/null || true
    echo -e "${GREEN}✅ Clean complete${NC}"
}

# ─────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Quick Start:"
    echo "  generate              Generate Xcode project from project.yml"
    echo "  run-macos             Build & run macOS app (Swift PM, dev-only, no sysext)"
    echo "  run-ios [device]      Build & run on iOS Simulator (default: iPhone 16)"
    echo ""
    echo "macOS:"
    echo "  build-macos           Build macOS via Swift PM (dev-only, no sysext)"
    echo "  build-macos-xcode     Build macOS via Xcode"
    echo "  run-macos-xcode       Build & launch macOS via Xcode"
    echo "  build-macos-signed [TEAM_ID]  Signed macOS build"
    echo "  install-macos-signed [TEAM_ID] Install signed macOS app + helper"
    echo "  run-macos-signed [TEAM_ID]     Install and launch signed macOS app"
    echo "  archive-macos [TEAM_ID]       Archive for distribution"
    echo ""
    echo "iOS:"
    echo "  list-simulators       List available iOS simulators"
    echo "  build-ios [device]    Build for iOS Simulator"
    echo "  run-ios [device]      Build, install & launch on Simulator"
    echo "  build-ios-device [TEAM_ID]  Build for physical iOS device"
    echo "  archive-ios [TEAM_ID]       Archive for distribution"
    echo ""
    echo "Other:"
    echo "  clean                 Remove all build artifacts"
    echo "  open                  Open in Xcode"
    echo ""
}

case "${1:-help}" in
    generate)           generate_project ;;
    build-macos)        build_macos_spm ;;
    run-macos)          run_macos_spm ;;
    build-macos-xcode)  build_macos_xcode ;;
    run-macos-xcode)    run_macos_xcode ;;
    build-macos-signed) build_macos_signed "${2:-}" ;;
    install-macos-signed) install_macos_signed "${2:-}" ;;
    run-macos-signed)   run_macos_signed "${2:-}" ;;
    archive-macos)      archive_macos "${2:-}" ;;
    list-simulators)    list_ios_simulators ;;
    build-ios)          build_ios_simulator "${2:-iPhone 16}" ;;
    run-ios)            run_ios_simulator "${2:-iPhone 16}" ;;
    build-ios-device)   build_ios_device "${2:-}" ;;
    archive-ios)        archive_ios "${2:-}" ;;
    clean)              clean ;;
    open)               ensure_xcodeproj && open "$XCODEPROJ" ;;
    *)                  usage ;;
esac
