#!/bin/bash
#
# HotReload Installer
# Configures HotReload for your project.
#
# Usage:
#   ./install.sh [project_path]
#
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_ok()    { echo -e "${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "${YELLOW}!${NC} $1"; }
log_info()  { echo -e "${BLUE}→${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo ""
echo -e "${GREEN}╔════════════════════════════════╗${NC}"
echo -e "${GREEN}║     HotReload Installer         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════╝${NC}"
echo ""

PROJECT_ROOT="${1:-.}"
PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd)

log_info "Project path: $PROJECT_ROOT"

# Resolve this script's directory (for finding Scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verify package structure
if [ ! -f "$SCRIPT_DIR/Scripts/HotReloadBuildPhase.sh" ]; then
    log_error "HotReloadBuildPhase.sh not found at $SCRIPT_DIR/Scripts/"
    log_error "This script must be run from the HotReload package root."
    log_info "Expected structure:"
    echo "  HotReload/"
    echo "    install.sh          <- run this"
    echo "    Scripts/"
    echo "      HotReloadBuildPhase.sh"
    echo "      hot_reload.swift"
    echo "      swiftc_wrapper.swift"
    exit 1
fi

echo ""

# ──────────────────────────────────────────────
# 1. Detect project type
# ──────────────────────────────────────────────
PROJECT_TYPE="unknown"

if [ -f "$PROJECT_ROOT/Tuist/Config.swift" ] || [ -d "$PROJECT_ROOT/Tuist" ]; then
    PROJECT_TYPE="tuist"
    log_ok "Project type: Tuist"
elif [ -f "$PROJECT_ROOT/Package.swift" ]; then
    PROJECT_TYPE="spm"
    log_ok "Project type: Swift Package Manager"
elif find "$PROJECT_ROOT" -maxdepth 1 -name "*.xcodeproj" -o -name "*.xcworkspace" 2>/dev/null | grep -q .; then
    PROJECT_TYPE="xcode"
    log_ok "Project type: Xcode"
else
    log_warn "Could not detect project type. Manual setup required."
fi

# ──────────────────────────────────────────────
# 2. Add xcconfig settings
# ──────────────────────────────────────────────
echo ""
log_info "Adding xcconfig settings..."

# Use single-quoted heredoc to prevent $(inherited) from being interpreted as subshell
HOTRELOAD_CONFIG=$(cat << 'XCCONFIG_EOF'

# ═══════════════════════════════════════════════
# HotReload Configuration (Debug only)
# ═══════════════════════════════════════════════
SWIFT_USE_INTEGRATED_DRIVER[config=Debug]=NO
SWIFT_EXEC[config=Debug]=/private/tmp/HotReload/swiftc
OTHER_SWIFT_FLAGS[config=Debug]=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports
OTHER_LDFLAGS[config=Debug]=$(inherited) -Xlinker -interposable
DEAD_CODE_STRIPPING[config=Debug]=NO
STRIP_SWIFT_SYMBOLS[config=Debug]=NO
# ═══════════════════════════════════════════════
XCCONFIG_EOF
)

XCCONFIG_FILES=$(find "$PROJECT_ROOT" -name "*.xcconfig" \
    -not -path "*/DerivedData/*" \
    -not -path "*/.build/*" \
    -not -path "*/Pods/*" \
    -not -path "*/.swiftpm/*" 2>/dev/null)

if [ -n "$XCCONFIG_FILES" ]; then
    # Separate Debug-likely and other xcconfig files
    DEBUG_CONFIGS=""
    OTHER_CONFIGS=""

    while IFS= read -r xcconfig; do
        if grep -q "HotReload Configuration" "$xcconfig" 2>/dev/null; then
            log_warn "Already configured: $(basename "$xcconfig")"
            continue
        fi

        # Must contain build settings to be a valid target
        if ! grep -qE "SWIFT_VERSION|OTHER_LDFLAGS|OTHER_SWIFT_FLAGS|IPHONEOS_DEPLOYMENT_TARGET|CODE_SIGN|DEBUG_INFORMATION_FORMAT" "$xcconfig" 2>/dev/null; then
            continue
        fi

        # Prioritize files with Debug/Dev/Module in the name
        basename_lower=$(basename "$xcconfig" | tr '[:upper:]' '[:lower:]')
        if echo "$basename_lower" | grep -qE "debug|dev|module"; then
            DEBUG_CONFIGS="${DEBUG_CONFIGS}${xcconfig}\n"
        else
            OTHER_CONFIGS="${OTHER_CONFIGS}${xcconfig}\n"
        fi
    done <<< "$XCCONFIG_FILES"

    # If Debug-specific configs found, only target those
    TARGET_CONFIGS="$DEBUG_CONFIGS"
    if [ -z "$TARGET_CONFIGS" ]; then
        TARGET_CONFIGS="$OTHER_CONFIGS"
    fi

    if [ -n "$TARGET_CONFIGS" ]; then
        echo ""
        log_info "Found xcconfig files to configure:"
        ADDED_COUNT=0
        INDEX=1
        declare -a CONFIG_ARRAY=()

        while IFS= read -r xcconfig; do
            [ -z "$xcconfig" ] && continue
            CONFIG_ARRAY+=("$xcconfig")
            echo "  $INDEX) $(basename "$xcconfig") ($(dirname "$xcconfig" | sed "s|$PROJECT_ROOT/||"))"
            INDEX=$((INDEX + 1))
        done < <(echo -e "$TARGET_CONFIGS")

        echo "  a) All of the above"
        echo "  s) Skip"
        echo ""
        read -rp "  Select files to configure [a]: " SELECTION
        SELECTION="${SELECTION:-a}"

        if [ "$SELECTION" = "s" ]; then
            log_info "Skipped xcconfig configuration."
        elif [ "$SELECTION" = "a" ]; then
            for xcconfig in "${CONFIG_ARRAY[@]}"; do
                echo "$HOTRELOAD_CONFIG" >> "$xcconfig"
                log_ok "Settings added: $(basename "$xcconfig")"
                ADDED_COUNT=$((ADDED_COUNT + 1))
            done
        else
            # Specific selection
            IDX=$((SELECTION - 1))
            if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#CONFIG_ARRAY[@]}" ]; then
                echo "$HOTRELOAD_CONFIG" >> "${CONFIG_ARRAY[$IDX]}"
                log_ok "Settings added: $(basename "${CONFIG_ARRAY[$IDX]}")"
                ADDED_COUNT=1
            else
                log_warn "Invalid selection. Skipped."
            fi
        fi
    else
        log_warn "No suitable xcconfig files found."
        log_info "Manually add the following to your Debug xcconfig:"
        echo ""
        echo "$HOTRELOAD_CONFIG"
        echo ""
    fi
else
    log_warn "No xcconfig files found."
    log_info "If not using xcconfig, add these in Xcode Build Settings (Debug only):"
    echo ""
    echo "  SWIFT_USE_INTEGRATED_DRIVER = NO"
    echo "  SWIFT_EXEC = /private/tmp/HotReload/swiftc"
    echo "  OTHER_SWIFT_FLAGS = -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports"
    echo "  OTHER_LDFLAGS = -Xlinker -interposable"
    echo "  DEAD_CODE_STRIPPING = NO"
    echo "  STRIP_SWIFT_SYMBOLS = NO"
    echo ""
fi

# ──────────────────────────────────────────────
# 3. Build Phase setup
# ──────────────────────────────────────────────
echo ""
log_info "Build Phase setup..."

DEST_DIR="$PROJECT_ROOT/Scripts"
BUILD_PHASE_SRC="$SCRIPT_DIR/Scripts/HotReloadBuildPhase.sh"

mkdir -p "$DEST_DIR"
cp "$BUILD_PHASE_SRC" "$DEST_DIR/"
chmod +x "$DEST_DIR/HotReloadBuildPhase.sh"
log_ok "HotReloadBuildPhase.sh copied to $DEST_DIR/"

case "$PROJECT_TYPE" in
    tuist)
        log_info "Tuist project detected. Add the following to your build phase helper:"
        echo ""
        echo "  .pre("
        echo "      path: .relativeToRoot(\"Scripts/HotReloadBuildPhase.sh\"),"
        echo "      name: \"HotReload Setup\","
        echo "      basedOnDependencyAnalysis: false"
        echo "  )"
        echo ""
        ;;
    xcode)
        log_info "Xcode project detected. Add a Run Script Phase:"
        echo ""
        echo '  Build Phases > + > New Run Script Phase'
        echo '  bash "${SRCROOT}/Scripts/HotReloadBuildPhase.sh"'
        echo ""
        ;;
    spm)
        log_info "SPM project detected. Add Build Phase script manually."
        ;;
    *)
        log_info "Add Build Phase script manually."
        ;;
esac

# ──────────────────────────────────────────────
# 4. AppDelegate instructions
# ──────────────────────────────────────────────
echo ""
log_info "Final step: Add the following to your AppDelegate:"
echo ""
echo -e "  ${BLUE}#if DEBUG && targetEnvironment(simulator)${NC}"
echo -e "  ${BLUE}import HotReloadClient${NC}"
echo -e "  ${BLUE}#endif${NC}"
echo ""
echo "  // Inside didFinishLaunchingWithOptions:"
echo -e "  ${BLUE}#if DEBUG && targetEnvironment(simulator)${NC}"
echo -e "  ${BLUE}HotReloadClient.start()${NC}"
echo -e "  ${BLUE}#endif${NC}"
echo ""

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} HotReload installation complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo "  1. Add SPM package (if not done yet)"
echo "  2. Add AppDelegate code shown above"
echo "  3. Debug build -> Edit file -> Cmd+S -> Instant reload!"
echo ""
echo "  UIKit:   Works automatically (override injected() recommended)"
echo "  SwiftUI: Works automatically (no code changes needed)"
echo ""
