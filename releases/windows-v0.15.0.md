# Windows v0.15.0

Stable Windows release of Codex Multihome.

## Highlights

- Run simultaneous Codex Desktop instances with isolated `CODEX_HOME` and Chromium profile directories.
- Create, clone, rename, move, review, promote, and safely clean up managed homes.
- Use the native PowerShell/WPF tray interface with separate live and development channels.
- Start the tray at login through a non-admin per-user Startup entry.
- Preserve legacy Windows `homeport.json` state while keeping the macOS package independent.
- Install from npm with `npm install -g codex-multihome-windows`.

## Verification

- Windows build and release checks pass.
- 21 Windows runtime tests pass.
- Two real isolated Codex Desktop homes were launched and reconciled concurrently.
- A clean install from the public npm registry passed the end-to-end smoke test.
