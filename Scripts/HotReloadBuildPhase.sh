#!/bin/bash
#
# HotReload Build Phase Script (pre-build)
# 1. Compile swiftc wrapper to /tmp
# 2. Export build settings
# 3. Auto-start file watcher
#

# Skip for Release builds
if [ "$CONFIGURATION" != "Debug" ] && [ "$CONFIGURATION" != "QA-Debug" ]; then
    exit 0
fi

SIGNAL_DIR="/tmp/HotReload-$(id -u)"
mkdir -p "$SIGNAL_DIR" "$SIGNAL_DIR/dylibs" "$SIGNAL_DIR/swiftc_cache"

# ──────────────────────────────────────────────
# 0. Find HotReload Scripts directory
# ──────────────────────────────────────────────
# Strategy: this script knows its own location via $0 or SCRIPT_INPUT_FILE,
# but Xcode Build Phase doesn't pass $0 reliably.
# Instead, search in known locations with SPM package path first.
HR_SCRIPTS_DIR=""
for dir in "${BUILD_DIR}/../SourcePackages/checkouts/HotReload/Scripts" \
           "$(dirname "${SCRIPT_INPUT_FILE_0:-/dev/null}")" \
           "${SRCROOT}/Packages/HotReload/Scripts" \
           "${SRCROOT}/HotReload/Scripts" \
           "${SRCROOT}/Tools/HotReload"; do
    if [ -f "$dir/hot_reload.swift" ] && [ -f "$dir/swiftc_wrapper.swift" ]; then
        HR_SCRIPTS_DIR="$dir"
        break
    fi
done

# Fallback: find in Tuist .build or any local package reference
if [ -z "$HR_SCRIPTS_DIR" ]; then
    HR_SCRIPTS_DIR=$(find "${SRCROOT}" -path "*/HotReload/Scripts/hot_reload.swift" -not -path "*/DerivedData/*" -exec dirname {} \; 2>/dev/null | head -1)
fi

# Last resort: check if package is referenced via absolute path in Package.swift or Tuist
if [ -z "$HR_SCRIPTS_DIR" ]; then
    # Search in common SPM local package locations
    for candidate in /Users/*/Git/HotReload/Scripts /Users/*/Developer/HotReload/Scripts; do
        if [ -f "$candidate/hot_reload.swift" ]; then
            HR_SCRIPTS_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$HR_SCRIPTS_DIR" ]; then
    echo "[HotReload] Scripts directory not found. Skipping."
    exit 0
fi

echo "[HotReload] Scripts: $HR_SCRIPTS_DIR"

# ──────────────────────────────────────────────
# 1. Compile swiftc wrapper
# ──────────────────────────────────────────────
WRAPPER_SRC="$HR_SCRIPTS_DIR/swiftc_wrapper.swift"
WRAPPER_DST="$SIGNAL_DIR/swiftc"

if [ -f "$WRAPPER_SRC" ]; then
    if [ ! -f "$WRAPPER_DST" ] || [ "$WRAPPER_SRC" -nt "$WRAPPER_DST" ]; then
        $(xcrun --find swiftc) -O "$WRAPPER_SRC" -o "$WRAPPER_DST" 2>/dev/null
        chmod +x "$WRAPPER_DST"
        echo "[HotReload] swiftc wrapper compiled"
    fi

    # Copy to fixed path (for xcconfig SWIFT_EXEC)
    FIXED_DIR="/tmp/HotReload"
    mkdir -p "$FIXED_DIR"
    cp -f "$WRAPPER_DST" "$FIXED_DIR/swiftc"
    chmod +x "$FIXED_DIR/swiftc"

    # Save real swiftc path for wrapper to use (avoids hardcoding)
    xcrun --find swiftc > "$SIGNAL_DIR/real_swiftc_path"
else
    echo "[HotReload] swiftc_wrapper.swift not found"
fi

# ──────────────────────────────────────────────
# 2. Export build settings
# ──────────────────────────────────────────────
HR_ARCH="${CURRENT_ARCH}"
if [ -z "$HR_ARCH" ] || [ "$HR_ARCH" = "undefined_arch" ]; then
    HR_ARCH="${ARCHS%% *}"
fi
if [ -z "$HR_ARCH" ] || [ "$HR_ARCH" = "undefined_arch" ]; then
    HR_ARCH=$(uname -m)
fi

cat > "$SIGNAL_DIR/build_settings.json" << SETTINGS_EOF
{
    "sdk": "${SDKROOT}",
    "arch": "${HR_ARCH}",
    "build_dir": "${BUILD_DIR}",
    "project_root": "${SRCROOT}",
    "swift_version": "5"
}
SETTINGS_EOF

# ──────────────────────────────────────────────
# 3. Auto-start file watcher (restart if script updated)
# ──────────────────────────────────────────────
HOT_RELOAD_SCRIPT="$HR_SCRIPTS_DIR/hot_reload.swift"

if [ -f "$HOT_RELOAD_SCRIPT" ]; then
    SHOULD_START=false
    EXISTING_PID=$(pgrep -f "hot_reload.swift" 2>/dev/null)

    if [ -z "$EXISTING_PID" ]; then
        SHOULD_START=true
    else
        # Restart if script is newer than the running process
        SCRIPT_MTIME=$(stat -f %m "$HOT_RELOAD_SCRIPT" 2>/dev/null || echo 0)
        SAVED_MTIME=$(cat "$SIGNAL_DIR/server_script_mtime" 2>/dev/null || echo 0)

        if [ "$SCRIPT_MTIME" != "$SAVED_MTIME" ]; then
            echo "[HotReload] Script updated, restarting file watcher..."
            kill "$EXISTING_PID" 2>/dev/null
            sleep 1
            SHOULD_START=true
        else
            echo "[HotReload] File watcher already running (PID: $EXISTING_PID)"
        fi
    fi

    if $SHOULD_START; then
        nohup env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" HOME="$HOME" swift "$HOT_RELOAD_SCRIPT" > "$SIGNAL_DIR/server.log" 2>&1 &
        echo "[HotReload] File watcher started (PID: $!)"
        stat -f %m "$HOT_RELOAD_SCRIPT" > "$SIGNAL_DIR/server_script_mtime"
    fi
else
    echo "[HotReload] hot_reload.swift not found at $HOT_RELOAD_SCRIPT"
fi