#!/usr/bin/env sh
# PreToolUse hook for the Supabase MCP server.
#
# When this machine's public IP is the office address below, Supabase tool
# calls are approved without a prompt. From any other address the script
# prints nothing, so Claude Code asks for permission as usual. If the IP
# cannot be determined the script also prints nothing (fail closed).

ALLOWED_IP="202.188.231.237"
CACHE="${TMPDIR:-/tmp}/claude-public-ip-cache"
TTL=300  # seconds to reuse a looked-up IP before checking again

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

if [ "$ip" = "$ALLOWED_IP" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Session is running from the approved office IP %s"}}\n' "$ALLOWED_IP"
fi
exit 0
