#!/usr/bin/env sh
# Tests for .claude/hooks/supabase-ip-gate.sh: where it keeps its caches, which
# cache files it trusts, how old a stale list may be, and how wide an office
# network may be. curl is replaced by a stub, so nothing goes to the network.
#
#   sh scripts/supabase_ip_gate_test.sh        (also: bash, dash, zsh -o shwordsplit)
#
# Exits non-zero when a check fails.

here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/supabase-ip-gate.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/ip-gate-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

# The curl stub: the rules from $FAKE_RULES (fails when unset), addresses from
# $FAKE_IP4 / $FAKE_IP6; every URL asked for is logged to $CURL_LOG.
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env sh
for a in "$@"; do u="$a"; done
echo "$u" >> "$CURL_LOG"
case "$u" in
  */rest/v1/claude_access_rules*) [ -n "${FAKE_RULES:-}" ] || exit 22; printf '%s' "$FAKE_RULES" ;;
  *api.ipify.org*|*ipv4.icanhazip.com*) [ -n "${FAKE_IP4:-}" ] || exit 22; echo "$FAKE_IP4" ;;
  *api64.ipify.org*|*ipv6.icanhazip.com*) [ -n "${FAKE_IP6:-}" ] || exit 22; echo "$FAKE_IP6" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$work/bin/curl"

fails=0
pass=0
ok() { pass=$((pass + 1)); }
bad() { fails=$((fails + 1)); echo "FAILED: $1"; }
# check MESSAGE COMMAND...: passes when the command succeeds.
check() { m="$1"; shift; if "$@"; then ok; else bad "$m"; fi; }
not() { ! "$@"; }

# Runs the hook as a fresh user with home $work/home; the output lands in $out.
run() {
  out=$(env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="$work/tmp" \
    CLAUDE_PROJECT_DIR="$here" SUPABASE_URL=https://db.example.test SUPABASE_ANON_KEY=k \
    CURL_LOG="$work/curl.log" FAKE_RULES="${FAKE_RULES:-}" FAKE_IP4="${FAKE_IP4:-}" FAKE_IP6="${FAKE_IP6:-}" \
    CLAUDE_CODE_REMOTE="${REMOTE:-}" CLAUDE_CODE_REMOTE_SESSION_ID="${SID:-}" \
    ${XDG:+XDG_CACHE_HOME="$XDG"} sh "$hook")
}
allows() { case "$out" in *'"permissionDecision":"allow"'*) return 0 ;; esac; return 1; }
expect_allow() { if allows; then ok; else bad "$1 (got: ${out:-nothing})"; fi; }
expect_ask() { if allows; then bad "$1 (got: $out)"; else ok; fi; }
fetches() { grep -q "$1" "$work/curl.log" 2>/dev/null; }
reset() { rm -rf "${work:?}/home" "$work/tmp" "$work/xdg" "$work/curl.log"; mkdir -p "$work/home" "$work/tmp"; }
# The octal permission bits of [$1], on Linux (GNU stat) and macOS (BSD stat).
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

dir="$work/home/.cache/get-ride"
cache="$dir/claude-access-rules.cache"
ipcache="$dir/claude-public-ip.cache"
listed='[{"kind":"session","value":"cachedonly00000000000a1"},{"kind":"ip","value":"203.0.113.10"},{"kind":"ip","value":"2001:db8:5::/64"},{"kind":"ip","value":"198.51.0.0/16"},{"kind":"ip","value":"::/0"},{"kind":"ip","value":"::/48"}]'
now=$(date +%s)
REMOTE=true

# 1. A fetched list allows a listed cloud session; the cache is private, not in TMPDIR.
reset
FAKE_RULES="$listed" SID=cse_cachedonly00000000000a1 run
expect_allow "a session on the fetched list is allowed"
check "cache directory is 0700 (got $(mode "$dir"))" [ "$(mode "$dir")" = 700 ]
check "rules cache is 0600 (got $(mode "$cache"))" [ "$(mode "$cache")" = 600 ]
check "nothing is written to TMPDIR" [ -z "$(ls -A "$work/tmp")" ]
check "a cloud session looks up no address" not fetches ipify

# 2. A fresh cache is used without fetching.
rm -f "$work/curl.log"
SID=cachedonly00000000000a1 run
expect_allow "a fresh cache allows without fetching"
check "a fresh cache is not refetched" not fetches rest/v1

# 3. Fetching fails: a stale cache under a day old still counts.
printf '%s\n%s\n' $((now - 3600)) "$listed" > "$cache"
SID=cachedonly00000000000a1 run
expect_allow "an hour-old cache is used when fetching fails"
check "a stale cache is refetched first" fetches rest/v1

# 4. ... but not one over a day old: the built-in list then decides.
printf '%s\n%s\n' $((now - 90000)) "$listed" > "$cache"
SID=cachedonly00000000000a1 run
expect_ask "a cache over a day old is not used"
SID=01NDfeQQMcJvAnDpYN9Mwyb6 run
expect_allow "the built-in list applies once the cache is too old"

# 5. A cache dated in the future is neither fresh nor stale.
printf '%s\n%s\n' $((now + 100000)) "$listed" > "$cache"
SID=cachedonly00000000000a1 run
expect_ask "a cache dated in the future is ignored"

# 6. A cache that others may write is ignored.
printf '%s\n%s\n' "$now" "$listed" > "$cache"
chmod 666 "$cache"
SID=cachedonly00000000000a1 run
expect_ask "a world-writable cache is ignored"
chmod 620 "$cache"
SID=cachedonly00000000000a1 run
expect_ask "a group-writable cache is ignored"

# 7. ... and one that is a symlink.
rm -f "$cache"
printf '%s\n%s\n' "$now" "$listed" > "$work/elsewhere"
ln -s "$work/elsewhere" "$cache"
SID=cachedonly00000000000a1 run
expect_ask "a symlinked cache is ignored"
rm -f "$cache" "$work/elsewhere"

# 8. ... and one owned by someone else (needs root to set up).
if [ "$(id -u)" = 0 ] && id nobody >/dev/null 2>&1; then
  printf '%s\n%s\n' "$now" "$listed" > "$cache"
  chmod 600 "$cache"
  chown nobody "$cache"
  SID=cachedonly00000000000a1 run
  expect_ask "a cache owned by another user is ignored"
  # The next good fetch replaces it with one of our own.
  FAKE_RULES="$listed" SID=cachedonly00000000000a1 run
  check "a foreign cache is replaced on the next fetch" [ "$(find "$cache" -user 0 2>/dev/null)" = "$cache" ]
else
  echo "skipped: cache owned by another user (run as root to include)"
fi

# 9. A cache directory others may write is not used at all.
reset
mkdir -p "$dir"
chmod 777 "$dir"
FAKE_RULES="$listed" SID=cachedonly00000000000a1 run
expect_allow "with a writable cache directory the fetched list still counts"
check "the hook tightens its own cache directory to 0700" [ "$(mode "$dir")" = 700 ]
reset
mkdir -p "$work/home/.cache" "$work/shared"
chmod 777 "$work/shared"
ln -s "$work/shared" "$dir"
FAKE_RULES="$listed" SID=cachedonly00000000000a1 run
check "a symlinked cache directory is not written to" [ -z "$(ls -A "$work/shared")" ]

# 10. XDG_CACHE_HOME is honoured.
reset
XDG="$work/xdg" FAKE_RULES="$listed" SID=cachedonly00000000000a1 run
check "the cache goes under XDG_CACHE_HOME" [ -f "$work/xdg/get-ride/claude-access-rules.cache" ]
check "nothing goes under HOME/.cache when XDG_CACHE_HOME is set" [ ! -e "$dir" ]

# 11. Office addresses and networks (a local machine).
REMOTE=""
SID=""
reset
FAKE_RULES="$listed" FAKE_IP4=203.0.113.10 run
expect_allow "the listed office address is allowed"
check "address cache is 0600 (got $(mode "$ipcache"))" [ "$(mode "$ipcache")" = 600 ]
if command -v python3 >/dev/null 2>&1; then
  reset
  FAKE_RULES="$listed" FAKE_IP4=192.0.2.1 FAKE_IP6=2001:db8:5::77 run
  expect_allow "an address inside an office /64 is allowed"
  reset
  FAKE_RULES="$listed" FAKE_IP4=198.51.7.7 run
  expect_ask "a /16 office rule is too wide to match"
  reset
  FAKE_RULES="$listed" FAKE_IP4=192.0.2.1 FAKE_IP6=2001:db8:6::1 run
  expect_ask "::/0 is too wide to match"
  reset
  FAKE_RULES="$listed" FAKE_IP4=192.0.2.1 FAKE_IP6=::ffff:192.0.2.1 run
  expect_ask "a /48 over the IPv4-mapped range is too wide to match"
else
  echo "skipped: network rules (no python3)"
fi
reset
FAKE_RULES="$listed" FAKE_IP4=192.0.2.1 run
expect_ask "an address on no rule is asked about"
# A forged address cache others could write is not believed.
mkdir -p "$dir"
printf '%s 203.0.113.10 -\n' "$now" > "$ipcache"
chmod 666 "$ipcache"
FAKE_RULES="$listed" FAKE_IP4=192.0.2.1 run
expect_ask "a world-writable address cache is ignored"

echo "supabase-ip-gate: $pass passed, $fails failed"
[ "$fails" = 0 ]
