#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# launch-linux-overlay.sh — Hermes Pets Electron overlay launcher for Linux
#
# Usage:
#   launch-linux-overlay.sh [start]     Start the overlay (default)
#   launch-linux-overlay.sh status      Show overlay process status
#   launch-linux-overlay.sh stop        Stop all overlay processes
#
# Flags (for start command):
#   --replace               Stop existing instances before starting
#
# Environment variables (forwarded to Electron):
#   HERMES_PET_PORT          Bridge WebSocket port (default: 17473)
#   HERMES_PET_WS_URL        Bridge WebSocket URL (overrides PORT)
#   HERMES_PET_SPECIES       Pet species name
#   HERMES_PET_POSITION_FILE Path to position persistence file
#   HERMES_PET_DEBUG_ANIMATION  Enable animation debug logging ("1")
#   HERMES_PET_DEBUG_DRAG       Enable drag debug logging ("1")
#   HERMES_PET_DEBUG_EVENTS     Enable event debug logging ("1")
#   HERMES_PET_DEBUG_SPRITE     Enable sprite debug overlay ("1")
#   HERMES_PET_ALWAYS_ON_TOP_LEVEL  Always-on-top level (default: screen-saver)
#   HERMES_PET_FOCUSABLE       Make window focusable ("1")
#   HERMES_PET_SHOW_UPLOAD     Show upload button ("1")
#   HERMES_PET_CLICK_THROUGH   Enable click-through mode ("1")
#   HERMES_PET_NO_SANDBOX      Run Electron without --no-sandbox
#   DISPLAY                   X11 display (auto-detected if unset)
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAIN_JS="${OVERLAY_DIR}/src/main.js"

# Electron binary: prefer overlay's own node_modules, then cache
OVERLAY_ELECTRON="${OVERLAY_DIR}/node_modules/.bin/electron"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/hermes-pet-electron"
CACHE_ELECTRON="${CACHE_DIR}/node_modules/.bin/electron"
PACKAGE_JSON="${CACHE_DIR}/package.json"

PORT="${HERMES_PET_PORT:-17473}"
PET_TITLE_PATTERN="Hermes Pets Overlay"

# --- Helper: log to stderr with timestamp ---
log() {
    echo "[hermes-pet-linux] $(date '+%H:%M:%S') $*" >&2
}

# --- Helper: find running overlay processes ---
find_overlay_pids() {
    # Find Electron processes running our main.js
    local pids=()
    while IFS= read -r line; do
        local pid rest
        pid=$(echo "$line" | awk '{print $1}')
        rest=$(echo "$line" | cut -c"$((${#pid}+1))"-)
        if [[ "$rest" == *"main.js"* && "$rest" == *"electron"* ]]; then
            pids+=("$pid")
        fi
    done < <(ps -eo pid=,args= 2>/dev/null || true)
    printf '%s\n' "${pids[@]}" | grep -v '^$' || true
}

# --- Helper: kill process tree recursively ---
kill_tree() {
    local root_pid="$1"
    local signal="${2:-TERM}"
    local killed=0

    # Collect all descendant PIDs using pstree or manual walk
    local descendants=()
    if command -v pstree &>/dev/null; then
        # pstree -p outputs "process(pid) ..." format
        local tree
        tree=$(pstree -p "$root_pid" 2>/dev/null || echo "")
        if [[ -n "$tree" ]]; then
            # Extract all PIDs from pstree output
            while IFS= read -r pid; do
                if [[ "$pid" =~ ^[0-9]+$ ]]; then
                    descendants+=("$pid")
                fi
            done < <(echo "$tree" | grep -oP '\d+' || true)
        fi
    else
        # Fallback: walk /proc
        local queue=("$root_pid")
        local visited=""
        while [[ ${#queue[@]} -gt 0 ]]; do
            local current="${queue[0]}"
            queue=("${queue[@]:1}")
            if [[ "$visited" == *":${current}:"* ]]; then
                continue
            fi
            visited="${visited}:${current}:"
            descendants+=("$current")
            # Find children by scanning /proc
            if [[ -d /proc/${current}/task ]]; then
                for child_pid in /proc/[0-9]*/status; do
                    [[ -f "$child_pid" ]] || continue
                    local child_num
                    child_num=$(basename "$(dirname "$child_pid")")
                    local ppid
                    ppid=$(grep -m1 '^PPid:' "$child_pid" 2>/dev/null | awk '{print $2}')
                    if [[ "$ppid" == "$current" ]]; then
                        queue+=("$child_num")
                    fi
                done
            fi
        done
    fi

    # Kill in reverse order (children first)
    local i
    for (( i=${#descendants[@]}-1; i>=0; i-- )); do
        local pid="${descendants[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "-$signal" "$pid" 2>/dev/null || true
            ((killed++)) || true
        fi
    done

    echo "$killed"
}

# --- Command: status ---
cmd_status() {
    local pids
    pids=$(find_overlay_pids)

    if [[ -z "$pids" ]]; then
        echo "Overlay processes: none"
    else
        local count
        count=$(echo "$pids" | wc -l | tr -d ' ')
        echo "Overlay processes: ${count}"
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            local cmd
            cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "(unknown)")
            echo "  pid ${pid}: ${cmd}"
        done <<< "$pids"
    fi

    echo "Electron cache: ${CACHE_DIR}"
    echo "Overlay dir: ${OVERLAY_DIR}"
    echo "Bridge URL: ws://127.0.0.1:${PORT}"

    # Report DISPLAY
    echo "DISPLAY: ${DISPLAY:-<not set>}"

    return 0
}

# --- Command: stop ---
cmd_stop() {
    local pids
    pids=$(find_overlay_pids)

    if [[ -z "$pids" ]]; then
        echo "Overlay processes: none"
        echo "Electron cache: ${CACHE_DIR}"
        return 0
    fi

    log "Stopping Hermes pet overlay process tree(s): $(echo "$pids" | tr '\n' ',' | sed 's/,$//')"

    local total_killed=0
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local killed
        killed=$(kill_tree "$pid" TERM)
        total_killed=$((total_killed + killed))
    done <<< "$pids"

    # Wait for graceful shutdown
    sleep 1

    # Force-kill any remaining
    local remaining
    remaining=$(find_overlay_pids)
    if [[ -n "$remaining" ]]; then
        log "Force-killing remaining processes..."
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            kill_tree "$pid" KILL >/dev/null || true
        done <<< "$remaining"
        sleep 0.5
    fi

    local final
    final=$(find_overlay_pids)
    if [[ -n "$final" ]]; then
        log "WARNING: Could not stop all overlay processes"
        echo "Overlay processes: some may still be running"
        return 1
    fi

    echo "Stopped overlay processes: ${total_killed}"
    echo "Electron cache: ${CACHE_DIR}"
    return 0
}

# --- Command: start ---
cmd_start() {
    # Check main.js exists
    if [[ ! -f "$MAIN_JS" ]]; then
        log "ERROR: Overlay entrypoint not found: ${MAIN_JS}"
        echo "ERROR: Overlay entrypoint not found: ${MAIN_JS}" >&2
        return 1
    fi

    # Check for existing instances
    local existing
    existing=$(find_overlay_pids)
    if [[ -n "$existing" ]]; then
        local count
        count=$(echo "$existing" | wc -l | tr -d ' ')
        if [[ "${REPLACE:-0}" == "1" ]]; then
            log "Stopping existing instances (--replace)..."
            cmd_stop >/dev/null 2>&1 || true
            sleep 0.5
        else
            echo "Hermes pet overlay already running (${count} process(es), pid: $(echo "$existing" | tr '\n' ',' | sed 's/,$//')); reusing existing instance."
            echo "Use 'hermes-pet launch --replace' to restart the overlay."
            echo "Electron cache: ${CACHE_DIR}"
            echo "Bridge URL: ws://127.0.0.1:${PORT}"
            return 0
        fi
    fi

    # Ensure DISPLAY is set
    if [[ -z "${DISPLAY:-}" ]]; then
        # Try to auto-detect from current session
        if [[ -f /proc/${PPID}/environ ]]; then
            DISPLAY=$(tr '\0' '\n' < /proc/${PPID}/environ | grep '^DISPLAY=' | cut -d= -f2- || true)
        fi
        if [[ -z "${DISPLAY:-}" ]]; then
            DISPLAY=":0"
            log "DISPLAY not set, defaulting to ${DISPLAY}"
        fi
        export DISPLAY
    fi

    # Ensure npm dependencies are installed
    # Prefer overlay's own node_modules (already installed), fall back to cache
    ELECTRON_BIN=""
    if [[ -f "$OVERLAY_ELECTRON" ]]; then
        ELECTRON_BIN="$OVERLAY_ELECTRON"
        log "Using overlay's own Electron: ${ELECTRON_BIN}"
    elif [[ -f "$CACHE_ELECTRON" ]]; then
        ELECTRON_BIN="$CACHE_ELECTRON"
        log "Using cached Electron: ${ELECTRON_BIN}"
    fi

    if [[ -z "$ELECTRON_BIN" ]]; then
        log "Electron not found, installing dependencies to cache..."
        mkdir -p "$CACHE_DIR"

        if [[ ! -f "$PACKAGE_JSON" ]]; then
            cat > "$PACKAGE_JSON" << 'PKGJSON'
{
  "name": "hermes-pet-overlay-linux-cache",
  "private": true,
  "version": "0.0.0",
  "dependencies": {
    "electron": "33.0.0",
    "ws": "8.18.0"
  }
}
PKGJSON
        fi

        if ! command -v npm &>/dev/null; then
            log "ERROR: npm not found. Please install Node.js/npm first."
            echo "ERROR: npm not found. Please install Node.js/npm first." >&2
            return 1
        fi

        if ! npm install --prefix "$CACHE_DIR" --no-audit --no-fund 2>&1; then
            log "ERROR: npm install failed"
            echo "ERROR: npm install failed. Check network connectivity and try again." >&2
            return 1
        fi

        if [[ -f "$CACHE_ELECTRON" ]]; then
            ELECTRON_BIN="$CACHE_ELECTRON"
            log "Cached Electron installed: ${ELECTRON_BIN}"
        fi
    fi

    if [[ -z "$ELECTRON_BIN" ]]; then
        log "ERROR: Electron binary not found"
        echo "ERROR: Electron binary not found. Run 'npm install' in the overlay directory or try again." >&2
        return 1
    fi

    # Prepare environment for Electron
    export HERMES_PET_PORT="${PORT}"
    export HERMES_PET_WS_URL="${HERMES_PET_WS_URL:-ws://127.0.0.1:${PORT}}"
    export HERMES_PET_PLATFORM="linux"

    # Forward known overlay env vars
    local forward_vars=(
        HERMES_PET_SPECIES
        HERMES_PET_POSITION_FILE
        HERMES_PET_DEBUG_ANIMATION
        HERMES_PET_DEBUG_DRAG
        HERMES_PET_DEBUG_EVENTS
        HERMES_PET_DEBUG_SPRITE
        HERMES_PET_ALWAYS_ON_TOP_LEVEL
        HERMES_PET_FOCUSABLE
        HERMES_PET_SHOW_UPLOAD
        HERMES_PET_CLICK_THROUGH
    )
    for var_name in "${forward_vars[@]}"; do
        if [[ -n "${!var_name:-}" ]]; then
            export "$var_name"
        fi
    done

    # Build Electron arguments
    local electron_args=()
    if [[ "${HERMES_PET_NO_SANDBOX:-}" != "1" ]]; then
        electron_args+=(--no-sandbox)
    fi
    electron_args+=("$MAIN_JS")

    # Launch Electron in background
    log "Launching Electron overlay..."
    log "  Binary: ${ELECTRON_BIN}"
    log "  Main JS: ${MAIN_JS}"
    log "  Working dir: ${OVERLAY_DIR}"
    log "  Bridge: ${HERMES_PET_WS_URL}"
    log "  DISPLAY: ${DISPLAY}"

    # Use setsid to create a new process group (detached from terminal)
    setsid "$ELECTRON_BIN" "${electron_args[@]}" \
        </dev/null \
        >/dev/null 2>&1 \
        &
    local launch_pid=$!

    # Give it a moment and verify it started
    sleep 1

    if ! kill -0 "$launch_pid" 2>/dev/null; then
        # Process already exited — check if it forked (Electron forks on startup)
        local child_pids
        child_pids=$(find_overlay_pids)
        if [[ -n "$child_pids" ]]; then
            echo "Hermes pet overlay started (overlay pid: $(echo "$child_pids" | head -1))"
        else
            log "ERROR: Electron process exited immediately"
            echo "ERROR: Electron overlay failed to start. Check Electron installation." >&2
            return 1
        fi
    else
        echo "Hermes pet overlay started (pid ${launch_pid})"
    fi

    echo "Electron cache: ${CACHE_DIR}"
    echo "Bridge URL: ${HERMES_PET_WS_URL}"
    return 0
}

# --- Parse arguments ---
MODE="start"
REPLACE="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --replace)
            REPLACE="1"
            shift
            ;;
        start|status|stop)
            MODE="$1"
            shift
            ;;
        *)
            echo "Usage: $0 [--replace] [start|status|stop]" >&2
            exit 1
            ;;
    esac
done

# --- Main ---
case "$MODE" in
    status)
        cmd_status
        ;;
    stop)
        cmd_stop
        ;;
    start)
        cmd_start
        ;;
    *)
        echo "Usage: $0 [--replace] [start|status|stop]" >&2
        exit 1
        ;;
esac
