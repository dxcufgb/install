# install

The Linux one-liner installer for dxcufgb's bots and services:
`curl -fsSL https://raw.githubusercontent.com/dxcufgb/install/main/install.sh | sudo bash -s <name> [options]`.
It finds the latest GitHub release of that program's repository, downloads and verifies its Linux archive and runs
the `install.sh` inside it as root with the remaining options. One bash script, no build step, no releases: the
one-liner always runs `install.sh` from `main`, so every merge to `main` is live for every new install at once.

## Layout
- `install.sh` – the installer. `PRODUCTS` (`name|owner/repo|private`), `usage`/`list_products` (`--help`, `--list`),
  `json_latest`/`json_asset` (read the release JSON with `python3 -I`, or `jq` when there is no python3; asset names
  matched ignoring case, an ambiguous match fails), `api_curl` (the token as a header through `curl --config -`),
  `download_asset` (API request with `--max-redirs 0`, then the HTTPS storage redirect without the token),
  `main` (root check, tool check, token from `INSTALL_GITHUB_TOKEN` or a hidden prompt on `/dev/tty`, tag must be
  `vX.Y.Z`, SHA-256 against `SHA256SUMS.txt`, every archive entry inside the single top folder `<name>-<version>/`
  and no `..`, extract with `--no-same-owner`, run `<top>/install.sh "$@"` with the token in `INSTALL_GITHUB_TOKEN`).
- `test/run.sh` – runs the real `install.sh` (as root) against the fake API: `--list`, unknown name, public install
  with option pass-through, private without/with a wrong/with the right token, token not printed, plain-http redirect
  refused and no token to storage, checksum mismatch, release without the new file names, path outside the top
  folder, names that differ only in case, wrong top folder, no temporary folder left.
- `test/fake_github.py` – stdlib stand-in for `releases/latest` and `/assets/<name>`; private mode needs
  `Bearer test-token`; logs `auth`/`noauth` per path to `auth.log`; `redirect-http` makes an asset redirect to plain
  http (`/storage/`).
- `.github/workflows/ci.yml` (shellcheck + `sudo bash test/run.sh`), `workflow-lint.yml` (actionlint, zizmor),
  `.github/dependabot.yml` (GitHub Actions only).

## Commands
- `sudo bash test/run.sh` (needs root, python3, curl, tar; behind a proxy run it with the proxy variables unset).
- `shellcheck install.sh test/run.sh`.

## Conventions
- `set -euo pipefail`, `umask 077`; everything is in functions and `main "$@"` is the last line, so a cut-off
  download runs nothing. Keep that.
- Messages go to stderr through `die` (prefix `install:`) and `say` (`==>`). Keep the scripts shellcheck-clean.
- A new program: one line in `PRODUCTS` and one row in the README table (name, repository, "Needs a token").

## Review focus
- **Runs as root from `main`**: there is no release step to catch a mistake. Every change to `install.sh` needs a
  case in `test/run.sh`, including the failure path, and the failure cases must assert that the release's
  `install.sh` did not run (`[ ! -e "$D/report" ]`).
- **Nothing runs before it is verified**: flag any weakening of the `vX.Y.Z` tag check, the SHA-256 check (exact
  64-hex line for the published name, `*name` accepted), the top-folder and `..` checks, `--max-filesize`, the
  `https` only redirect, or running anything from the archive before those checks.
- **The token** goes only to the API (`api_curl`, via `curl --config -`, never as a command-line argument), never
  to the storage redirect, never to stdout/stderr, and on to the release's installer only in `INSTALL_GITHUB_TOKEN`.
  It is unset from the environment early (`unset INSTALL_GITHUB_TOKEN`); public products (`private` = `0`) never
  ask for one.
- **Contract with the product repositories** (TwitchDiscordBot, DiscordComicsBot, FoundryVTT-discord-integration,
  FoundryVTT-Private-Github-proxy, FoundryVTT-world-backup-to-git): their releases carry
  `<name>-<version>-linux.tar.gz` (any case) and `SHA256SUMS.txt`, the archive has one top folder `<name>-<version>/`
  with `install.sh`, and the options after `<name>` are passed on unchanged. Changing any of this breaks installs
  of programs whose releases cannot change retroactively.
- `PRODUCTS` and the README table must agree (names, repositories, private flag).
- `INSTALL_TEST_API_URL` is test-only (it allows plain http); no new behaviour may hang off it for real installs.
- The `jq` branches of `json_latest`/`json_asset` must behave like the `python3` ones (the tests only cover
  python3, because the fake server needs it).
- Prompts read from `/dev/tty`, and the release's installer gets `/dev/tty` (or `/dev/null` without a terminal) as
  stdin, never the pipe the script arrived through.
