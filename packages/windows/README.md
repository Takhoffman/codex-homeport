# codex-multihome-windows

Windows-native Codex Multihome CLI and tray launcher. It creates isolated
`CODEX_HOME` and Codex Desktop profile directories so multiple Codex sessions
can run side by side without setting a global environment variable.

```powershell
npm install -g codex-multihome-windows
codex-multihome onboard
codex-multihome doctor
```

See the [Windows documentation](https://github.com/Takhoffman/codex-multihome/blob/main/docs/windows.md)
for commands, paths, safety behavior, development checks, and the
Windows/macOS feature boundary.
