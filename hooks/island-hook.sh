#!/bin/bash
# Dynamic Island Universal Hook
# Works with both Claude Code and GitHub Copilot
# Reads hook JSON from stdin, sends events to Dynamic Island

PORT="${DYNAMIC_ISLAND_PORT:-9423}"
URL="http://127.0.0.1:$PORT/event"

INPUT=$(cat)

# Extract project name from cwd
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$CWD" 2>/dev/null)

# agent_id/agent_type are present in Claude Code subagent hook payloads.
# We keep the project label as the parent (cwd basename) and pass agent fields
# separately so the island can track multiple concurrent subagents as their
# own channels while the compact ear still shows the latest-pinging one via
# a "↳ agent_type" override on the project label.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
DISPLAY_PROJECT="$PROJECT"
if [ -n "$AGENT_ID" ] && [ -n "$AGENT_TYPE" ]; then
    DISPLAY_PROJECT="↳ $AGENT_TYPE"
fi

send() {
    local payload="$1"
    if [ -n "$DISPLAY_PROJECT" ]; then
        payload=$(echo "$payload" | jq -c --arg p "$DISPLAY_PROJECT" '. + {project: $p}')
    fi
    if [ -n "$AGENT_ID" ]; then
        payload=$(echo "$payload" | jq -c --arg id "$AGENT_ID" --arg t "$AGENT_TYPE" '. + {agent_id: $id, agent_type: $t}')
    fi
    curl -s -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 &
}

basename_of() { echo "$1" | sed 's|.*/||'; }

truncate() {
    local str="$1" max="$2"
    if [ ${#str} -gt "$max" ]; then echo "${str:0:$max}…"; else echo "$str"; fi
}

# Trim a multi-line string to first N lines, each truncated to ~MAX chars,
# with each line prefixed by $1. Appends "  (+K more)" if lines were dropped.
diff_lines() {
    local prefix="$1" max_lines="${2:-5}" max_chars="${3:-80}"
    awk -v p="$prefix" -v maxl="$max_lines" -v maxc="$max_chars" '
        NR <= maxl {
            line = $0
            if (length(line) > maxc) line = substr(line, 1, maxc) "…"
            print p line
        }
        END {
            if (NR > maxl) print "  (+" (NR - maxl) " more)"
        }
    '
}

# Build a unified "- old / + new" preview from two multi-line strings.
# Emits plain text (newlines included); caller wraps in JSON via jq --arg.
build_edit_diff() {
    local old="$1" new="$2"
    local old_part new_part
    [ -n "$old" ] && old_part=$(printf '%s' "$old" | diff_lines "- ")
    [ -n "$new" ] && new_part=$(printf '%s' "$new" | diff_lines "+ ")
    if [ -n "$old_part" ] && [ -n "$new_part" ]; then
        printf '%s\n%s\n' "$old_part" "$new_part"
    elif [ -n "$old_part" ]; then
        printf '%s\n' "$old_part"
    elif [ -n "$new_part" ]; then
        printf '%s\n' "$new_part"
    fi
}

# ─── Detect source: Claude Code uses hook_event_name, Copilot uses toolName at root ───
CC_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CP_TOOL=$(echo "$INPUT" | jq -r '.toolName // empty')
CP_PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
CP_SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
CP_REASON=$(echo "$INPUT" | jq -r '.reason // empty')
CP_ERROR=$(echo "$INPUT" | jq -r '.error.message? // empty')

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
                OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""')
                NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
                # MultiEdit fallback — sniff first edit from the array
                if [ -z "$OLD_STR" ] && [ -z "$NEW_STR" ]; then
                    OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.edits[0].old_string // ""')
                    NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.edits[0].new_string // ""')
                fi
                DIFF=$(build_edit_diff "$OLD_STR" "$NEW_STR")
                PAYLOAD=$(jq -cn --arg s "${FNAME:-file}" --arg d "$DIFF" \
                    '{title:"Editing", subtitle:$s, style:"claude", duration:3} + (if $d == "" then {} else {detail:$d} end)')
                send "$PAYLOAD"
                ;;
            Write|create)
                FNAME=$(basename_of "$(get_file)")
                CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
                [ -z "$CONTENT" ] && CONTENT=$(echo "$INPUT" | jq -r '.toolArgs // empty' | jq -r '.content // ""' 2>/dev/null)
                DETAIL=""
                if [ -n "$CONTENT" ]; then
                    DETAIL=$(printf '%s' "$CONTENT" | diff_lines "+ ")
                fi
                PAYLOAD=$(jq -cn --arg s "${FNAME:-file}" --arg d "$DETAIL" \
                    '{title:"Writing", subtitle:$s, style:"claude", duration:3} + (if $d == "" then {} else {detail:$d} end)')
                send "$PAYLOAD"
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
        case "$TOOL" in
            Edit|Write|create)
                FNAME=$(basename_of "$(get_file)")
                send "{\"title\":\"Saved\",\"subtitle\":\"${FNAME:-file}\",\"style\":\"success\",\"duration\":1.5}"
                ;;
        esac
        ;;

    PostToolUseFailure)
        ERR=$(echo "$INPUT" | jq -r '.tool_error // .error // empty' | head -c 60)
        send "$(jq -cn --arg t "$TOOL" --arg e "$ERR" \
            '{title:"Tool failed",subtitle:(if $e!="" then $e else $t end),style:"error",duration:5}')"
        ;;

    PermissionDenied)
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "tool"')
        REASON=$(echo "$INPUT" | jq -r '.denial_reason // empty' | head -c 60)
        send "$(jq -cn --arg t "$TOOL_NAME" --arg r "$REASON" \
            '{title:"Denied",subtitle:(if $r!="" then $r else $t end),style:"warning",duration:4}')"
        ;;

    Notification)
        NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')
        MSG=$(echo "$INPUT" | jq -r '.message // "Notification"')
        # For permission prompts, skip — PermissionRequest hook will show real
        # Allow/Deny buttons. Showing a second event here would confuse the user
        # (fake buttons before real ones). For other types, use reminder
        # (pulsing ears, no buttons) since this hook can't capture a decision.
        if [ "$NOTIF_TYPE" = "permission_prompt" ]; then
            exit 0
        fi
        send "{\"title\":\"Claude Code\",\"subtitle\":\"$(truncate "$MSG" 45)\",\"style\":\"reminder\"}"
        ;;

    # ─── Permission request → show Allow/Deny, wait for response ──
    PermissionRequest)
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "tool"')
        TOOL_DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.file_path // ""' | head -c 40)

        # Send action event to island (will auto-expand with buttons)
        send "{\"title\":\"Permission\",\"subtitle\":\"$TOOL_NAME: $TOOL_DETAIL\",\"style\":\"action\"}"

        # Wait for user's choice (long-poll, up to 25s)
        RESPONSE=$(curl -s --max-time 26 "http://127.0.0.1:$PORT/response" 2>/dev/null)
        DECISION=$(echo "$RESPONSE" | jq -r '.decision // "timeout"')

        if [ "$DECISION" = "allow" ]; then
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        elif [ "$DECISION" = "deny" ]; then
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Dynamic Island"}}}'
        fi
        # timeout = no output = defer to normal Claude Code permission flow
        exit 0
        ;;

    StopFailure)
        send "{\"type\":\"thinking_stop\"}"
        ERR=$(echo "$INPUT" | jq -r '.stop_error // empty' | head -c 60)
        send "$(jq -cn --arg e "${ERR:-API error}" \
            '{title:"Error",subtitle:$e,style:"error",duration:6}')"
        ;;

    Stop)
        send "{\"type\":\"thinking_stop\"}"
        # Check if Claude is asking a question
        LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' | tail -c 200)
        if echo "$LAST_MSG" | grep -qE '\?$|\？$'; then
            send "{\"title\":\"Waiting\",\"subtitle\":\"Your turn\",\"style\":\"reminder\"}"
        else
            send "{\"title\":\"Done\",\"style\":\"success\",\"duration\":3}"
        fi
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
        # Close the subagent's channel in the island's session tree
        send "{\"type\":\"subagent_stop\"}"
        # Ephemeral "done" toast
        send "{\"title\":\"Agent done\",\"subtitle\":\"$AGENT_TYPE\",\"style\":\"success\",\"duration\":2}"
        ;;

    SessionStart)
        SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
        send "{\"title\":\"Session\",\"subtitle\":\"$SOURCE\",\"style\":\"info\",\"duration\":2}"
        ;;

    SessionEnd)
        send "{\"type\":\"thinking_stop\"}"
        ;;

    PreCompact)
        send "{\"title\":\"Compacting\",\"subtitle\":\"context\",\"style\":\"info\",\"duration\":2}"
        ;;

    PostCompact)
        send "{\"title\":\"Compacted\",\"style\":\"success\",\"duration\":2}"
        ;;

    UserPromptSubmit)
        send "{\"type\":\"thinking_start\"}"
        ;;

esac

exit 0
