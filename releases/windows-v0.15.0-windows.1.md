# Windows v0.15.0-windows.1

- Restored the Windows Node.js CLI and PowerShell/WPF tray application on top
  of the current v0.15.0 codebase without changing the macOS package.
- Published Windows as the independent `codex-multihome-windows` package with
  the `codex-multihome` executable.
- Added isolated Codex Desktop and terminal launches, live/dev channels,
  custom home paths, safe move/adopt behavior, and legacy state migration.
- Added current packaged Codex Desktop and PATH-based CLI discovery.
- Added independent Windows CI/release workflows and 20 Windows regression
  tests, including simultaneous launch isolation and custom-path safeguards.
- Kept model routing, MITM capture, and macOS Computer Use configuration out
  of the initial Windows support contract.
