#!/bin/bash
# Claude Code → Dynamic Island 小幫手
# Reads hook JSON from stdin, sends formatted events to Dynamic Island

PORT="${DYNAMIC_ISLAND_PORT:-9423}"
URL="http://localhost:$PORT/event"

# Read JSON from stdin
INPUT=$(cat)

send() {
    curl -s -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "$1" > /dev/null 2>&1 &
}

# Extract common fields
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Helper: shorten file path to just filename
basename_of() {
    echo "$1" | sed 's|.*/||'
}

# Helper: truncate string
truncate() {
    local str="$1" max="$2"
    if [ ${#str} -gt "$max" ]; then
        echo "${str:0:$max}…"
    else
        echo "$str"
    fi
}

case "$EVENT" in

    # ─── Before tool use ───────────────────────────────────
    PreToolUse)
        case "$TOOL" in
            Edit)
                FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"')
                FNAME=$(basename_of "$FILE")
                send "{\"title\":\"Editing\",\"subtitle\":\"$FNAME\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Write)
                FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"')
                FNAME=$(basename_of "$FILE")
                send "{\"title\":\"Writing\",\"subtitle\":\"$FNAME\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Read)
                FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"')
                FNAME=$(basename_of "$FILE")
                send "{\"title\":\"Reading\",\"subtitle\":\"$FNAME\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Bash)
                CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
                DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty')
                if [ -n "$DESC" ]; then
                    DISPLAY=$(truncate "$DESC" 35)
                else
                    DISPLAY=$(truncate "$CMD" 35)
                fi
                send "{\"title\":\"Terminal\",\"subtitle\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Grep)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""')
                DISPLAY=$(truncate "$PATTERN" 30)
                send "{\"title\":\"Searching\",\"subtitle\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Glob)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""')
                send "{\"title\":\"Finding files\",\"subtitle\":\"$PATTERN\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Agent)
                AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "agent"')
                DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty')
                DISPLAY=$(truncate "${DESC:-$AGENT_TYPE}" 35)
                send "{\"title\":\"Agent\",\"subtitle\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":3}"
                ;;
            WebSearch)
                send "{\"title\":\"Web Search\",\"style\":\"claude\",\"duration\":2}"
                ;;
            WebFetch)
                send "{\"title\":\"Fetching URL\",\"style\":\"claude\",\"duration\":2}"
                ;;
            TaskCreate|TaskUpdate)
                SUBJECT=$(echo "$INPUT" | jq -r '.tool_input.subject // .tool_input.status // ""')
                send "{\"title\":\"Task\",\"subtitle\":\"$SUBJECT\",\"style\":\"claude\",\"duration\":2}"
                ;;
            *)
                DISPLAY=$(echo "$TOOL" | sed 's/mcp__[^_]*__//')
                send "{\"title\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":2}"
                ;;
        esac
        ;;

    # ─── After tool use ────────────────────────────────────
    PostToolUse)
        case "$TOOL" in
            Bash)
                # Check if command failed (non-zero exit code in response)
                # Only show errors to avoid noise
                RESULT=$(echo "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null)
                if echo "$RESULT" | grep -qi "error\|failed\|exit code [1-9]"; then
                    CMD=$(echo "$INPUT" | jq -r '.tool_input.description // .tool_input.command // ""')
                    DISPLAY=$(truncate "$CMD" 30)
                    send "{\"title\":\"Command failed\",\"subtitle\":\"$DISPLAY\",\"style\":\"error\",\"duration\":4}"
                fi
                ;;
            Edit|Write)
                # Show brief success for file changes
                FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"')
                FNAME=$(basename_of "$FILE")
                send "{\"title\":\"Saved\",\"subtitle\":\"$FNAME\",\"style\":\"success\",\"duration\":1.5}"
                ;;
        esac
        ;;

    # ─── Notification (permission, idle, etc.) ─────────────
    Notification)
        MSG=$(echo "$INPUT" | jq -r '.message // "Notification"')
        DISPLAY=$(truncate "$MSG" 45)
        send "{\"title\":\"Claude Code\",\"subtitle\":\"$DISPLAY\",\"style\":\"warning\",\"duration\":6}"
        ;;

    # ─── Claude finished responding ────────────────────────
    Stop)
        send "{\"type\":\"thinking_stop\"}"
        send "{\"title\":\"Done\",\"style\":\"success\",\"duration\":3}"
        ;;

    # ─── Subagent lifecycle ────────────────────────────────
    SubagentStart)
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "agent"')
        send "{\"title\":\"Agent\",\"subtitle\":\"$AGENT_TYPE\",\"style\":\"claude\",\"duration\":3}"
        ;;

    SubagentStop)
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "agent"')
        send "{\"title\":\"Agent done\",\"subtitle\":\"$AGENT_TYPE\",\"style\":\"success\",\"duration\":2}"
        ;;

    # ─── Session start ─────────────────────────────────────
    SessionStart)
        SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
        send "{\"title\":\"Session\",\"subtitle\":\"$SOURCE\",\"style\":\"info\",\"duration\":2}"
        ;;

    # ─── User submitted prompt → start thinking pulse ──────
    UserPromptSubmit)
        send "{\"type\":\"thinking_start\"}"
        ;;

esac

exit 0
