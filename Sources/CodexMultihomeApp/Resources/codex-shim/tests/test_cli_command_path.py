from __future__ import annotations

from pathlib import Path
import sys
import unittest
from unittest.mock import patch


SHIM_ROOT = Path(__file__).resolve().parents[1]
if str(SHIM_ROOT) not in sys.path:
    sys.path.insert(0, str(SHIM_ROOT))

from codex_shim import cli  # noqa: E402


class CommandPathTests(unittest.TestCase):
    def test_uses_path_lookup_first(self) -> None:
        with patch.object(cli.shutil, "which", return_value="/custom/bin/npx"):
            self.assertEqual(cli._command_path("npx"), "/custom/bin/npx")

    def test_finds_homebrew_npx_for_finder_launched_app(self) -> None:
        with (
            patch.object(cli.shutil, "which", return_value=None),
            patch.object(cli.sys, "platform", "darwin"),
            patch.object(cli.Path, "is_file", return_value=True),
            patch.object(cli.os, "access", return_value=True),
        ):
            self.assertEqual(cli._command_path("npx"), "/opt/homebrew/bin/npx")

    def test_does_not_guess_platform_paths_off_macos(self) -> None:
        with (
            patch.object(cli.shutil, "which", return_value=None),
            patch.object(cli.sys, "platform", "linux"),
        ):
            self.assertIsNone(cli._command_path("npx"))


if __name__ == "__main__":
    unittest.main()
