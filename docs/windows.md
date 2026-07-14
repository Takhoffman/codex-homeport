# Codex Multihome on Windows

The Windows port is a native Node.js CLI with a PowerShell/WPF tray app. It is
kept in `packages/windows` so the existing Swift/macOS release and its bundled
macOS runtimes remain independent.

## Windows v1 scope

Supported:

- isolated `CODEX_HOME` folders and Codex Desktop profile directories;
- create, clone, rename, move, adopt, promote, review, and safe cleanup flows;
- simultaneous terminal and Codex Desktop launches;
- Windows Terminal with a `cmd.exe` fallback;
- a WPF tray launcher and non-admin, per-user Startup-folder autostart;
- live/dev channels and legacy `homeport.json` state compatibility;
- `CODEX_MULTIHOME_*` variables with legacy `HOMEPORT_*` fallbacks.

Not yet supported on Windows:

- Codex Shim model routing and provider bridges;
- bundled mitmproxy capture;
- macOS Computer Use defaults and app-bundle repair.

Claude homes remain available as an experimental compatibility feature, but
the supported Windows v1 contract is Codex.

## Paths

- Main home: `%USERPROFILE%\.codex`
- Managed homes: `%USERPROFILE%\.codex-homes\<slug>`
- Managed profiles: `%APPDATA%\CodexMultihome\Profiles\<slug>`
- State: `%APPDATA%\CodexMultihome\homeport.json`
- Trash: `%APPDATA%\CodexMultihome\Trash`
- Tray installation: `%LOCALAPPDATA%\CodexMultihome\App`
- Autostart: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Multihome.vbs`

The legacy state filename is intentional. Existing Windows v0.7.3 state is
migrated in memory without forcing users to reset their homes.

## Development

```powershell
cd packages/windows
npm test
npm run build
npm run release:check
node .\codex-multihome.js --help
```

Install a local command shim and tray app:

```powershell
node .\codex-multihome.js install --prefix "$env:USERPROFILE\bin" --with-app
& "$env:USERPROFILE\bin\codex-multihome.cmd" doctor
codex-multihome start
codex-multihome autostart enable
```

For a side-by-side development channel:

```powershell
codex-multihome install --with-app --channel dev
codex-multihome start --channel dev
```

The dev channel uses `.codex-homes-dev`, `CodexMultihomeDev` application data,
and a separate `Codex Multihome Dev.vbs` per-user Startup entry.

## Common commands

```powershell
codex-multihome doctor
codex-multihome list
codex-multihome launch main --target terminal
codex-multihome launch main --target desktop
codex-multihome launch temp --target desktop
codex-multihome clone --preset working-setup --name "Plugin Lab"
codex-multihome create --kind clean-room --name "Blank Slate"
codex-multihome create --kind clean-room --path "D:\Codex Homes\Project A"
codex-multihome path blank-slate --path "D:\Codex Homes\Blank Slate" --move
codex-multihome rename blank-slate --name "Scratch Lab" --move-folders
codex-multihome review
codex-multihome cleanup INSTANCE_UUID
codex-multihome promote INSTANCE_UUID --name "Saved Lab"
```

Desktop launches locate `Codex.exe`, create a distinct profile directory, and
set `CODEX_HOME` only in the launched child process. Terminal launches set it
inside the new terminal command. The tool never writes `CODEX_HOME` into the
user or machine environment.

## Custom-path safety

`create` and `clone` accept `--path`. The `path` command can move a registered
home with `--move`, or point it at an existing directory without `--move`.

Deleting a registration at a custom path preserves that directory by default.
Pass `--remove-files` only when the custom directory itself should be moved to
Multihome Trash. The main `%USERPROFILE%\.codex` home cannot be moved or
deleted.

## Packaging

The Windows package is intentionally separate from the macOS npm package:

```powershell
npm install -g codex-multihome-windows
codex-multihome onboard
```

This prevents Windows installs from downloading macOS-only Swift, Python, and
mitmproxy runtime assets.
