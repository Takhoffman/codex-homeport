# Bundled codex-shim runtime

This directory vendors the cleaned local `codex-shim` runtime used by Codex
Multihome model routing. It is based on the local source at
`sybil-solutions/codex-shim`, including Anthropic BYOK `/v1/messages` support.
The retired Grok and Claude CLI/subscription passthrough code is not included.

The upstream MIT license is included in [LICENSE](LICENSE). Release packaging
prepares checksum-verified standalone CPython runtimes for Apple Silicon and
Intel Macs, with the exact versions listed in `requirements.txt`. Published
packages and installed apps therefore need no globally installed Python or
`codex-shim` executable, and routing runs offline. A source checkout prepares
only its host runtime through `scripts/prepare-shim-runtime.sh`.
