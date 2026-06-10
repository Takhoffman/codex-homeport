# Security Policy

Codex Multihome launches local Codex processes with explicit `CODEX_HOME` and app profile paths. It may copy local Codex configuration and, depending on the preset, authentication files.

## Reporting

Please report security issues privately through GitHub Security Advisories once the repository is public. Do not open a public issue for vulnerabilities.

## Sensitive Areas

Security-sensitive changes include:

- Copying `auth.json` or other credential-like files
- Cleanup or uninstall behavior
- LaunchAgent/autostart behavior
- Any shell, AppleScript, or process-launch command construction
- Changes that affect `CODEX_HOME` or managed home paths

## Invariants

- Multihome must never delete the main `~/.codex` directory.
- Multihome must not persist global `CODEX_HOME` with `launchctl setenv`.
- Temporary homes should be moved to Trash only through explicit cleanup or uninstall flags.
