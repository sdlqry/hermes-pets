#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hermes-hook-bridge.sh — Hermes Agent → Hermes Pets emotion-aware bridge
# ---------------------------------------------------------------------------
# Reads JSON from stdin (Hermes shell hook wire protocol), detects the
# emotional tone of the event (tool calls, LLM responses, session lifecycle),
# and forwards a mapped pet event to the running hermes-pet bridge via
# hermes-pet-bridge --emit-json.
#
# Wire protocol (stdin):
#   {
#     "hook_event_name": "post_tool_call",
#     "tool_name": "terminal",
#     "tool_input": {"command": "..."},
#     "session_id": "sess_abc123",
#     "cwd": "/home/user/project",
#     "extra": { ... }
#   }
#
# See: https://hermes-agent.nousresearch.com/docs/hooks
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
HERMES_PET_PROJECT_DIR="${HERMES_PET_PROJECT_DIR:-/home/ai-server/GitHubProjects/hermes-pets}"
HERMES_PET_VENV="${HERMES_PET_VENV:-${HERMES_PET_PROJECT_DIR}/.venv}"
BRIDGE_PORT="${HERMES_PET_PORT:-17473}"
BRIDGE_HOST="${HERMES_PET_HOST:-127.0.0.1}"
BRIDGE_BIN="${HERMES_PET_VENV}/bin/hermes-pet-bridge"

# Emoji patterns for emotion detection (simple keyword matching, no NLP needed)
readonly SUCCESS_PATTERNS='success|done|completed|完成|成功|passed|ok$|works|verified'
readonly ERROR_PATTERNS='error|failed|failure|失败|错误|exception|traceback|segfault|killed|denied|forbidden'
readonly WARNING_PATTERNS='warning|warn|caution|警告|注意|deprecated|timeout|retry|refused'
readonly THINKING_TOOLS='web_search|browser_|read_file|search_files|codebase_inspection'
readonly CODING_TOOLS='terminal|execute_code|write_file|patch|terminal\(background'
readonly DANGEROUS_TOOLS='bash|curl|wget|rm |sudo|chmod|chown|systemctl|docker|kubectl'

# ── Logging (stderr only — stdout must be empty or valid JSON) ────────────
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[hermes-hook-bridge] $*" >&2; true; }
log_warn()  { echo "[hermes-hook-bridge] WARN: $*" >&2; true; }
log_error() { echo "[hermes-hook-bridge] ERROR: $*" >&2; true; }

# ── JSON helpers (bash-native, no jq dependency) ──────────────────────────
# Extract a top-level string value from JSON. Returns empty if not found.
# Usage: json_extract_string '{"key": "value"}' "key"
json_extract_string() {
    local json="$1" key="$2"
    # Match "key": "value" pattern — handles escaped quotes within value
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Extract a top-level boolean or string value (unquoted).
json_extract_value() {
    local json="$1" key="$2"
    # Try string first
    local str_val
    str_val=$(json_extract_string "$json" "$key")
    if [[ -n "$str_val" ]]; then
        echo "$str_val"
        return
    fi
    # Try unquoted value (boolean, number)
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([^\",}]\+\).*/\1/p" | head -1 | tr -d '[:space:]'
}

# Check if a JSON string contains a given substring (for nested field search)
json_contains() {
    local json="$1" pattern="$2"
    echo "$json" | grep -qi "$pattern"
}

# ── Emotion detection ─────────────────────────────────────────────────────
# Analyze text and return: positive | negative | warning | neutral
detect_emotion() {
    local text="$1"

    if echo "$text" | grep -qiE "$ERROR_PATTERNS"; then
        echo "negative"
    elif echo "$text" | grep -qiE "$WARNING_PATTERNS"; then
        echo "warning"
    elif echo "$text" | grep -qiE "$SUCCESS_PATTERNS"; then
        echo "positive"
    else
        echo "neutral"
    fi
}

# Detect emotion from LLM response text.
# Looks at the last ~500 chars for conclusion sentiment.
detect_response_emotion() {
    local response="$1"
    # Take the tail of the response — conclusions are usually at the end
    local tail_text
    tail_text=$(echo "$response" | tail -c 500)

    if echo "$tail_text" | grep -qiE "$ERROR_PATTERNS"; then
        echo "negative"
    elif echo "$tail_text" | grep -qiE "$WARNING_PATTERNS"; then
        echo "warning"
    elif echo "$tail_text" | grep -qiE "$SUCCESS_PATTERNS"; then
        echo "positive"
    else
        echo "neutral"
    fi
}

# ── Tool categorization ───────────────────────────────────────────────────
# Returns a human-readable category for display in pet bubble text
categorize_tool() {
    local tool="$1"
    if echo "$tool" | grep -qiE "$CODING_TOOLS"; then
        echo "coding"
    elif echo "$tool" | grep -qiE "$THINKING_TOOLS"; then
        echo "researching"
    elif echo "$tool" | grep -qiE "$DANGEROUS_TOOLS"; then
        echo "system"
    elif echo "$tool" | grep -qi "file\|write\|patch\|edit"; then
        echo "editing"
    elif echo "$tool" | grep -qi "memory\|session_search\|cron"; then
        echo "organizing"
    elif echo "$tool" | grep -qi "delegate\|subagent"; then
        echo "delegating"
    elif echo "$tool" | grep -qi "browser\|vision"; then
        echo "browsing"
    else
        echo "working"
    fi
}

# ── Pet event emitter ─────────────────────────────────────────────────────
# Send a JSON event to the hermes-pet bridge.
# Usage: emit_pet_event '{"type": "bubble", "text": "..."}'
emit_pet_event() {
    local event_json="$1"

    if [[ ! -x "$BRIDGE_BIN" ]]; then
        log_error "bridge binary not found: $BRIDGE_BIN"
        return 1
    fi

    log_debug "emitting: $event_json"
    "$BRIDGE_BIN" --emit-json "$event_json" --port "$BRIDGE_PORT" --host "$BRIDGE_HOST" 2>/dev/null
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_debug "event sent successfully"
    else
        log_warn "bridge returned exit code $rc (bridge may not be running)"
    fi
    return $rc
}

# ── Event handlers ────────────────────────────────────────────────────────

handle_pre_tool_call() {
    local event_json="$1"
    local tool_name
    tool_name=$(json_extract_string "$event_json" "tool_name")

    if [[ -z "$tool_name" ]]; then
        return
    fi

    local category
    category=$(categorize_tool "$tool_name")

    # Show thinking bubble for research, running for coding
    if [[ "$category" == "researching" ]]; then
        emit_pet_event "{\"type\": \"bubble\", \"text\": \"🔍 Looking things up...\"}"
    elif [[ "$category" == "coding" ]]; then
        emit_pet_event "{\"type\": \"job_started\", \"text\": \"Running ${tool_name}...\"}"
    elif [[ "$category" == "delegating" ]]; then
        emit_pet_event "{\"type\": \"bubble\", \"text\": \"📋 Delegating tasks...\"}"
    elif [[ "$category" == "system" ]]; then
        emit_pet_event "{\"type\": \"status\", \"text\": \"⚠️ System operation: ${tool_name}\", \"severity\": \"warning\"}"
    fi
}

handle_post_tool_call() {
    local event_json="$1"
    local tool_name tool_output
    tool_name=$(json_extract_string "$event_json" "tool_name")
    tool_output=$(json_extract_string "$event_json" "tool_output" 2>/dev/null || true)

    if [[ -z "$tool_name" ]]; then
        return
    fi

    # Check tool output for errors (limited to first 1000 chars for speed)
    local sample="${tool_output:0:1000}"
    local emotion
    emotion=$(detect_emotion "$sample")

    case "$emotion" in
        negative)
            emit_pet_event "{\"type\": \"job_failed\", \"text\": \"${tool_name} hit an error\"}"
            ;;
        warning)
            emit_pet_event "{\"type\": \"bubble\", \"text\": \"⚠️ Something needs attention...\"}"
            ;;
        positive)
            emit_pet_event "{\"type\": \"job_finished\", \"text\": \"${tool_name} succeeded\"}"
            ;;
        *)
            # Neutral — just show brief status
            local category
            category=$(categorize_tool "$tool_name")
            case "$category" in
                researching) emit_pet_event "{\"type\": \"bubble\", \"text\": \"📖 Found some info\"}" ;;
                editing)    emit_pet_event "{\"type\": \"job_finished\", \"text\": \"File updated\"}" ;;
                *)          ;; # Skip neutral tool results to avoid spam
            esac
            ;;
    esac
}

handle_pre_llm_call() {
    local event_json="$1"
    local user_message
    user_message=$(json_extract_string "$event_json" "user_message")

    if [[ -n "$user_message" && ${#user_message} -gt 2 ]]; then
        # Truncate long messages for the bubble
        local display_msg="${user_message:0:60}"
        if [[ ${#user_message} -gt 60 ]]; then
            display_msg="${display_msg}..."
        fi
        emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"thinking\"}"
        emit_pet_event "{\"type\": \"bubble\", \"text\": \"💭 $display_msg\"}"
    else
        emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"thinking\"}"
    fi
}

handle_post_llm_call() {
    local event_json="$1"
    local response
    response=$(json_extract_string "$event_json" "assistant_response" 2>/dev/null || true)

    if [[ -z "$response" ]]; then
        emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"idle\"}"
        return
    fi

    # Analyze the emotional tone of the response
    local emotion
    emotion=$(detect_response_emotion "$response")

    # Extract a brief summary from the response (last sentence or key phrase)
    local summary=""
    # Try to get the last meaningful line (often a conclusion)
    summary=$(echo "$response" | grep -v '^$' | tail -5 | head -1 | cut -c1-80)

    case "$emotion" in
        positive)
            emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"happy\"}"
            if [[ -n "$summary" ]]; then
                emit_pet_event "{\"type\": \"bubble\", \"text\": \"✅ $summary\"}"
            else
                emit_pet_event "{\"type\": \"job_finished\", \"text\": \"Task completed\"}"
            fi
            ;;
        negative)
            emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"sad\"}"
            emit_pet_event "{\"type\": \"job_failed\", \"text\": \"Something went wrong\"}"
            ;;
        warning)
            emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"thinking\"}"
            emit_pet_event "{\"type\": \"bubble\", \"text\": \"⚠️ Check the details...\"}"
            ;;
        neutral)
            emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"idle\"}"
            # Don't spam bubble for neutral responses
            ;;
    esac
}

handle_on_session_start() {
    local event_json="$1"
    local model platform
    model=$(json_extract_string "$event_json" "model")
    platform=$(json_extract_string "$event_json" "platform")

    local greeting="👋 Session started"
    [[ -n "$model" ]] && greeting="$greeting (${model})"
    [[ -n "$platform" ]] && greeting="$greeting via $platform"

    emit_pet_event "{\"type\": \"bubble\", \"text\": \"$greeting\"}"
    emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"happy\"}"
}

handle_on_session_end() {
    local event_json="$1"
    local completed interrupted
    completed=$(json_extract_value "$event_json" "completed")
    interrupted=$(json_extract_value "$event_json" "interrupted")

    if [[ "$interrupted" == "True" || "$interrupted" == "true" ]]; then
        emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"sad\"}"
        emit_pet_event "{\"type\": \"bubble\", \"text\": \"👋 Session interrupted\"}"
    else
        emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"happy\"}"
        emit_pet_event "{\"type\": \"bubble\", \"text\": \"🎉 Session complete!\"}"
    fi
}

handle_post_approval_response() {
    local event_json="$1"
    local choice
    choice=$(json_extract_string "$event_json" "choice")

    case "$choice" in
        once|session|always)
            emit_pet_event "{\"type\": \"approval_needed\", \"text\": \"✅ Approved\"}"
            ;;
        deny)
            emit_pet_event "{\"type\": \"job_failed\", \"text\": \"🚫 Command denied\"}"
            ;;
        timeout)
            emit_pet_event "{\"type\": \"bubble\", \"text\": \"⏰ Approval timed out\"}"
            ;;
    esac
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    # Read hook payload from stdin
    local stdin_json=""
    if [[ ! -t 0 ]]; then
        stdin_json=$(cat)
    fi

    if [[ -z "$stdin_json" ]]; then
        log_debug "no stdin data, exiting"
        exit 0
    fi

    # Validate it looks like JSON
    if ! echo "$stdin_json" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
        log_warn "stdin is not valid JSON, ignoring"
        exit 0
    fi

    local hook_event
    hook_event=$(json_extract_string "$stdin_json" "hook_event_name")

    if [[ -z "$hook_event" ]]; then
        log_debug "no hook_event_name found, ignoring"
        exit 0
    fi

    log_debug "received hook: $hook_event"

    # Dispatch to handler
    case "$hook_event" in
        pre_tool_call)
            handle_pre_tool_call "$stdin_json"
            ;;
        post_tool_call)
            handle_post_tool_call "$stdin_json"
            ;;
        pre_llm_call)
            handle_pre_llm_call "$stdin_json"
            ;;
        post_llm_call)
            handle_post_llm_call "$stdin_json"
            ;;
        on_session_start)
            handle_on_session_start "$stdin_json"
            ;;
        on_session_end)
            handle_on_session_end "$stdin_json"
            ;;
        on_session_reset)
            emit_pet_event "{\"type\": \"bubble\", \"text\": \"🔄 Session reset\"}"
            ;;
        on_session_finalize)
            emit_pet_event "{\"type\": \"mood_change\", \"mood\": \"idle\"}"
            ;;
        post_approval_response)
            handle_post_approval_response "$stdin_json"
            ;;
        pre_approval_request)
            emit_pet_event "{\"type\": \"approval_needed\", \"text\": \"❓ Needs your approval\"}"
            ;;
        post_api_request)
            # Skip — too frequent, use post_llm_call instead
            ;;
        subagent_stop)
            emit_pet_event "{\"type\": \"job_finished\", \"text\": \"Subagent done\"}"
            ;;
        *)
            log_debug "unhandled hook event: $hook_event"
            ;;
    esac

    # IMPORTANT: stdout must be empty (or valid hook response JSON).
    # Pet bridge events are sent via hermes-pet-bridge CLI, not stdout.
    exit 0
}

main "$@"
