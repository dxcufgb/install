#!/usr/bin/env bash
# Tests install.sh against a fake GitHub API (test/fake_github.py). Needs root (install.sh refuses otherwise),
# python3, curl, tar. Nothing outside a temporary folder is changed: the fake release's install.sh only writes
# a report file.
# pass/bad never fail, so "check && pass || bad" is safe here; cleanup runs from the EXIT trap.
# shellcheck disable=SC2015,SC2329
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/../install.sh"
T="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# make_release <dir> <name> <version> [corrupt]
make_release() {
  local dir="$1" top="$2-$3"
  mkdir -p "$dir/src/$top"
  cat >"$dir/src/$top/install.sh" <<EOF
#!/usr/bin/env bash
{ echo "args=\$*"; echo "token=\${INSTALL_GITHUB_TOKEN:-<none>}"; echo "pwd=\$(basename "\$PWD")"; } > "$dir/report"
EOF
  tar -czf "$dir/$top-linux.tar.gz" -C "$dir/src" "$top"
  (cd "$dir" && sha256sum "$top-linux.tar.gz" >SHA256SUMS.txt)
  if [ "${4:-}" = corrupt ]; then echo garbage >>"$dir/$top-linux.tar.gz"; fi
  printf '{"tag_name":"v%s","assets":[{"name":"%s-linux.tar.gz"},{"name":"SHA256SUMS.txt"}]}' "$3" "$top" \
    >"$dir/release.json"
}

port=18700
# start_server <dir> <private|public>  -> sets URL
start_server() {
  port=$((port + 1))
  python3 "$HERE/fake_github.py" "$port" "$1" "$2" &
  PIDS+=($!)
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
  URL="http://127.0.0.1:$port"
}

run() { # <url> <args...>; stdin from /dev/null (no terminal)
  local url="$1"; shift
  INSTALL_TEST_API_URL="$url" bash "$INSTALLER" "$@" </dev/null >"$T/out" 2>&1
}

# 1. --list and unknown names
list="$(bash "$INSTALLER" --list)"; grep -q comicsbot <<<"$list" && pass "--list" || bad "--list"
if run http://127.0.0.1:1 nosuchthing; then bad "unknown name accepted"; else grep -q "unknown name" "$T/out" && pass "unknown name refused" || bad "unknown name message"; fi

# 2. public repo, no token: installs and passes the options through
D="$T/public"; mkdir -p "$D"; make_release "$D" foundryvtt-discord-integration 1.4.0
start_server "$D" public
if run "$URL" foundryvtt-discord-integration --yes --auto-update; then
  grep -q '^args=--yes --auto-update$' "$D/report" && grep -q '^token=<none>$' "$D/report" &&
    grep -q '^pwd=foundryvtt-discord-integration-1.4.0$' "$D/report" && pass "public install" || bad "public install report"
else bad "public install failed: $(cat "$T/out")"; fi

# 3. private repo without a token and without a terminal: clear error, nothing run
D="$T/private"; mkdir -p "$D"; make_release "$D" comicsbot 2.4.0
start_server "$D" private
PRIV="$URL"
if run "$PRIV" comicsbot; then bad "private without token accepted"; else grep -q INSTALL_GITHUB_TOKEN "$T/out" && [ ! -e "$D/report" ] && pass "private needs a token" || bad "private token message"; fi

# 4. private repo, wrong token: 404 explained
if INSTALL_GITHUB_TOKEN=wrong run "$PRIV" comicsbot; then bad "wrong token accepted"; else grep -q "read access" "$T/out" && pass "wrong token explained" || bad "wrong token message: $(cat "$T/out")"; fi

# 5. private repo, right token: token reaches the installer in INSTALL_GITHUB_TOKEN, never on a command line
if INSTALL_GITHUB_TOKEN=test-token run "$PRIV" comicsbot --help; then
  grep -q '^token=test-token$' "$D/report" && grep -q '^args=--help$' "$D/report" && pass "private install with token" || bad "private report"
  grep -q test-token "$T/out" && bad "token printed" || pass "token not printed"
else bad "private install failed: $(cat "$T/out")"; fi

# 6. redirect to plain http is refused, and the token never went to the storage address
rm -f "$D/report"; echo "comicsbot-2.4.0-linux.tar.gz" >"$D/redirect-http"
if INSTALL_GITHUB_TOKEN=test-token run "$PRIV" comicsbot; then bad "http redirect accepted"; else
  grep -q "non-HTTPS" "$T/out" && [ ! -e "$D/report" ] && pass "http redirect refused" || bad "http redirect message: $(cat "$T/out")"; fi
grep -q '^/storage/.* auth$' "$D/auth.log" && bad "token sent to storage" || pass "no token to storage"
rm -f "$D/redirect-http"

# 7. checksum mismatch: refused, nothing run
D="$T/corrupt"; mkdir -p "$D"; make_release "$D" foundryvtt-discord-integration 1.4.1 corrupt
start_server "$D" public
if run "$URL" foundryvtt-discord-integration; then bad "corrupt archive accepted"; else grep -q "checksum mismatch" "$T/out" && [ ! -e "$D/report" ] && pass "checksum mismatch refused" || bad "checksum message"; fi

# 8. a release without the new file names: clear message
D="$T/old"; mkdir -p "$D"; make_release "$D" foundryvtt-discord-integration 1.3.2
printf '{"tag_name":"v1.3.2","assets":[{"name":"SHA256SUMS.txt"}]}' >"$D/release.json"
start_server "$D" public
if run "$URL" foundryvtt-discord-integration; then bad "old release accepted"; else grep -q "by hand" "$T/out" && pass "old release explained" || bad "old release message"; fi

# 9. an archive with a path outside the top folder: refused
D="$T/evil"; mkdir -p "$D/src/foundryvtt-discord-integration-1.5.0" "$D/src/other"
echo 'touch /tmp/should-not-exist' >"$D/src/foundryvtt-discord-integration-1.5.0/install.sh"; echo x >"$D/src/other/file"
tar -czf "$D/foundryvtt-discord-integration-1.5.0-linux.tar.gz" -C "$D/src" foundryvtt-discord-integration-1.5.0 other
(cd "$D" && sha256sum foundryvtt-discord-integration-1.5.0-linux.tar.gz >SHA256SUMS.txt)
printf '{"tag_name":"v1.5.0","assets":[{"name":"foundryvtt-discord-integration-1.5.0-linux.tar.gz"},{"name":"SHA256SUMS.txt"}]}' >"$D/release.json"
start_server "$D" public
if run "$URL" foundryvtt-discord-integration; then bad "escaping archive accepted"; else grep -q "unexpected path" "$T/out" && pass "escaping archive refused" || bad "escaping archive message"; fi

# 10. names differ only in case (GitHub matches release file names ignoring case): ComicsBot-2.4.0-linux.tar.gz
#     with top folder ComicsBot-2.4.0/ is found and installed for the name comicsbot
D="$T/case"; mkdir -p "$D"; make_release "$D" ComicsBot 2.4.0
start_server "$D" private
if INSTALL_GITHUB_TOKEN=test-token run "$URL" comicsbot --yes; then
  grep -q '^pwd=ComicsBot-2.4.0$' "$D/report" && pass "file name and top folder matched ignoring case" || bad "case report"
else bad "case install failed: $(cat "$T/out")"; fi

# 11. a top folder for another name or version: refused, nothing run
D="$T/wrongtop"; mkdir -p "$D"; make_release "$D" comicsbot 2.3.9
mv "$D/comicsbot-2.3.9-linux.tar.gz" "$D/comicsbot-2.4.0-linux.tar.gz"
(cd "$D" && sha256sum comicsbot-2.4.0-linux.tar.gz >SHA256SUMS.txt)
printf '{"tag_name":"v2.4.0","assets":[{"name":"comicsbot-2.4.0-linux.tar.gz"},{"name":"SHA256SUMS.txt"}]}' >"$D/release.json"
start_server "$D" private
if INSTALL_GITHUB_TOKEN=test-token run "$URL" comicsbot; then bad "wrong top folder accepted"; else
  grep -q "unexpected top folder" "$T/out" && [ ! -e "$D/report" ] && pass "wrong top folder refused" || bad "wrong top message: $(cat "$T/out")"; fi

# 12. no temporary folders left behind
ls -d /tmp/dxcufgb-install.* >/dev/null 2>&1 && bad "temporary folder left" || pass "temporary folders removed"

exit $fail
