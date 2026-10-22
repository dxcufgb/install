# install

The Linux installer for dxcufgb's bots and services. One line installs (or upgrades) any of them from its
latest GitHub release:

```sh
curl -fsSL https://raw.githubusercontent.com/dxcufgb/install/main/install.sh | sudo bash -s <name> [options]
```

| Name | Repository |
|---|---|
| `twitchdiscordbot` | [TwitchDiscordBot](https://github.com/dxcufgb/TwitchDiscordBot) |
| `comicsbot` | [DiscordComicsBot](https://github.com/dxcufgb/DiscordComicsBot) |
| `foundryvtt-discord-integration` | [FoundryVTT-discord-integration](https://github.com/dxcufgb/FoundryVTT-discord-integration) |
| `foundry-release-proxy` | [FoundryVTT-Private-Github-proxy](https://github.com/dxcufgb/FoundryVTT-Private-Github-proxy) |
| `foundry-world-backup` | [FoundryVTT-world-backup-to-git](https://github.com/dxcufgb/FoundryVTT-world-backup-to-git) |

`[options]` go to that release's own `install.sh`. They are the same for all five:

| Option | Meaning |
|---|---|
| (none) | install or upgrade in place, asking for what it needs |
| `--yes`, `-y` | no questions; missing required settings are an error |
| `--auto-update` / `--no-auto-update` | turn automatic updates on / off as part of this install |
| `--enable-auto-update` / `--disable-auto-update` | turn them on / off on an existing install, nothing else |
| `--check-update` | only check: exit 0 = up to date, 10 = newer release available |
| `--update-now` | install the latest release now |
| `--uninstall` [`--purge`] | remove (keep / also delete settings and data) |
| `--help` | all options, including the ones specific to that program |

## What it does

1. Asks GitHub for the latest release of the repository (drafts and pre-releases never count).
2. Downloads `<name>-<version>-linux.tar.gz` and `SHA256SUMS.txt` from it and checks the archive's SHA-256.
3. Checks that everything in the archive is inside its one top folder, unpacks it into a new temporary folder and
   runs `<name>-<version>/install.sh` as root with your options.
4. Deletes the temporary folder.

Questions are asked on your terminal, so the interactive installers work through the pipe.

## No token needed

All five repositories are public, so the installer needs no GitHub token, and neither do automatic updates.

The installer still supports private repositories (none is listed now): for one, it asks for a fine-grained token
with read-only *Contents* access to that repository (input hidden), or reads it from `INSTALL_GITHUB_TOKEN`
(`sudo --preserve-env=INSTALL_GITHUB_TOKEN ...`). A token is sent only to `api.github.com` (GitHub redirects the
actual download to its storage server, which gets no token), never put on a command line or printed, and passed to
the release's installer in `INSTALL_GITHUB_TOKEN`.

## Without the one-liner

Download `<name>-linux.tar.gz` from the repository's latest release, then:

```sh
tar xzf <name>-linux.tar.gz
cd <name>-<version>
sudo ./install.sh [options]
```

## Development

- `bash test/run.sh` (as root) tests the installer against a fake GitHub API (`test/fake_github.py`); CI runs it
  with shellcheck, actionlint and zizmor.
- A new program: add a line to `PRODUCTS` in `install.sh` and a row to the table above. Its releases must carry
  `<name>-<version>-linux.tar.gz` (one top folder `<name>-<version>/` with `install.sh`) and `SHA256SUMS.txt`.
