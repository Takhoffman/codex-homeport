# Contributing

Thanks for helping improve Codex Multihome.

## Development

Requirements:

- macOS 13 or newer
- Xcode with Swift 6 toolchain
- Codex installed locally if you want to test real launches

Run checks:

```sh
swift test
swift run homeport --help
swift run homeport doctor
```

Build the menu bar app:

```sh
swift run homeport install --with-app --prefix /tmp/homeport-bin --app-dir /tmp
```

## Safety

Multihome manages Codex state paths. Changes should preserve these rules:

- Never remove `~/.codex`.
- Never call `launchctl setenv CODEX_HOME`.
- Temporary homes must be reviewable before deletion.
- Destructive cleanup must move files to Trash, stay opt-in, and stay scoped to managed Multihome paths.

## Pull Requests

Please include:

- What changed and why
- Manual verification steps
- Screenshots for menu bar or console UI changes
- Any migration impact for `homeport.json`

## Maintainer Release Checklist

Before tagging a release:

- Keep `main` protected with CI required before merge.
- Confirm npm trusted publishing is configured for this GitHub repository.
- Update `HomeportCore/AppVersion.swift`, `package.json`, `CHANGELOG.md`, and
  `releases/vX.Y.Z.md` together.
- Run `npm run release:check`.
- Tag with `git tag vX.Y.Z` and push `main` plus the tag.
