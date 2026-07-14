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

### Bundled MITM proxy

Multihome can ship the official signed mitmproxy macOS bundle and automatically
start `mitmweb` when a proxy-enabled Codex Desktop or CLI session launches:

```sh
codex-multihome configure --mitm-proxy on --mitm-proxy-url http://127.0.0.1:8080
codex-multihome proxy status
codex-multihome proxy stop
```

The proxy binds only to loopback. Its generated CA, private key, PID, and log are
stored under Multihome's Application Support directory, never in the app bundle.
Each home gets stable proxy/web ports and its own session directory under
`mitmproxy/homes/<home-id>/`, including `flows.mitm`, `mitmweb.log`, and its PID.
The trusted CA remains shared at the channel's `mitmproxy/` root. An agent can
inspect a home's archive with the bundled `mitmdump` when explicitly asked. Flow archives
may contain authorization headers, cookies, prompts, and response bodies; treat
them as sensitive and do not attach or share them without reviewing their contents.
Set `--mitm-proxy-ca` to use a different PEM CA bundle. Release builders run
`scripts/prepare-mitmproxy-runtime.sh --all`; local builds prepare only the host
architecture. Trusting a generated interception CA in the macOS keychain remains
an explicit user action.

```sh
swift run codex-multihome doctor
swift run codex-multihome launch main --target desktop
swift run codex-multihome launch main --target terminal
swift run codex-multihome launch temp --target terminal
swift run codex-multihome throwaway
swift run codex-multihome create --kind clean-room --name "Blank Slate"
swift run codex-multihome rename blank-slate --name "Scratch Lab"
swift run codex-multihome delete scratch-lab
swift run codex-multihome clone --preset working-setup --name "Test Home"
swift run codex-multihome clone --preset working-setup --name "Disposable Test Home" --temporary
swift run codex-multihome clone --name "Shared Skills" --source main --link-safe --include skills,plugins
swift run codex-multihome clone --name "Shared Auth" --source main --link-auth --include config,auth
swift run codex-multihome clone --name "Linked Config" --source main --include config,auth --link config
swift run codex-multihome clone --name "From Template" --source template-home --link-safe
swift run codex-multihome list
swift run codex-multihome review
swift run codex-multihome cleanup INSTANCE_UUID
swift run codex-multihome install --with-app
swift run codex-multihome update --with-app
swift run codex-multihome onboard
swift run codex-multihome uninstall
swift run codex-multihome clone --name "Skills Lab" --include config,skills,plugins --exclude auth,sessions
```

`codex-multihome clone --source main|SLUG` chooses the clone source. `--link-safe`
symlinks safe customization categories only: config, skills, plugins, agents,
prompts, rules, and profiles. `--link-auth` also symlinks selected `auth.json`.
`--link LIST` symlinks specific linkable categories. Browser support, memories,
and sessions/logs are always copied or excluded.

## Menu Bar App

```sh
swift run CodexMultihomeApp
```

The menu bar app provides quick launch buttons, diagnostics, clone creation, clean-room creation, and cleanup review.
The New Home screen and CLI share the same lifecycle model: add `--temporary`
to a CLI clone, or enable **Temporary home** in the app, to keep the selected
copy/link policies while marking the home for cleanup review.

To run a dev menu bar app beside the live app:

```sh
codex-multihome install --with-app --channel dev
codex-multihome start --channel dev
CODEX_MULTIHOME_CHANNEL=dev swift run CodexMultihomeApp
```

The dev channel installs as `Codex Multihome Dev.app`, uses bundle ID
`com.takhoffman.codex-multihome.dev`, embeds its dev channel in the app bundle,
writes its own LaunchAgent, and keeps Multihome state and managed homes separate
from live. Use `CODEX_MULTIHOME_CHANNEL=dev` only for `swift run` development.

The menu keeps pinned homes and recent launches close at hand:

- Pin homes from the Console to keep them at the top of the menu.
- Relaunch recent desktop or terminal sessions from the menu or Console.
- Recents are based on Multihome launch history and survive app restarts.

## Model Routing Shim

Model routing uses a cleaned `codex-shim` runtime bundled inside the Multihome
app; it does not require a separate checkout or globally installed
`codex-shim` executable. Published packages embed checksum-verified standalone
CPython runtimes for Apple Silicon and Intel Macs plus pinned `aiohttp`
dependencies. Starting the bundled routing runtime needs neither a system
Python nor dependency downloads; requests to remote model providers still need
network access. Source checkouts prepare the host runtime during installation.
Settings keeps an optional Shim executable override for an intentionally managed
external runtime.

### GitHub Copilot subscription

The shim can run the models included with your GitHub Copilot subscription
inside the Codex Desktop or CLI harness. Install the GitHub Copilot CLI, run
`copilot login`, then open a home's **Model Routing** panel. Model routing is
only available for clones, clean rooms, and temporary homes — the Main home
always launches the untouched default Codex install:

1. Enable **Route models through shim** and **GitHub Copilot**.
2. Choose **Sign in** to open `copilot login` in your configured Terminal if
   you have not already authenticated.
3. Choose **Restart**, then open **Model Picker** and select one of the
   dynamically discovered `copilot-*` models.

The shim uses the Copilot CLI's existing login and never copies or stores its
token. Codex remains responsible for executing tools and enforcing approvals;
Copilot supplies the model response. Available models and any quota or premium
request accounting come from your GitHub Copilot plan. See the
[shim documentation](Sources/CodexMultihomeApp/Resources/codex-shim/README.md#github-copilot-passthrough-subscription)
for the CLI setup, limitations, and SDK caveats.

## Install And Update

The recommended Mac install path is npm. The npm package builds the Swift CLI
during install, exposes the `codex-multihome` command, and keeps the source package in
npm's normal global package location.

```sh
npm install -g codex-multihome
codex-multihome install --with-app
codex-multihome start
```

To update:

```sh
npm install -g codex-multihome@latest
codex-multihome update
```

When installed through npm, `codex-multihome update` rebuilds and reinstalls the app
from the npm package. Use npm itself to fetch new published versions.

The app's Settings tab includes the auto-updater. When the app is running, it
checks npm daily or weekly, badges Settings and the menu bar icon when a newer
version is available, and installs only after you choose Update unless automatic
installs are enabled. Updates run the same safe path the app shows:

```sh
npm install -g codex-multihome@latest
codex-multihome update --with-app
```

If you already have the source repo checked out, you can still install directly
from the current checkout:

```sh
swift run codex-multihome install --with-app
codex-multihome start
```

To install the CLI:

```sh
swift run codex-multihome install
```

The older git-backed install script remains useful for source development:

```sh
./install.sh
```

That script keeps a checkout at
`~/Library/Application Support/CodexMultihome/Source`, installs the CLI to
`~/bin/codex-multihome`, installs the app to `~/Applications/Codex Multihome.app`,
enables autostart, and starts the app.

If the app is already installed, `codex-multihome update` reinstalls it automatically;
if the menu bar app is running, it restarts it after the update so macOS uses
the new binary. Use `codex-multihome update --no-restart` when you want to relaunch
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
codex-multihome autostart enable
codex-multihome autostart status
codex-multihome autostart disable
```

Configuration can be changed without reinstalling:

```sh
codex-multihome configure --terminal iTerm
codex-multihome configure --channel dev --show
codex-multihome configure --workspace "$PWD"
codex-multihome configure --launch-target terminal
codex-multihome configure --clone-preset config-only
codex-multihome configure --clone-include config,skills,plugins
codex-multihome configure --clone-exclude auth,sessions
codex-multihome configure --temporary on
codex-multihome configure --allow-forbidden-computer-use-targets on
codex-multihome configure --browser-use-local-testing on
codex-multihome configure --desktop-app-dev-flavor on
codex-multihome configure --browser-use-local-testing on
codex-multihome configure --update-checks on
codex-multihome configure --update-interval weekly
codex-multihome configure --auto-install-updates off
codex-multihome configure --autostart on
codex-multihome configure --show
codex-multihome configure --reset
```

Onboarding applies Apple's global Computer Use target default so desktop
automation can reach apps that macOS otherwise marks as forbidden. Turn it off
with `codex-multihome configure --allow-forbidden-computer-use-targets off`, or use the
Settings tab in the menu bar app.

To uninstall the app and autostart entry while keeping Codex homes and Multihome state:

```sh
codex-multihome uninstall
```

More complete removal is opt-in:

```sh
codex-multihome uninstall --remove-cli --remove-state
codex-multihome uninstall --remove-managed-homes
```

`--remove-managed-homes` moves `~/.codex-homes` to Trash, so use it only when you really want to remove cloned or temporary Codex homes. Your main `~/.codex` is never removed by Multihome.

## Clone Presets

- `working-setup`: config, auth, skills, plugins, MCP-related files, no sessions/logs.
- `config-only`: config and customization, no auth.
- `everything`: full copy.
- `empty`: no inherited files.

## Diagnostics

`codex-multihome doctor` checks:

- whether `launchctl getenv CODEX_HOME` is set
- whether a Codex Desktop app is installed (identified by bundle ID, so app renames are supported)
- whether the `codex` CLI exists
- how many sessions are in `~/.codex/session_index.jsonl`
- whether Desktop launcher scripts reference `Deckhand/CodexHome`

Use:

```sh
swift run codex-multihome doctor --repair
```

to clear a GUI-level `CODEX_HOME` override.
