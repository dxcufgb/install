#!/usr/bin/env bash
# Installs one of dxcufgb's bots/services on Linux from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/dxcufgb/install/main/install.sh | sudo bash -s <name> [options]
#
# <name> is one of the names listed by --list (e.g. comicsbot). Everything after it goes to that release's own
# install.sh (for example --yes, --auto-update, --help).
#
# What it does:
#   1. asks GitHub for the latest release of the repository (drafts and pre-releases are never "latest");
#   2. downloads <name>-<version>-linux.tar.gz and SHA256SUMS.txt from it and checks the archive's SHA-256;
#   3. unpacks it into a new temporary folder and runs <name>-<version>/install.sh as root;
#   4. deletes the temporary folder.
#
# Private repositories need a fine-grained GitHub token with read-only "Contents" access to that repository.
# It is read from the environment variable INSTALL_GITHUB_TOKEN or asked for (input hidden). It is sent only to
# api.github.com (never to the storage server GitHub redirects downloads to), never put on a command line or in
# a log, and handed to the release's installer in INSTALL_GITHUB_TOKEN so it can offer to use it for automatic
# updates.
set -euo pipefail
umask 077

# name | GitHub repository | private (1) or public (0)
PRODUCTS="
twitchdiscordbot|dxcufgb/TwitchDiscordBot|1
comicsbot|dxcufgb/DiscordComicsBot|1
foundryvtt-discord-integration|dxcufgb/FoundryVTT-discord-integration|0
foundry-release-proxy|dxcufgb/FoundryVTT-Private-Github-proxy|1
"

API="https://api.github.com"
# Tests only: point at a fake API (plain http allowed there). Never set this for a real install.
if [ -n "${INSTALL_TEST_API_URL:-}" ]; then API="$INSTALL_TEST_API_URL"; fi
MAX_BYTES=$((300 * 1024 * 1024))

die() { echo "install: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

usage() {
  cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/dxcufgb/install/main/install.sh | sudo bash -s <name> [options]

  <name>     what to install (see --list)
  [options]  passed to the release's own install.sh, e.g. --yes, --auto-update, --uninstall, --help

  --list     show the names
EOF
}

list_products() {
  local name repo private
  while IFS='|' read -r name repo private; do
    [ -n "$name" ] || continue
    if [ "$private" = 1 ]; then printf '  %-32s %s (private: needs a token)\n' "$name" "$repo"
    else printf '  %-32s %s\n' "$name" "$repo"; fi
  done <<<"$PRODUCTS"
}

# Reads a JSON document on stdin and prints what the expression asks for. python3 or jq, whichever exists.
json_latest() { # prints: tag_name
  if command -v python3 >/dev/null; then
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
  else
    jq -er '.tag_name'
  fi
}
# GitHub treats release file names as case-insensitive (a release cannot hold both ComicsBot-1.0.0-x and
# comicsbot-1.0.0-x), so names are matched ignoring case.
json_asset() { # $1 = asset name; prints "<API URL> <name as published>", nothing if absent, fails if ambiguous
  if command -v python3 >/dev/null; then
    python3 -I -c 'import json,sys
hits = [a for a in json.load(sys.stdin).get("assets", []) if a.get("name", "").lower() == sys.argv[1].lower()]
if len(hits) > 1: sys.exit("more than one release file is called " + sys.argv[1])
for a in hits: print(a["url"], a["name"])' "$1"
  else
    jq -er --arg n "$1" '[.assets[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))]
      | if length > 1 then error("more than one release file is called " + $n) else (.[] | "\(.url) \(.name)") end' || true
  fi
}

# curl with the token as a header, fed through a config file on stdin so it never shows up in `ps`.
api_curl() { # args: curl options...
  if [ -n "$TOKEN" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl --config - "$@"
  else
    curl "$@"
  fi
}

# Downloads a release asset through the API. GitHub answers with a redirect to its storage server; that second
# request is made without the token.
download_asset() { # $1 = API asset URL, $2 = output file
  local result code location
  result="$(api_curl -sS --proto '=https,http' --max-redirs 0 --max-filesize "$MAX_BYTES" \
    --connect-timeout 20 --max-time 600 -H 'Accept: application/octet-stream' \
    -o "$2" -w '%{http_code} %{redirect_url}' "$1")" || die "download failed: $1"
  code="${result%% *}"
  location="${result#* }"
  case "$code" in
    200) ;;
    301 | 302 | 303 | 307 | 308)
      case "$location" in
        https://*) ;;
        *) die "GitHub redirected the download to a non-HTTPS address; refusing." ;;
      esac
      curl -fsS --proto '=https' --max-redirs 3 --max-filesize "$MAX_BYTES" --connect-timeout 20 --max-time 600 \
        -o "$2" "$location" || die "download failed (storage server)" ;;
    *) die "GitHub answered HTTP $code for a release file" ;;
  esac
}

main() {
  case "${1:-}" in
    "" | -h | --help) usage; echo; echo "Names:"; list_products; exit 0 ;;
    --list) list_products; exit 0 ;;
  esac
  local name="$1"; shift

  local repo="" private="" n r p
  while IFS='|' read -r n r p; do
    if [ "$n" = "$name" ]; then repo="$r"; private="$p"; fi
  done <<<"$PRODUCTS"
  [ -n "$repo" ] || { echo "install: unknown name '$name'. Names:" >&2; list_products >&2; exit 1; }

  [ "$(id -u)" -eq 0 ] || die "run as root: ... | sudo bash -s $name"
  local tool
  for tool in curl tar sha256sum mktemp; do
    command -v "$tool" >/dev/null || die "'$tool' is needed but not installed"
  done
  command -v python3 >/dev/null || command -v jq >/dev/null || die "python3 or jq is needed but neither is installed"

  # Questions (ours and the installer's) come from the terminal, not from the pipe this script arrived through.
  local have_tty=0
  if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then have_tty=1; fi

  TOKEN="${INSTALL_GITHUB_TOKEN:-}"
  unset INSTALL_GITHUB_TOKEN
  if [ "$private" = 1 ] && [ -z "$TOKEN" ]; then
    [ "$have_tty" = 1 ] || die "$repo is private: set INSTALL_GITHUB_TOKEN (sudo --preserve-env=INSTALL_GITHUB_TOKEN ...)"
    echo "$repo is private. Paste a fine-grained GitHub token with read-only 'Contents' access to it" >&2
    echo "(github.com -> Settings -> Developer settings -> Fine-grained tokens). Input is hidden." >&2
    IFS= read -r -s -p "Token: " TOKEN </dev/tty || true
    echo >&2
    [ -n "$TOKEN" ] || die "no token given"
  fi

  WORK="$(mktemp -d /tmp/dxcufgb-install.XXXXXXXX)"
  trap 'rm -rf -- "$WORK"' EXIT

  say "Looking up the latest release of $repo"
  local code
  code="$(api_curl -sS --proto '=https,http' --max-redirs 0 --connect-timeout 20 --max-time 60 \
    -H 'Accept: application/vnd.github+json' -o "$WORK/release.json" -w '%{http_code}' \
    "$API/repos/$repo/releases/latest")" || die "could not reach GitHub"
  case "$code" in
    200) ;;
    401) die "GitHub rejected the token (HTTP 401): it is wrong or has expired" ;;
    403) die "GitHub refused the request (HTTP 403): rate limit, or the token lacks access" ;;
    404) die "no release found (HTTP 404). For a private repository: does the token have read access to $repo?" ;;
    *) die "GitHub answered HTTP $code" ;;
  esac

  local tag version
  tag="$(json_latest <"$WORK/release.json")" || die "could not read the release"
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "unexpected release tag '$tag'"
  version="${tag#v}"
  local archive="$name-$version-linux.tar.gz"
  local top="$name-$version"

  local archive_hit sums_hit archive_url sums_url
  archive_hit="$(json_asset "$archive" <"$WORK/release.json")" || die "could not read the release's file list"
  sums_hit="$(json_asset SHA256SUMS.txt <"$WORK/release.json")" || die "could not read the release's file list"
  [ -n "$archive_hit" ] && [ -n "$sums_hit" ] ||
    die "release $tag has no $archive or SHA256SUMS.txt (releases made before the unified installer). Download and install it by hand."
  archive_url="${archive_hit%% *}"
  archive="${archive_hit#* }"  # the name as published (its case may differ)
  sums_url="${sums_hit%% *}"

  say "Downloading $archive"
  download_asset "$sums_url" "$WORK/SHA256SUMS.txt"
  download_asset "$archive_url" "$WORK/$archive"

  local expected actual
  expected="$(awk -v n="$archive" '($2 == n || $2 == "*" n) && $1 ~ /^[0-9a-f]{64}$/ { print $1; exit }' "$WORK/SHA256SUMS.txt")"
  [ -n "$expected" ] || die "SHA256SUMS.txt has no line for $archive"
  actual="$(sha256sum "$WORK/$archive" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $archive: refusing to install it"
  say "Checksum OK"

  # The top folder is <name>-<version>/ in any case (see json_asset); every entry must be inside it, with no
  # absolute paths and no '..'.
  local entry first
  first="$(tar -tzf "$WORK/$archive" | head -n 1)" || true
  first="${first%%/*}"
  [ "${first,,}" = "${top,,}" ] || die "unexpected top folder in the archive: '$first' (expected $top)"
  top="$first"
  while IFS= read -r entry; do
    case "$entry" in
      "$top" | "$top/" | "$top/"*) ;;
      *) die "unexpected path in the archive: $entry" ;;
    esac
    case "/$entry/" in
      */../*) die "unexpected path in the archive: $entry" ;;
    esac
  done < <(tar -tzf "$WORK/$archive")
  mkdir "$WORK/x"
  tar -xzf "$WORK/$archive" -C "$WORK/x" --no-same-owner
  [ -f "$WORK/x/$top/install.sh" ] || die "the archive has no $top/install.sh"

  say "Running $top/install.sh $*"
  local status=0
  if [ "$have_tty" = 1 ]; then
    (cd "$WORK/x/$top" && INSTALL_GITHUB_TOKEN="$TOKEN" bash ./install.sh "$@") </dev/tty || status=$?
  else
    (cd "$WORK/x/$top" && INSTALL_GITHUB_TOKEN="$TOKEN" bash ./install.sh "$@") </dev/null || status=$?
  fi
  TOKEN=""
  exit "$status"
}

# Everything is in functions and main runs on the last line, so `curl ... | bash` reads the whole script before
# running any of it (a cut-off download does nothing).
main "$@"
