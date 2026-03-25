#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Focus Shield — Build & Run Scripts
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
XCODEPROJ="$PROJECT_DIR/FocusShield.xcodeproj"
DERIVED_DATA="$PROJECT_DIR/.build/DerivedData"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  🛡️  Focus Shield — $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

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
    swift build
    echo -e "${GREEN}✅ macOS build complete${NC}"
    echo -e "   Binary: $(swift build --show-bin-path)/FocusShield"
}

run_macos_spm() {
    print_header "Running macOS (Swift PM)"
    cd "$PROJECT_DIR"
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
    local TEAM_ID="${1:-}"
    print_header "Building iOS (Device)"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Usage: $0 build-ios-device <TEAM_ID>${NC}"
        echo -e "${YELLOW}Find your Team ID in Xcode → Settings → Accounts → Team ID${NC}"
        exit 1
    fi

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Debug \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DERIVED_DATA" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE="Automatic" \
        build
    echo -e "${GREEN}✅ iOS device build complete${NC}"
}

# ─────────────────────────────────────────────────────────────
# macOS Device (sign for distribution)
# ─────────────────────────────────────────────────────────────
build_macos_signed() {
    local TEAM_ID="${1:-}"
    print_header "Building macOS (Signed)"
    ensure_xcodeproj

    if [ -z "$TEAM_ID" ]; then
        echo -e "${YELLOW}Usage: $0 build-macos-signed <TEAM_ID>${NC}"
        exit 1
    fi

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE="Automatic" \
        build
    echo -e "${GREEN}✅ macOS signed build complete${NC}"

    APP_PATH=$(find "$DERIVED_DATA" -name "Focus Shield.app" -type d | head -1)
    echo -e "   App: $APP_PATH"
}

# ─────────────────────────────────────────────────────────────
# Archive for distribution
# ─────────────────────────────────────────────────────────────
archive_macos() {
    local TEAM_ID="${1:-}"
    print_header "Archiving macOS"
    ensure_xcodeproj

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-macOS" \
        -configuration Release \
        -archivePath "$PROJECT_DIR/.build/FocusShield-macOS.xcarchive" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE="Automatic" \
        archive
    echo -e "${GREEN}✅ macOS archive complete: .build/FocusShield-macOS.xcarchive${NC}"
}

archive_ios() {
    local TEAM_ID="${1:-}"
    print_header "Archiving iOS"
    ensure_xcodeproj

    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "FocusShield-iOS" \
        -configuration Release \
        -destination "generic/platform=iOS" \
        -archivePath "$PROJECT_DIR/.build/FocusShield-iOS.xcarchive" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE="Automatic" \
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
    echo "  run-macos             Build & run macOS app (Swift PM, no Xcode needed)"
    echo "  run-ios [device]      Build & run on iOS Simulator (default: iPhone 16)"
    echo ""
    echo "macOS:"
    echo "  build-macos           Build macOS via Swift PM"
    echo "  build-macos-xcode     Build macOS via Xcode"
    echo "  run-macos-xcode       Build & launch macOS via Xcode"
    echo "  build-macos-signed <TEAM_ID>  Signed macOS build"
    echo "  archive-macos <TEAM_ID>       Archive for distribution"
    echo ""
    echo "iOS:"
    echo "  list-simulators       List available iOS simulators"
    echo "  build-ios [device]    Build for iOS Simulator"
    echo "  run-ios [device]      Build, install & launch on Simulator"
    echo "  build-ios-device <TEAM_ID>  Build for physical iOS device"
    echo "  archive-ios <TEAM_ID>       Archive for distribution"
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
