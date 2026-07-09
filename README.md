# Codex Multihome

![Codex Multihome banner](docs/hero.png)

[![CI](https://github.com/Takhoffman/codex-multihome/actions/workflows/ci.yml/badge.svg)](https://github.com/Takhoffman/codex-multihome/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/codex-multihome.svg)](https://www.npmjs.com/package/codex-multihome)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Codex Multihome is a macOS menu bar launcher and CLI for safely running multiple Codex homes without losing track of which state you opened.

It can launch Codex as the desktop app or in a terminal session while setting `CODEX_HOME` only for that child process. It does not use `launchctl setenv CODEX_HOME`.

## What It Manages

- Main Codex home: `~/.codex`
- Managed homes: `~/.codex-homes/<slug>`
- Managed desktop profiles: `~/Library/Application Support/CodexMultihome/Profiles/<slug>`
- Multihome state: `~/Library/Application Support/CodexMultihome/homeport.json`
- Dev-channel managed homes: `~/.codex-homes-dev/<slug>`
- Dev-channel state: `~/Library/Application Support/CodexMultihomeDev/homeport.json`

## Launch Modes

- **Main**: opens your normal `~/.codex`.
- **Clean Room**: creates an empty managed home.
- **Clone My Setup**: copies selected files from `~/.codex` or a managed home, with an optional safe symlink mode for shared customizations.
- **Temporary**: creates a throwaway home and marks it for cleanup review.

Temporary homes are not deleted immediately. Multihome shows what will be removed and lets you delete or promote the home.

## CLI

```sh
swift run homeport doctor
swift run homeport launch main --target desktop
swift run homeport launch main --target terminal
swift run homeport launch temp --target terminal
swift run homeport throwaway
swift run homeport create --kind clean-room --name "Blank Slate"
swift run homeport rename blank-slate --name "Scratch Lab"
swift run homeport delete scratch-lab
swift run homeport clone --preset working-setup --name "Test Home"
swift run homeport clone --name "Shared Skills" --source main --link-safe --include skills,plugins
swift run homeport clone --name "Shared Auth" --source main --link-auth --include config,auth
swift run homeport clone --name "Linked Config" --source main --include config,auth --link config
swift run homeport clone --name "From Template" --source template-home --link-safe
swift run homeport list
swift run homeport review
swift run homeport cleanup INSTANCE_UUID
swift run homeport install --with-app
swift run homeport update --with-app
swift run homeport onboard
swift run homeport uninstall
swift run homeport clone --name "Skills Lab" --include config,skills,plugins --exclude auth,sessions
```

`homeport clone --source main|SLUG` chooses the clone source. `--link-safe`
symlinks safe customization categories only: config, skills, plugins, agents,
prompts, rules, and profiles. `--link-auth` also symlinks selected `auth.json`.
`--link LIST` symlinks specific linkable categories. Browser support, memories,
and sessions/logs are always copied or excluded.

## Menu Bar App

```sh
swift run CodexMultihomeApp
```

The menu bar app provides quick launch buttons, diagnostics, clone creation, clean-room creation, and cleanup review.

To run a dev menu bar app beside the live app:

```sh
homeport install --with-app --channel dev
homeport start --channel dev
HOMEPORT_CHANNEL=dev swift run CodexMultihomeApp
```

The dev channel installs as `Codex Multihome Dev.app`, uses bundle ID
`com.takhoffman.codex-multihome.dev`, embeds its dev channel in the app bundle,
writes its own LaunchAgent, and keeps Multihome state and managed homes separate
from live. Use `HOMEPORT_CHANNEL=dev` only for `swift run` development.

The menu keeps pinned homes and recent launches close at hand:

- Pin homes from the Console to keep them at the top of the menu.
- Relaunch recent desktop or terminal sessions from the menu or Console.
- Recents are based on Multihome launch history and survive app restarts.

## Model Routing Shim

Model routing uses a cleaned `codex-shim` runtime bundled inside the Multihome
app; it does not require a separate checkout or globally installed
`codex-shim` executable. On its first routing command, the bundled launcher
creates `~/Library/Application Support/CodexMultihome/codex-shim-runtime/venv`
and installs its pinned `aiohttp` dependencies. This requires Python 3.11+ and
network access for that first bootstrap. Settings keeps an optional Shim
executable override for an intentionally managed external runtime.

## Install And Update

The recommended Mac install path is npm. The npm package builds the Swift CLI
during install, exposes the `homeport` command, and keeps the source package in
npm's normal global package location.

```sh
npm install -g codex-multihome
homeport install --with-app
homeport start
```

To update:

```sh
npm install -g codex-multihome@latest
homeport update
```

When installed through npm, `homeport update` rebuilds and reinstalls the app
from the npm package. Use npm itself to fetch new published versions.

The app's Settings tab includes the auto-updater. When the app is running, it
checks npm daily or weekly, badges Settings and the menu bar icon when a newer
version is available, and installs only after you choose Update unless automatic
installs are enabled. Updates run the same safe path the app shows:

```sh
npm install -g codex-multihome@latest
homeport update --with-app
```

If you already have the source repo checked out, you can still install directly
from the current checkout:

```sh
swift run homeport install --with-app
homeport start
```

To install the CLI:

```sh
swift run homeport install
```

The older git-backed install script remains useful for source development:

```sh
./install.sh
```

That script keeps a checkout at
`~/Library/Application Support/CodexMultihome/Source`, installs the CLI to
`~/bin/homeport`, installs the app to `~/Applications/Codex Multihome.app`,
enables autostart, and starts the app.

If the app is already installed, `homeport update` reinstalls it automatically;
if the menu bar app is running, it restarts it after the update so macOS uses
the new binary. Use `homeport update --no-restart` when you want to relaunch
manually.

The versioning strategy is simple semantic versions:

- Patch versions (`0.2.1`) are bug fixes, docs, and safe installer tweaks.
- Minor versions (`0.3.0`) are visible app or CLI behavior changes.
- Major versions (`1.0.0`) are reserved for incompatible state, path, or command changes.

`HomeportCore/AppVersion.swift` is the source of truth for the CLI version and
the generated app bundle `CFBundleShortVersionString`/`CFBundleVersion`;
`package.json` must match it. Each version also has release notes in
`releases/vX.Y.Z.md`, and `CHANGELOG.md` links to those files.

To cut a release:

```sh
npm run release:check
git tag vX.Y.Z
git push origin main vX.Y.Z
```

Pushing a `vX.Y.Z` tag runs the GitHub Release workflow. The workflow tests the
package, publishes `codex-multihome` to npm with trusted publishing and
provenance, and creates a GitHub Release from `releases/vX.Y.Z.md`. Configure
the npm package for trusted publishing from this repository before cutting a
release. Users update with `npm install -g codex-multihome@latest`.

Autostart is managed by a user LaunchAgent:

```sh
homeport autostart enable
homeport autostart status
homeport autostart disable
```

Configuration can be changed without reinstalling:

```sh
homeport configure --terminal iTerm
homeport configure --channel dev --show
homeport configure --workspace "$PWD"
homeport configure --launch-target terminal
homeport configure --clone-preset config-only
homeport configure --clone-include config,skills,plugins
homeport configure --clone-exclude auth,sessions
homeport configure --temporary on
homeport configure --allow-forbidden-computer-use-targets on
homeport configure --browser-use-local-testing on
homeport configure --update-checks on
homeport configure --update-interval weekly
homeport configure --auto-install-updates off
homeport configure --autostart on
homeport configure --show
homeport configure --reset
```

Onboarding applies Apple's global Computer Use target default so desktop
automation can reach apps that macOS otherwise marks as forbidden. Turn it off
with `homeport configure --allow-forbidden-computer-use-targets off`, or use the
Settings tab in the menu bar app.

To uninstall the app and autostart entry while keeping Codex homes and Multihome state:

```sh
homeport uninstall
```

More complete removal is opt-in:

```sh
homeport uninstall --remove-cli --remove-state
homeport uninstall --remove-managed-homes
```

`--remove-managed-homes` moves `~/.codex-homes` to Trash, so use it only when you really want to remove cloned or temporary Codex homes. Your main `~/.codex` is never removed by Multihome.

## Clone Presets

- `working-setup`: config, auth, skills, plugins, MCP-related files, no sessions/logs.
- `config-only`: config and customization, no auth.
- `everything`: full copy.
- `empty`: no inherited files.

## Diagnostics

`homeport doctor` checks:

- whether `launchctl getenv CODEX_HOME` is set
- whether a Codex Desktop app is installed (identified by bundle ID, so app renames are supported)
- whether the `codex` CLI exists
- how many sessions are in `~/.codex/session_index.jsonl`
- whether Desktop launcher scripts reference `Deckhand/CodexHome`

Use:

```sh
swift run homeport doctor --repair
```

to clear a GUI-level `CODEX_HOME` override.
