#!/usr/bin/env sh
# PreToolUse hook for the Supabase MCP server.
#
# Supabase tool calls are approved without a prompt when either:
#   1. this is a Claude cloud session whose ID is in ALLOWED_SESSIONS, or
#   2. this machine's public IP is the office address in ALLOWED_IP.
# In every other case the script prints nothing, so Claude Code asks for
# permission as usual. If the IP cannot be determined it also prints
# nothing (fail closed).

ALLOWED_IP="202.188.231.237"

# Cloud session IDs, as they appear in the claude.ai/code/session_<id> URL
# without the "session_" prefix. One per line.
ALLOWED_SESSIONS="
01D5UkQNkT4wNjAS45j7F4ej
01NDfeQQMcJvAnDpYN9Mwyb6z
01LUamzNaqHsLrMn92xVqEzH
017V7sMCRzpsywneJ3Sw3wHz
018jbhTQW6yVtn1tDDWjy2W1
"

CACHE="${TMPDIR:-/tmp}/claude-public-ip-cache"
TTL=300  # seconds to reuse a looked-up IP before checking again

allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# --- 1. Approved cloud sessions -------------------------------------------
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  sid="${CLAUDE_CODE_REMOTE_SESSION_ID#cse_}"
  for s in $ALLOWED_SESSIONS; do
    [ "$sid" = "$s" ] && allow "Approved cloud session $sid"
  done
  # Other cloud sessions never match the office IP; fall through to the prompt.
  exit 0
fi

# --- 2. Office IP ----------------------------------------------------------
now=$(date +%s)
ip=""

if [ -r "$CACHE" ]; then
  read -r ts cached < "$CACHE" 2>/dev/null
  case "$ts" in
    ''|*[!0-9]*) ;;
    *) [ $((now - ts)) -lt "$TTL" ] && ip="$cached" ;;
  esac
fi

if [ -z "$ip" ]; then
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
    [ -n "$ip" ] && break
  done
  [ -n "$ip" ] && printf '%s %s\n' "$now" "$ip" > "$CACHE" 2>/dev/null
fi

[ "$ip" = "$ALLOWED_IP" ] && allow "Session is running from the approved office IP $ALLOWED_IP"
exit 0
