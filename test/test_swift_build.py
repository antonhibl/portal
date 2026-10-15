# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/swift-build.sh drops SwiftPM's download progress updates, nothing else.

A stand-in xcrun replays lines from a real first build, so no test runs Swift.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "tools" / "swift-build.sh"
URL = "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.0538f7535be0-2/GhosttyKit.xcframework.zip"
KEPT = [
    "Fetching https://github.com/Lakr233/libghostty-spm.git",
    "[1/241] Fetching displaylink",
    f"Downloading binary artifact {URL}",
    f"Downloaded {URL} (21.48s)",
    "[36 / 114]",
    "error: something went wrong (1 / 2)",
    "Build complete! (33.24 sec)",
]
PROGRESS = [
    f"[0/100] Downloading {URL} (10 KB / 77.1 MB)",
    f"[37/100] Downloading {URL} (28.6 MB / 77.1 MB)",
    f"[100/100] Downloading {URL} (77.1 MB / 77.1 MB)",
]


class SwiftBuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal swift ")
        self.addCleanup(directory.cleanup)
        self.bin = Path(directory.name)

    def run_wrapper(self, lines, status=0):
        """Run the wrapper with an xcrun that prints LINES, half on stderr."""
        script = "#!/bin/sh\necho \"args: $*\"\n"
        for index, line in enumerate(lines):
            script += f"printf '%s\\n' '{line}'{' >&2' if index % 2 else ''}\n"
        xcrun = self.bin / "xcrun"
        xcrun.write_text(script + f"exit {status}\n")
        xcrun.chmod(0o755)
        environment = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin")
        return subprocess.run(["/bin/sh", WRAPPER, "--product", "portal"], env=environment,
                              capture_output=True, text=True)

    def test_drops_only_download_progress(self):
        lines = KEPT[:3] + PROGRESS + KEPT[3:]
        result = self.run_wrapper(lines)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ["args: swift build --product portal"] + KEPT)
        self.assertEqual(result.stderr, "")

    def test_keeps_the_exit_status(self):
        result = self.run_wrapper(PROGRESS + ["error: no such module"], status=3)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout.splitlines()[1:], ["error: no such module"])

    def test_succeeds_when_every_line_is_dropped(self):
        result = self.run_wrapper(PROGRESS)
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
