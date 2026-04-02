#!/bin/bash
# Dynamic Island Universal Hook
# Works with both Claude Code and GitHub Copilot
# Reads hook JSON from stdin, sends events to Dynamic Island

PORT="${DYNAMIC_ISLAND_PORT:-9423}"
URL="http://127.0.0.1:$PORT/event"

INPUT=$(cat)

send() {
    curl -s -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "$1" > /dev/null 2>&1 &
}

basename_of() { echo "$1" | sed 's|.*/||'; }

truncate() {
    local str="$1" max="$2"
    if [ ${#str} -gt "$max" ]; then echo "${str:0:$max}…"; else echo "$str"; fi
}

# ─── Detect source: Claude Code uses hook_event_name, Copilot uses toolName at root ───
CC_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CP_TOOL=$(echo "$INPUT" | jq -r '.toolName // empty')
CP_PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
CP_SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
CP_REASON=$(echo "$INPUT" | jq -r '.reason // empty')
CP_ERROR=$(echo "$INPUT" | jq -r '.error.message // empty')

# ─── Normalize to a common event + tool ───
if [ -n "$CC_EVENT" ]; then
    # Claude Code
    EVENT="$CC_EVENT"
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
else
    # GitHub Copilot — detect event type from available fields
    if [ -n "$CP_TOOL" ]; then
        # Has toolName → pre or post tool use
        RESULT_TYPE=$(echo "$INPUT" | jq -r '.toolResult.resultType // empty')
        if [ -n "$RESULT_TYPE" ]; then
            EVENT="PostToolUse"
        else
            EVENT="PreToolUse"
        fi
        TOOL="$CP_TOOL"
    elif [ -n "$CP_ERROR" ]; then
        EVENT="Error"
    elif [ -n "$CP_REASON" ]; then
        EVENT="Stop"
    elif [ -n "$CP_SOURCE" ]; then
        EVENT="SessionStart"
    elif [ -n "$CP_PROMPT" ]; then
        EVENT="UserPromptSubmit"
    else
        exit 0
    fi
fi

# ─── Helper: extract file path from either format ───
get_file() {
    local f
    # Claude Code: .tool_input.file_path
    f=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [ -z "$f" ]; then
        # Copilot: toolArgs is a JSON string, parse it
        f=$(echo "$INPUT" | jq -r '.toolArgs // empty' | jq -r '.file_path // .path // .filePath // empty' 2>/dev/null)
    fi
    echo "$f"
}

# ─── Helper: extract command from either format ───
get_command() {
    local c
    c=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    if [ -z "$c" ]; then
        c=$(echo "$INPUT" | jq -r '.toolArgs // empty' | jq -r '.command // empty' 2>/dev/null)
    fi
    echo "$c"
}

# ─── Normalize tool names (Copilot uses lowercase) ───
case "$TOOL" in
    edit|Edit)       TOOL="Edit" ;;
    create|Write)    TOOL="Write" ;;
    view|Read)       TOOL="Read" ;;
    bash|Bash)       TOOL="Bash" ;;
    grep|Grep)       TOOL="Grep" ;;
    glob|Glob)       TOOL="Glob" ;;
    agent|Agent)     TOOL="Agent" ;;
esac

# ─── Handle events ────────────────────────────────────────

case "$EVENT" in

    PreToolUse)
        case "$TOOL" in
            Edit)
                FNAME=$(basename_of "$(get_file)")
                send "{\"title\":\"Editing\",\"subtitle\":\"${FNAME:-file}\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Write|create)
                FNAME=$(basename_of "$(get_file)")
                send "{\"title\":\"Writing\",\"subtitle\":\"${FNAME:-file}\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Read|view)
                FNAME=$(basename_of "$(get_file)")
                send "{\"title\":\"Reading\",\"subtitle\":\"${FNAME:-file}\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Bash)
                CMD=$(get_command)
                DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty')
                DISPLAY=$(truncate "${DESC:-$CMD}" 35)
                send "{\"title\":\"Terminal\",\"subtitle\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":3}"
                ;;
            Grep)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
                [ -z "$PATTERN" ] && PATTERN=$(echo "$INPUT" | jq -r '.toolArgs // empty' | jq -r '.pattern // empty' 2>/dev/null)
                send "{\"title\":\"Searching\",\"subtitle\":\"$(truncate "$PATTERN" 30)\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Glob)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
                [ -z "$PATTERN" ] && PATTERN=$(echo "$INPUT" | jq -r '.toolArgs // empty' | jq -r '.pattern // empty' 2>/dev/null)
                send "{\"title\":\"Finding files\",\"subtitle\":\"$PATTERN\",\"style\":\"claude\",\"duration\":2}"
                ;;
            Agent)
                DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty')
                AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "agent"')
                send "{\"title\":\"Agent\",\"subtitle\":\"$(truncate "${DESC:-$AGENT_TYPE}" 35)\",\"style\":\"claude\",\"duration\":3}"
                ;;
            *)
                DISPLAY=$(echo "$TOOL" | sed 's/mcp__[^_]*__//')
                send "{\"title\":\"$DISPLAY\",\"style\":\"claude\",\"duration\":2}"
                ;;
        esac
        ;;

    PostToolUse)
        # Check for failure
        RESULT_TYPE=$(echo "$INPUT" | jq -r '.toolResult.resultType // empty')
        if [ "$RESULT_TYPE" = "failure" ] || [ "$RESULT_TYPE" = "denied" ]; then
            send "{\"title\":\"Failed\",\"subtitle\":\"$TOOL\",\"style\":\"error\",\"duration\":4}"
        else
            case "$TOOL" in
                Bash)
                    RESULT=$(echo "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null)
                    if echo "$RESULT" | grep -qi "error\|failed\|exit code [1-9]"; then
                        CMD=$(echo "$INPUT" | jq -r '.tool_input.description // .tool_input.command // ""')
                        send "{\"title\":\"Command failed\",\"subtitle\":\"$(truncate "$CMD" 30)\",\"style\":\"error\",\"duration\":4}"
                    fi
                    ;;
                Edit|Write|create)
                    FNAME=$(basename_of "$(get_file)")
                    send "{\"title\":\"Saved\",\"subtitle\":\"${FNAME:-file}\",\"style\":\"success\",\"duration\":1.5}"
                    ;;
            esac
        fi
        ;;

    Notification)
        MSG=$(echo "$INPUT" | jq -r '.message // "Notification"')
        send "{\"title\":\"Action needed\",\"subtitle\":\"$(truncate "$MSG" 45)\",\"style\":\"action\"}"
        ;;

    Stop)
        send "{\"type\":\"thinking_stop\"}"
        send "{\"title\":\"Done\",\"style\":\"success\",\"duration\":3}"
        ;;

    Error)
        send "{\"type\":\"thinking_stop\"}"
        send "{\"title\":\"Error\",\"subtitle\":\"$(truncate "$CP_ERROR" 35)\",\"style\":\"error\",\"duration\":5}"
        ;;

    SubagentStart)
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "agent"')
        send "{\"title\":\"Agent\",\"subtitle\":\"$AGENT_TYPE\",\"style\":\"claude\",\"duration\":3}"
        ;;

    SubagentStop)
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "agent"')
        send "{\"title\":\"Agent done\",\"subtitle\":\"$AGENT_TYPE\",\"style\":\"success\",\"duration\":2}"
        ;;

    SessionStart)
        SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
        send "{\"title\":\"Session\",\"subtitle\":\"$SOURCE\",\"style\":\"info\",\"duration\":2}"
        ;;

    UserPromptSubmit)
        send "{\"type\":\"thinking_start\"}"
        ;;

esac

exit 0
