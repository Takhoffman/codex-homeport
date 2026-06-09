![Codex Homeport banner](docs/hero.png)

# Codex Homeport

Codex Homeport is a macOS launcher and hygiene tool for running multiple Codex homes without losing track of which state you opened.

It can launch Codex as the desktop app or in a terminal session while setting `CODEX_HOME` only for that child process. It does not use `launchctl setenv CODEX_HOME`.

## What It Manages

- Main Codex home: `~/.codex`
- Managed homes: `~/.codex-homes/<slug>`
- Managed desktop profiles: `~/Library/Application Support/CodexHomeport/Profiles/<slug>`
- Homeport state: `~/Library/Application Support/CodexHomeport/homeport.json`

## Launch Modes

- **Main**: opens your normal `~/.codex`.
- **Clean Room**: creates an empty managed home.
- **Clone My Setup**: copies selected files from `~/.codex`.
- **Temporary**: creates a throwaway home and marks it for cleanup review.

Temporary homes are not deleted immediately. Homeport shows what will be removed and lets you delete or promote the home.

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
swift run homeport list
swift run homeport review
swift run homeport cleanup INSTANCE_UUID
swift run homeport install --with-app
swift run homeport update --with-app
swift run homeport onboard
swift run homeport uninstall
```

## Menu Bar App

```sh
swift run CodexHomeportApp
```

The menu bar app provides quick launch buttons, diagnostics, clone creation, clean-room creation, and cleanup review.

The menu keeps pinned homes and recent launches close at hand:

- Pin homes from the Console to keep them at the top of the menu.
- Relaunch recent desktop or terminal sessions from the menu or Console.
- Recents are based on Homeport launch history and survive app restarts.

To install, configure autostart, and open the app:

```sh
swift run homeport onboard
```

To build and install an app bundle:

```sh
swift run homeport install --with-app
homeport start
```

To install the CLI:

```sh
swift run homeport install
```

To update from git and reinstall:

```sh
homeport update --with-app
```

Autostart is managed by a user LaunchAgent:

```sh
homeport autostart enable
homeport autostart status
homeport autostart disable
```

Configuration can be changed without reinstalling:

```sh
homeport configure --terminal iTerm
homeport configure --workspace "$PWD"
homeport configure --launch-target terminal
homeport configure --clone-preset config-only
homeport configure --temporary on
homeport configure --autostart on
homeport configure --show
homeport configure --reset
```

To uninstall the app and autostart entry while keeping Codex homes and Homeport state:

```sh
homeport uninstall
```

More complete removal is opt-in:

```sh
homeport uninstall --remove-cli --remove-state
homeport uninstall --remove-managed-homes
```

`--remove-managed-homes` moves `~/.codex-homes` to Trash, so use it only when you really want to remove cloned or temporary Codex homes. Your main `~/.codex` is never removed by Homeport.

## Clone Presets

- `working-setup`: config, auth, skills, plugins, MCP-related files, no sessions/logs.
- `config-only`: config and customization, no auth.
- `everything`: full copy.
- `empty`: no inherited files.

## Diagnostics

`homeport doctor` checks:

- whether `launchctl getenv CODEX_HOME` is set
- whether Codex.app exists
- whether the `codex` CLI exists
- how many sessions are in `~/.codex/session_index.jsonl`
- whether Desktop launcher scripts reference `Deckhand/CodexHome`

Use:

```sh
swift run homeport doctor --repair
```

to clear a GUI-level `CODEX_HOME` override.
