#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run INSIDE the terminal being measured. Python 3 standard library only.
set -euo pipefail
benchmark_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$benchmark_root" "$@" <<'PY'
import argparse
import contextlib
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import select
import shutil
import signal
import statistics
import subprocess
import sys
import termios
import threading
import time
import tty

ROOT = Path(sys.argv[1])
ESC = b"\x1b["
CPR = re.compile(rb"\x1b\[\??\d+;\d+R")
SYNC_REPLY = re.compile(rb"\x1b\[\?2026;([0-4])\$y")


class BenchmarkError(Exception):
    pass


def bounded_number(kind, low, high):
    def parse(value):
        result = kind(value)
        if not math.isfinite(result) or not low <= result <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return result
    return parse


parser = argparse.ArgumentParser(
    prog="./benchmark.sh",
    description="Terminal throughput, protocol latency and frame-supply benchmark.",
    epilog="FPS here means frames submitted and parser-acknowledged, NOT displayed FPS. "
           "Use --trace with --mode frames for a macOS Instruments display trace. "
           "See docs/terminal-benchmark.md. Ctrl-C restores the terminal.")
parser.add_argument("--label", default="terminal", help="e.g. ghostty, portal, ghostel")
parser.add_argument("--notes", default="", help="record font, display refresh rate, power mode or Emacs load")
parser.add_argument("--mode", choices=("all", "throughput", "latency", "frames"), default="all")
parser.add_argument("--runs", type=bounded_number(int, 1, 30), default=3)
parser.add_argument("--mib", type=bounded_number(float, .01, 1024), default=8,
                    help="MiB per throughput case per run (default: 8)")
parser.add_argument("--samples", type=bounded_number(int, 5, 10000), default=100,
                    help="samples per latency case per run (default: 100)")
parser.add_argument("--seconds", type=bounded_number(float, .1, 300), default=3,
                    help="duration per frame trial (default: 3)")
parser.add_argument("--target-fps", type=bounded_number(float, 0, 1000), default=60,
                    help="frame supply target; 0 = uncapped (default: 60)")
parser.add_argument("--timeout", type=bounded_number(float, .1, 60), default=5,
                    help="TTY write/reply timeout in seconds (default: 5)")
parser.add_argument("--scrollback", action="store_true",
                    help="use the main screen, including scrollback cost; default is alternate screen")
parser.add_argument("--pid", type=bounded_number(int, 1, 2147483647),
                    help="host Emacs/Ghostty PID for optional CPU and RSS sampling")
parser.add_argument("--trace", action="store_true",
                    help="record macOS Game Performance trace of --pid (requires Xcode)")
parser.add_argument("--output", type=Path, help="JSON path; default: build/benchmarks/LABEL-TIME.json")
args = parser.parse_args(sys.argv[2:])
if args.trace and (not args.pid or platform.system() != "Darwin"):
    parser.error("--trace requires macOS and --pid HOST_APP_PID")


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def resized(_signum, _frame):
    raise BenchmarkError("Terminal resized during measurement; rerun with a fixed grid.")


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupt)
signal.signal(signal.SIGWINCH, resized)


class Terminal:
    """Nonblocking I/O handles partial writes, input cancellation and timeouts."""
    def __enter__(self):
        try:
            self.fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as error:
            raise BenchmarkError("Run this inside a real interactive terminal, not a batch runner.") from error
        self.saved = termios.tcgetattr(self.fd)
        self.buffer = b""
        self.sync = False
        self.columns, self.rows = os.get_terminal_size(self.fd)
        if self.columns < 20 or self.rows < 6:
            os.close(self.fd)
            raise BenchmarkError("Use a terminal at least 20 columns by 6 rows.")
        try:
            tty.setraw(self.fd, termios.TCSANOW)
            self.write((b"" if args.scrollback else ESC + b"?1049h") + ESC + b"?25l")
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        # Restore even after a reply timeout, SIGTERM or Ctrl-C. Never erase history.
        with contextlib.suppress(OSError, BenchmarkError, KeyboardInterrupt):
            self.write(ESC + b"?2026l" + ESC + b"0m" + ESC + b"?25h"
                       + (b"\r\n" if args.scrollback else ESC + b"?1049l"))
        try:
            termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
            termios.tcflush(self.fd, termios.TCIFLUSH)
        finally:
            os.close(self.fd)

    def read(self):
        try:
            data = os.read(self.fd, 4096)
        except BlockingIOError:
            return
        if not data:
            raise BenchmarkError("Terminal disconnected.")
        if b"\x03" in data:
            raise KeyboardInterrupt
        self.buffer = (self.buffer + data)[-8192:]

    def write(self, data):
        pending = memoryview(data)
        deadline = time.perf_counter() + args.timeout
        while pending:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise BenchmarkError("TTY write timed out.")
            readable, writable, _ = select.select([self.fd], [self.fd], [], remaining)
            if readable:
                self.read()
            if writable:
                try:
                    sent = os.write(self.fd, pending[:65536])
                    pending = pending[sent:]
                except BlockingIOError:
                    pass

    def query(self, request=ESC + b"6n", pattern=CPR, timeout=None):
        self.buffer = b""
        self.write(request)
        deadline = time.perf_counter() + (args.timeout if timeout is None else timeout)
        while True:
            match = pattern.search(self.buffer)
            if match:
                self.buffer = self.buffer[match.end():]
                return match
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise BenchmarkError("Terminal reply timed out (CPR/DECRQM unsupported or terminal stalled).")
            if select.select([self.fd], [], [], remaining)[0]:
                self.read()

    def pause(self, duration):
        deadline = time.perf_counter() + max(0, duration)
        while time.perf_counter() < deadline:
            if select.select([self.fd], [], [], max(0, deadline - time.perf_counter()))[0]:
                self.read()

    def clear(self, title):
        self.write(ESC + b"0m" + ESC + b"2J" + ESC + b"H"
                   + title[:self.columns - 1].encode() + b"\r\n")
        self.query()


def distribution(samples):
    ordered = sorted(samples)
    return {"count": len(samples), "median": statistics.median(samples),
            "p95": ordered[max(0, math.ceil(len(samples) * .95) - 1)],
            "p99": ordered[max(0, math.ceil(len(samples) * .99) - 1)], "max": max(samples)}


def repeated(line, size):
    return line * max(1, size // len(line))  # Keep complete UTF-8 and escape sequences.


def payloads(columns):
    width = columns - 1
    ascii_line = ("0123456789abcdef" * math.ceil(width / 16))[:width].encode() + b"\r\n"
    colored = b"".join(f"\x1b[38;2;{(i*17)%256};{(i*31)%256};{(i*7)%256}mX".encode()
                       for i in range(width)) + ESC + b"0m\r\n"
    # One CJK wide glyph plus one ASCII space = three cells; no font-dependent emoji widths.
    unicode_line = ("界 " * (width // 3)).encode() + b"\r\n"
    return {name: repeated(line, 65536) for name, line in
            (("ascii", ascii_line), ("truecolor", colored), ("unicode", unicode_line))}


def frames(columns, rows):
    # Precompute outside timed sections; no fire simulation/encoding in the hot loop.
    cached = []
    for phase in range(16):
        data = bytearray()
        for row in range(1, rows):
            data.extend(f"\x1b[{row + 1};1H".encode())
            for col in range(0, columns - 1, 4):
                color = 16 + ((row * 13 + col + phase * 7) % 216)
                data.extend(f"\x1b[48;5;{color}m".encode())
                data.extend(b" " * min(4, columns - 1 - col))
        data.extend(ESC + b"0m")
        cached.append(bytes(data))
    return cached


def throughput(term, block):
    target = int(args.mib * 1048576)
    count = max(1, math.ceil(target / len(block)))
    term.write(block)  # Warm parser/glyph cache, excluded from measurement.
    term.query()
    start = time.perf_counter()
    for _ in range(count):
        term.write(block)
    term.query()  # Parser fence: do not time only the producer's final write.
    elapsed = time.perf_counter() - start
    return {"bytes": len(block) * count, "seconds": elapsed,
            "mib_per_s": len(block) * count / 1048576 / elapsed}


def latency(term, block=b""):
    values = []
    for index in range(args.samples + 5):
        term.pause(.005)
        start = time.perf_counter()
        term.write(block)
        term.query()
        elapsed = (time.perf_counter() - start) * 1000
        if index >= 5:
            values.append(elapsed)
    return {"batch_bytes": len(block), "milliseconds": distribution(values), "samples_ms": values}


def animate(term, cached):
    start_sync = ESC + b"?2026h" if term.sync else b""
    end_sync = ESC + b"?2026l" if term.sync else b""
    def submit(index):
        marker = f"\x1b[H\x1b[0mFRAME {index:09d}  target {args.target_fps:g} FPS".encode()
        term.write(start_sync + marker[:term.columns - 1] + cached[index % len(cached)] + end_sync)
        term.query()
    for index in range(3):
        submit(index)
    samples, completed, missed = [], 0, 0
    period = 1 / args.target_fps if args.target_fps else 0
    start = time.perf_counter()
    slot = 0
    while time.perf_counter() - start < args.seconds:
        now = time.perf_counter()
        if period:
            next_due = start + slot * period
            if next_due >= start + args.seconds:
                term.pause(start + args.seconds - now)
                break
            if now > next_due + period:
                skipped = int((now - next_due) / period)
                missed += skipped
                slot += skipped
                next_due = start + slot * period
            if next_due >= start + args.seconds:
                term.pause(start + args.seconds - now)
                break
            term.pause(next_due - now)
        before = time.perf_counter()
        submit(completed)
        samples.append((time.perf_counter() - before) * 1000)
        completed += 1
        slot += 1
    elapsed = time.perf_counter() - start
    return {"acknowledged_fps": completed / elapsed, "frames": completed, "seconds": elapsed,
            "target_fps": args.target_fps, "missed_supply_slots": missed,
            "frame_service_ms": distribution(samples), "samples_ms": samples,
            "displayed_fps": None}


def process_sample(pid):
    fields = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=", "-o", "rss="],
                                     text=True, stderr=subprocess.DEVNULL, timeout=3).split()
    # ps TIME is [[days-]hours:]minutes:seconds[.fraction]. RSS is KiB on macOS/Linux.
    days, clock = (fields[0].split("-", 1) if "-" in fields[0] else ("0", fields[0]))
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return {"time": time.perf_counter(), "cpu_seconds": seconds + int(days) * 86400,
            "rss_mib": int(fields[1]) / 1024}


class Resources:
    def __init__(self):
        self.samples, self.errors = [], []
        self.stop = threading.Event()
        self.thread = None

    def start(self):
        if not args.pid:
            return
        self.samples.append(process_sample(args.pid))
        def sample():
            while not self.stop.wait(.5):
                try:
                    self.samples.append(process_sample(args.pid))
                except (OSError, subprocess.SubprocessError, IndexError, ValueError):
                    self.errors.append("Host process disappeared or could not be sampled.")
                    return
        self.thread = threading.Thread(target=sample, daemon=True)
        self.thread.start()

    def finish(self):
        self.stop.set()
        if not self.thread:
            return None
        self.thread.join(timeout=2)
        try:
            self.samples.append(process_sample(args.pid))
        except (OSError, subprocess.SubprocessError, IndexError, ValueError):
            self.errors.append("Final process sample unavailable.")
        first, last = self.samples[0], self.samples[-1]
        elapsed = last["time"] - first["time"]
        return {"pid": args.pid, "sampled_peak_rss_mib": max(s["rss_mib"] for s in self.samples),
                "cpu_percent_one_core": 100 * (last["cpu_seconds"] - first["cpu_seconds"]) / elapsed
                if elapsed else None, "sample_interval_seconds": .5, "errors": self.errors}


class Trace:
    def __init__(self, output):
        self.path = output.with_suffix(".trace")
        self.log_path = output.with_suffix(".trace.log")
        self.process = self.log = None

    def start(self):
        if not args.trace:
            return
        if not shutil.which("xcrun"):
            raise BenchmarkError("--trace needs Xcode's xcrun/xctrace.")
        self.log = self.log_path.open("x")
        self.process = subprocess.Popen(
            ["xcrun", "xctrace", "record", "--template", "Game Performance", "--attach", str(args.pid),
             "--output", str(self.path), "--no-prompt"], stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise BenchmarkError(f"Instruments could not start; see {self.log_path}")
            log = self.log_path.read_text()
            if "Recording started" in log or "Ctrl-C to stop the recording" in log:
                return
            time.sleep(.2)
        raise BenchmarkError(f"Timed out starting Instruments; see {self.log_path}")

    def finish(self):
        if not self.process:
            return None
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.log.close()
        return {"path": str(self.path), "log": str(self.log_path), "exit_code": self.process.returncode,
                "note": "Open in Instruments and inspect Display timing; no displayed FPS inferred from CPR."}


def main():
    label = re.sub(r"[^A-Za-z0-9._-]+", "-", args.label).strip(".-") or "terminal"
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or ROOT / "build" / "benchmarks" / f"{label}-{stamp}.json").resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Refuse to silently replace earlier measurements.
    with output.open("x") as file:
        file.write("{}\n")
    report = {"schema": 1, "label": args.label, "created_utc": stamp, "complete": False,
              "script_sha256": hashlib.sha256((ROOT / "benchmark.sh").read_bytes()).hexdigest(),
              "platform": platform.platform(), "python": platform.python_version(),
              "environment": {key: os.environ.get(key) for key in
                              ("TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "INSIDE_EMACS", "TMUX", "STY")},
              "settings": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "measurement_notes": ["CPR acknowledges parser progress, not GPU presentation.",
                                    "Reply RTT is not physical key-to-pixel latency.",
                                    "Missed supply slots are not measured display frame drops."],
              "results": {}}
    resources, trace = Resources(), Trace(output)
    status = 0
    try:
        print(f"Benchmark: {args.label}. Keep the terminal visible and grid fixed. Ctrl-C stops.", flush=True)
        trace.start()
        with Terminal() as term:
            report["grid"] = {"columns": term.columns, "rows": term.rows}
            term.query()  # Unsupported terminals fail explicitly, never produce misleading scores.
            try:
                term.sync = term.query(ESC + b"?2026$p", SYNC_REPLY, timeout=.5).group(1) in (b"1", b"2")
            except BenchmarkError:
                term.sync = False
            report["synchronized_output"] = term.sync
            blocks = payloads(term.columns)
            cached = frames(term.columns, term.rows)
            resources.start()
            for run in range(args.runs):
                tasks = []
                if args.mode in ("all", "throughput"):
                    tasks += [(f"throughput_{name}", lambda b=block: throughput(term, b))
                              for name, block in blocks.items()]
                if args.mode in ("all", "latency"):
                    tasks += [("idle_reply", lambda: latency(term)),
                              ("loaded_batch_reply", lambda: latency(term, blocks["truecolor"]))]
                if args.mode in ("all", "frames"):
                    tasks += [("frame_supply", lambda: animate(term, cached))]
                for name, measure in tasks:
                    term.clear(f"{name} {run + 1}/{args.runs}; Ctrl-C stops")
                    term.pause(.1)
                    began = time.time()
                    result = measure()
                    result.update(started_unix=began, finished_unix=time.time())
                    report["results"].setdefault(name, []).append(result)
            report["complete"] = True
    except KeyboardInterrupt:
        report["error"], status = "Interrupted; terminal restored.", 130
    except (BenchmarkError, OSError, subprocess.SubprocessError, ValueError, IndexError) as error:
        report["error"], status = str(error), 1
    finally:
        report["resources"] = resources.finish()
        report["trace"] = trace.finish()
        if report["trace"] and report["trace"]["exit_code"] != 0:
            report["complete"], status = False, status or 1
            report.setdefault("error", "Instruments recording failed; see the trace log.")
        output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"\n{args.label}: median of {args.runs} trials; grid {report.get('grid', 'unavailable')}")
    for name, trials in report["results"].items():
        if name.startswith("throughput_"):
            value = statistics.median(t["mib_per_s"] for t in trials)
            print(f"  {name:24s} {value:9.2f} MiB/s (parser-acknowledged)")
        elif name == "frame_supply":
            value = statistics.median(t["acknowledged_fps"] for t in trials)
            p95 = statistics.median(t["frame_service_ms"]["p95"] for t in trials)
            missed = sum(t["missed_supply_slots"] for t in trials)
            print(f"  frame_supply             {value:9.2f} FPS; service p95 {p95:.2f} ms; missed supply slots {missed}")
        else:
            p50 = statistics.median(t["milliseconds"]["median"] for t in trials)
            p95 = statistics.median(t["milliseconds"]["p95"] for t in trials)
            print(f"  {name:24s} {p50:9.2f} ms p50; {p95:.2f} ms p95")
    if report["resources"]:
        resource = report["resources"]
        cpu = resource['cpu_percent_one_core']
        cpu_text = f"{cpu:.1f}% of one core" if cpu is not None else "unavailable"
        print(f"  host resources           CPU {cpu_text}; "
              f"sampled peak RSS {resource['sampled_peak_rss_mib']:.1f} MiB")
    print("FPS = submitted + parser-acknowledged frames, NOT displayed frames or key-to-pixel latency.")
    if report.get("error"):
        print(f"Incomplete: {report['error']}", file=sys.stderr)
    if report["trace"]:
        print(f"Instruments trace: {report['trace']['path']} (exit {report['trace']['exit_code']})")
    print(f"JSON: {output}")
    return status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, BenchmarkError) as error:
        sys.exit(f"benchmark: {error}")
PY
