#!/usr/bin/env sh
# PreToolUse hook for the Supabase MCP server (matcher mcp__Supabase__.*).
#
# Supabase tool calls are approved without a permission prompt when either
#   1. this is a Claude cloud session whose id is on the list, or
#   2. one of this machine's public addresses (IPv4, IPv6) is an office
#      address or inside an office network (CIDR) on the list.
# The list is Admin → Security & integrations → Claude Code access
# (public.claude_access_rules, migration 0228), read with the project's
# publishable key and cached for five minutes. When it cannot be fetched the
# last good copy is used, and failing that the built-in list below. In every
# other case the script prints nothing, so Claude Code asks as usual: it only
# ever fails closed, and always exits 0.
#
# Scope: a local Claude Code CLI honours this hook's decision, so an office
# machine gets no prompt. A Claude cloud session reads the list too, but the
# Supabase connector there asks on writes from its own tool-permission setting
# at claude.ai/customize/connectors, which no hook can override: set Execute
# SQL / Apply Migration to Allowed there for cloud sessions to stop prompting.
#
# POSIX sh only, no jq: it also runs on developers' own machines.

# Built-in fallback: the list as it stood when this file was last changed.
FALLBACK_IPS="202.188.231.237 2001:d08:1c01:6873::/64"
FALLBACK_SESSIONS="
01D5UkQNkT4wNjAS45j7F4ej
01NDfeQQMcJvAnDpYN9Mwyb6
01LUamzNaqHsLrMn92xVqEzH
017V7sMCRzpsywneJ3Sw3wHz
018jbhTQW6yVtn1tDDWjy2W1
"

TMP="${TMPDIR:-/tmp}"
RULES_CACHE="$TMP/claude-access-rules.cache"   # line 1: unix time written; rest: the JSON
IP_CACHE="$TMP/claude-public-ip-cache"         # "<unix time> <ipv4 or -> <ipv6 or ->"
TTL=300
now=$(date +%s)

allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# --- The list ---------------------------------------------------------------
project="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
config="$project/lib/src/config.dart"
url="${SUPABASE_URL:-}"
key="${SUPABASE_ANON_KEY:-}"
if [ -z "$url" ] && [ -r "$config" ]; then
  url=$(grep -A3 "'SUPABASE_URL'" "$config" | grep -o "https://[A-Za-z0-9.-]*" | head -1)
fi
if [ -z "$key" ] && [ -r "$config" ]; then
  key=$(grep -A4 "'SUPABASE_ANON_KEY'" "$config" | grep -o "'eyJ[A-Za-z0-9_.-]*'" | head -1 | tr -d "'")
fi

rules=""
if [ -r "$RULES_CACHE" ]; then
  ts=$(sed -n 1p "$RULES_CACHE")
  case "$ts" in
    ''|*[!0-9]*) ;;
    *) [ $((now - ts)) -lt "$TTL" ] && rules=$(sed 1d "$RULES_CACHE") ;;
  esac
fi
if [ -z "$rules" ] && [ -n "$url" ] && [ -n "$key" ]; then
  fetched=$(curl -fsS --max-time 4 -H "apikey: $key" -H "Authorization: Bearer $key" \
    "$url/rest/v1/claude_access_rules?select=kind,value&enabled=is.true" 2>/dev/null)
  case "$fetched" in
    "["*) rules="$fetched"; { echo "$now"; echo "$rules"; } > "$RULES_CACHE" 2>/dev/null ;;
  esac
fi
if [ -z "$rules" ] && [ -r "$RULES_CACHE" ]; then
  rules=$(sed 1d "$RULES_CACHE")   # a stale copy beats none
fi

if [ -n "$rules" ]; then
  sessions=$(printf '%s' "$rules" | tr '{' '\n' | grep '"kind":"session"' | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  ips=$(printf '%s' "$rules" | tr '{' '\n' | grep '"kind":"ip"' | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  source="the Claude Code access list"
else
  sessions="$FALLBACK_SESSIONS"
  ips="$FALLBACK_IPS"
  source="the built-in list"
fi

# --- 1. Approved cloud sessions ---------------------------------------------
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  sid="${CLAUDE_CODE_REMOTE_SESSION_ID#cse_}"
  [ -n "$sid" ] && for s in $sessions; do
    [ "$sid" = "$s" ] && allow "Cloud session $sid is on $source"
  done
  # Another cloud session: its address is never the office. Ask as usual.
  exit 0
fi

# --- 2. Office address or network -------------------------------------------
# Address [$1] is rule [$2] itself, or inside the network it names. A network
# needs python3 (its ipaddress module); without it only exact rules match.
in_rule() {
  [ "$1" = "$2" ] && return 0
  case "$2" in */*) ;; *) return 1 ;; esac
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
except Exception:
    sys.exit(1)
PY
}

# First answer among the given lookup services, else empty.
lookup() {
  for u in "$@"; do
    r=$(curl -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]')
    [ -n "$r" ] && { printf '%s' "$r"; return; }
  done
}

ip4=""; ip6=""
if [ -r "$IP_CACHE" ]; then
  read -r ts c4 c6 < "$IP_CACHE" 2>/dev/null
  case "$ts" in
    ''|*[!0-9]*) ;;
    *) [ $((now - ts)) -lt "$TTL" ] && { ip4="$c4"; ip6="$c6"; } ;;
  esac
fi
if [ -z "$ip4$ip6" ]; then
  ip4=$(lookup https://api.ipify.org https://ipv4.icanhazip.com)
  ip6=$(lookup https://api64.ipify.org https://ipv6.icanhazip.com)
  [ "$ip6" = "$ip4" ] && ip6=""
  [ -n "$ip4$ip6" ] && printf '%s %s %s\n' "$now" "${ip4:--}" "${ip6:--}" > "$IP_CACHE" 2>/dev/null
fi
for ip in $ip4 $ip6; do
  [ "$ip" = "-" ] && continue
  for o in $ips; do
    in_rule "$ip" "$o" && allow "Address $ip is in office rule $o on $source"
  done
done
exit 0
