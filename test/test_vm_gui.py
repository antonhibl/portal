# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("vm_gui", Path(__file__).with_name("vm-gui.py"))
vm_gui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm_gui)


class VmGuiTests(unittest.TestCase):
    def test_sync_includes_working_changes_without_git_or_ignored_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            target = Path(temporary) / "target"
            root.mkdir()
            target.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text("build/\nnode_modules/\n")
            (root / "tracked").write_text("original")
            (root / "deleted").write_text("removed locally")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            (root / "tracked").write_text("uncommitted")
            (root / "deleted").unlink()
            (root / "new file\nwith newline").write_text("new")
            (root / "build").mkdir()
            (root / "build" / "host.dylib").write_text("wrong machine")
            (root / "link").symlink_to("tracked")
            subprocess.run(
                ["rsync", "-a", "--from0", "--files-from=-", "./", str(target) + "/"],
                cwd=root, input=vm_gui.source_files(root), check=True,
            )
            self.assertEqual((target / "tracked").read_text(), "uncommitted")
            self.assertEqual((target / "new file\nwith newline").read_text(), "new")
            self.assertTrue((target / "link").is_symlink())
            self.assertEqual(
                {p.name for p in target.iterdir()},
                {".gitignore", "tracked", "new file\nwith newline", "link"},
            )

    def test_stage_preserves_arguments_exit_status_and_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (root / "lock").open("w") as lock:
                result = vm_gui.run_stage(
                    [sys.executable, "-c", "import sys; print(sys.argv[1]); sys.exit(7)",
                     "a quote ' and $(not-a-shell)"],
                    root, root / "test.log", 5, lock.fileno(),
                )
            self.assertEqual(result, 7)
            self.assertEqual((root / "test.log").read_text(), "a quote ' and $(not-a-shell)\n")

    def test_unlaunchable_command_records_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = root / "not-executable"
            command.write_text("#!/bin/sh\nexit 0\n")
            with (root / "lock").open("w") as lock:
                result = vm_gui.run_stage(
                    [str(command)], root, root / "test.log", 5, lock.fileno(),
                )
            self.assertEqual(result, 126)
            self.assertIn("Permission denied", (root / "test.log").read_text())

    def test_timeout_stops_the_process_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            program = (
                "import os, pathlib, subprocess, sys, time; "
                "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                "pathlib.Path('pid').write_text(str(os.getpid())); time.sleep(60)"
            )
            with (root / "lock").open("w") as lock:
                result = vm_gui.run_stage(
                    [sys.executable, "-c", program], root, root / "test.log", 1,
                    lock.fileno(),
                )
            self.assertEqual(result, 124)
            pid = int((root / "pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.killpg(pid, 0)


if __name__ == "__main__":
    unittest.main()
