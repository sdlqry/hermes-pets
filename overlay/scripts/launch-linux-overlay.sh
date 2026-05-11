#!/usr/bin/env bash
# Linux native Overlay launcher (placeholder - will be enhanced in Phase 2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.hermes_pet"
PID_FILE="${STATE_DIR}/overlay.pid"

case "${1:-start}" in
    start)
        # Ensure DISPLAY is set
        export DISPLAY="${DISPLAY:-:0}"
        export HERMES_PET_PLATFORM=linux

        # Find electron binary
        ELECTRON_BIN=""
        for candidate in \
            "${SCRIPT_DIR}/../node_modules/.bin/electron" \
            "${SCRIPT_DIR}/../node_modules/electron/dist/electron" \
            "$(which electron 2>/dev/null || true)"; do
            if [[ -x "$candidate" ]]; then
                ELECTRON_BIN="$candidate"
                break
            fi
        done

        if [[ -z "$ELECTRON_BIN" ]]; then
            echo "Error: Electron not found. Run: cd overlay && npm install" >&2
            exit 1
        fi

        cd "${SCRIPT_DIR}/.."
        "$ELECTRON_BIN" src/main.js > /dev/null 2>&1 &
        echo $! > "$PID_FILE"
        echo "Overlay started (PID: $!)"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            PID=$(cat "$PID_FILE")
            kill "$PID" 2>/dev/null || true
            sleep 1
            kill -9 "$PID" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Overlay stopped"
        else
            # Fallback: find by process name
            pkill -f "electron.*main.js" 2>/dev/null || true
            echo "Overlay stopped (fallback)"
        fi
        ;;
    status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "Overlay: running (PID: $(cat "$PID_FILE"))"
        else
            echo "Overlay: not running"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
