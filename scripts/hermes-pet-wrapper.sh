#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hermes-pet-wrapper.sh — systemd wrapper for Hermes Pets
#
# Usage:
#   hermes-pet-wrapper.sh                 # Start bridge + overlay (foreground mode)
#   hermes-pet-wrapper.sh --overlay-only  # Start overlay only, then exit
#
# Under systemd:
#   - hermes-pet-bridge.service: runs bridge directly (Type=simple)
#   - hermes-pet-overlay.service: runs this script with --overlay-only (Type=oneshot)
# ---------------------------------------------------------------------------

set -euo pipefail

PROJECT_DIR="/home/ai-server/GitHubProjects/hermes-pets"
VENV_DIR="${PROJECT_DIR}/.venv"
BRIDGE_PY="${VENV_DIR}/bin/python"
OVERLAY_DIR="${PROJECT_DIR}/overlay"
ELECTRON_BIN="${OVERLAY_DIR}/node_modules/.bin/electron"
MAIN_JS="${OVERLAY_DIR}/src/main.js"
STATE_DIR="${HOME}/.local/share/hermes_pet"
LAUNCHER_SCRIPT="${OVERLAY_DIR}/scripts/launch-linux-overlay.sh"

PORT="${HERMES_PET_PORT:-17473}"
HOST="${HERMES_PET_HOST:-127.0.0.1}"

OVERLAY_ONLY=false
[[ "${1:-}" == "--overlay-only" ]] && OVERLAY_ONLY=true

# Ensure required env vars
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HERMES_PET_PORT="${PORT}"
export HERMES_PET_WS_URL="ws://${HOST}:${PORT}"
export HERMES_PET_PLATFORM="linux"
export HERMES_PET_DIR="${STATE_DIR}"
mkdir -p "${STATE_DIR}"

# ---------------------------------------------------------------------------
# launch_overlay_detached — Start Electron in a new session (for standalone
#                           or full mode). Does NOT wait for Electron to exit.
# launch_overlay_foreground — Start Electron as foreground process (for
#                             systemd Type=simple). Waits for Electron to exit.
# ---------------------------------------------------------------------------
launch_overlay_detached() {
    echo "[hermes-pet] Starting Electron overlay (detached)..."

    if [[ -x "${ELECTRON_BIN}" ]]; then
        setsid "${ELECTRON_BIN}" \
            --no-sandbox \
            --disable-gpu \
            --hermes-pet-platform=linux \
            --hermes-pet-dir="${STATE_DIR}" \
            --hermes-pet-bridge-port="${PORT}" \
            "${MAIN_JS}" \
            </dev/null >/dev/null 2>&1 &
        disown
        echo "[hermes-pet] Electron launch command dispatched"

        local retries=10
        local found=false
        while [[ $retries -gt 0 ]]; do
            sleep 1
            if pgrep -f "electron.*main.js" >/dev/null 2>&1 \
               || pgrep -f "hermes-pet" -u "$(id -u)" >/dev/null 2>&1 \
               || pgrep -f "main\\.js.*hermes-pet" >/dev/null 2>&1; then
                found=true
                break
            fi
            retries=$((retries - 1))
        done

        if [[ "${found}" == "true" ]]; then
            echo "[hermes-pet] Overlay started successfully"
            return 0
        fi

        echo "[hermes-pet] Overlay launch dispatched (could not confirm via pgrep)"
        return 0
    fi

    if [[ -x "${LAUNCHER_SCRIPT}" ]]; then
        "${LAUNCHER_SCRIPT}" start
        return $?
    fi

    echo "[hermes-pet] ERROR: Neither Electron binary nor launcher script found" >&2
    return 1
}

launch_overlay_foreground() {
    echo "[hermes-pet] Starting Electron overlay (foreground)..."

    if [[ -x "${ELECTRON_BIN}" ]]; then
        # Run Electron as foreground process — systemd manages lifecycle.
        # stdout/stderr go to journal for diagnostics.
        exec "${ELECTRON_BIN}" \
            --no-sandbox \
            --disable-gpu \
            --hermes-pet-platform=linux \
            --hermes-pet-dir="${STATE_DIR}" \
            --hermes-pet-bridge-port="${PORT}" \
            "${MAIN_JS}"
    fi

    echo "[hermes-pet] ERROR: Electron binary not found" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Overlay-only mode — for hermes-pet-overlay.service (Type=simple)
# Runs Electron as foreground process; systemd manages lifecycle.
# ---------------------------------------------------------------------------
if [[ "${OVERLAY_ONLY}" == "true" ]]; then
    launch_overlay_foreground
    exit $?
fi

# ---------------------------------------------------------------------------
# Full mode — bridge + overlay, for standalone use or combined service
# ---------------------------------------------------------------------------
BRIDGE_PID=""

cleanup() {
    echo "[hermes-pet] Shutting down..."
    # Stop overlay via launcher script
    if [[ -x "${LAUNCHER_SCRIPT}" ]]; then
        "${LAUNCHER_SCRIPT}" stop 2>/dev/null || true
    fi
    # Stop bridge
    if [[ -n "${BRIDGE_PID}" ]] && kill -0 "${BRIDGE_PID}" 2>/dev/null; then
        kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
        wait "${BRIDGE_PID}" 2>/dev/null || true
    fi
    rm -f "${STATE_DIR}/overlay.pid"
    echo "[hermes-pet] Cleanup complete"
    exit 0
}
trap cleanup EXIT SIGTERM SIGINT

launch_overlay_detached

echo "[hermes-pet] Starting bridge on ws://${HOST}:${PORT}..."
cd "${PROJECT_DIR}"
"${BRIDGE_PY}" -m hermes_pet.bridge --serve --port "${PORT}" --host "${HOST}" &
BRIDGE_PID=$!
wait "${BRIDGE_PID}"
echo "[hermes-pet] Bridge exited (code $?)"
