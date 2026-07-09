# Bundled codex-shim runtime

This directory vendors the cleaned local `codex-shim` runtime used by Codex
Multihome model routing. It is based on the local source at
`sybil-solutions/codex-shim`, including Anthropic BYOK `/v1/messages` support.
The retired Grok and Claude CLI/subscription passthrough code is not included.

The upstream MIT license is included in [LICENSE](LICENSE). `run-codex-shim`
creates a per-user virtual environment on first use and installs the exact
versions listed in `requirements.txt`; no globally installed `codex-shim`
executable is required.
