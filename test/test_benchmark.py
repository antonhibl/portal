# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise benchmark I/O using a PTY peer; these are NOT performance scores."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
REQUEST = re.compile(rb"\x1b\[(?:6n|\?2026\$p)")


class BenchmarkTests(unittest.TestCase):
    def run_pty(self, *arguments, reply=True, reply_delay=0, cancel=False, resize=False):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            pid, fd = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                os.execv(str(ROOT / "benchmark.sh"),
                         [str(ROOT / "benchmark.sh"), "--runs", "1", "--mib", ".01",
                          "--samples", "5", "--seconds", ".1", "--timeout", ".3",
                          "--output", str(output), *arguments])
            before = termios.tcgetattr(fd)
            received, pending, queries, status = bytearray(), b"", 0, None
            deadline = time.monotonic() + 15
            try:
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], .05)[0]:
                        try:
                            data = os.read(fd, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not data:
                            break
                        received.extend(data)
                        pending += data
                        while (match := REQUEST.search(pending)):
                            request = match.group()
                            pending = pending[match.end():]
                            queries += 1
                            if cancel and queries == 4:
                                os.write(fd, b"\x03")
                                reply = False
                            elif resize and queries == 4:
                                os.kill(pid, signal.SIGWINCH)
                                reply = False
                            elif reply:
                                time.sleep(reply_delay)
                                answer = b"\x1b[?2026;2$y" if b"2026" in request else b"\x1b[1;1R"
                                # Deliberately split terminal replies across reads.
                                os.write(fd, answer[:3])
                                time.sleep(.001)
                                os.write(fd, answer[3:])
                        pending = pending[-64:]
                    ended, result = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        status = result
                        break
                # PTY EOF can precede waitpid reporting the child's exit.
                while status is None and time.monotonic() < deadline:
                    ended, result = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        status = result
                    else:
                        time.sleep(.01)
                if status is None:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                    self.fail("benchmark did not terminate within 15 seconds")
                after = termios.tcgetattr(fd)
                self.assertEqual(after, before, "TTY attributes were not restored")
                return os.waitstatus_to_exitcode(status), json.loads(output.read_text()), bytes(received)
            finally:
                os.close(fd)

    def test_suite_reports_separate_metrics_and_no_displayed_fps(self):
        code, report, stream = self.run_pty()
        self.assertEqual(code, 0)
        self.assertTrue(report["complete"])
        self.assertEqual(report["grid"], {"columns": 80, "rows": 24})
        self.assertTrue(report["synchronized_output"])
        self.assertEqual(len(report["results"]), 6)
        frame = report["results"]["frame_supply"][0]
        self.assertGreater(frame["acknowledged_fps"], 0)
        self.assertIsNone(frame["displayed_fps"])
        self.assertIn(b"\x1b[?1049h", stream)
        self.assertIn(b"\x1b[?1049l", stream)

    def test_measurement_waits_for_terminal_reply(self):
        code, report, _ = self.run_pty("--mode", "latency", reply_delay=.02)
        self.assertEqual(code, 0)
        idle = report["results"]["idle_reply"][0]["milliseconds"]
        self.assertGreaterEqual(idle["median"], 20)
        self.assertEqual(idle["count"], 5)

    def test_no_reply_fails_instead_of_inventing_score(self):
        code, report, stream = self.run_pty(reply=False)
        self.assertEqual(code, 1)
        self.assertFalse(report["complete"])
        self.assertEqual(report["results"], {})
        self.assertIn("timed out", report["error"])
        self.assertIn(b"\x1b[?1049l", stream)

    def test_ctrl_c_restores_terminal_and_marks_partial_run(self):
        code, report, stream = self.run_pty(cancel=True)
        self.assertEqual(code, 130)
        self.assertFalse(report["complete"])
        self.assertIn(b"\x1b[?25h", stream)
        self.assertIn(b"\x1b[?1049l", stream)

    def test_resize_invalidates_measurement(self):
        code, report, _ = self.run_pty(resize=True)
        self.assertEqual(code, 1)
        self.assertFalse(report["complete"])
        self.assertIn("resized", report["error"])

    def test_scrollback_mode_does_not_switch_screens(self):
        code, report, stream = self.run_pty("--mode", "throughput", "--scrollback")
        self.assertEqual(code, 0)
        self.assertTrue(report["settings"]["scrollback"])
        self.assertNotIn(b"\x1b[?1049h", stream)
        self.assertNotIn(b"\x1b[?1049l", stream)


if __name__ == "__main__":
    unittest.main()
