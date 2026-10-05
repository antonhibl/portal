#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Copy this checkout to a macOS desktop VM, build it, and run a GUI command."""

import argparse
import fcntl
import math
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys


def source_files(root):
    """Include tracked edits and new source files, excluding ignored outputs."""
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    ).split(b"\0")
    return b"\0".join(
        name for name in dict.fromkeys(names)
        if name and os.path.lexists(os.fsencode(root) + b"/" + name)
    ) + b"\0"


def run_stage(command, root, log, timeout, lock_fd):
    print(f"Running {shlex.join(command)} (limit {timeout:g}s)", flush=True)
    with log.open("wb") as output:
        try:
            process = subprocess.Popen(
                command, cwd=root, stdin=subprocess.DEVNULL, stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(lock_fd,),
            )
        except OSError as error:
            output.write(f"Could not launch {command[0]}: {error}\n".encode())
            return 127 if isinstance(error, FileNotFoundError) else 126
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"Timed out; see {log}", flush=True)
            return 124
        finally:
            # Stop descendants after completion, timeout or a delivered signal.
            try:
                # These are disposable processes, including descendants that
                # ignore SIGTERM.
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def guest(run, command, timeout):
    run = Path(run).resolve()
    if run.parent != (Path.home() / "portal-test-runs").resolve() or not run.name.startswith("run."):
        raise ValueError("Guest runs must be inside ~/portal-test-runs/run.*")
    root = run / "repo"
    os.environ["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    os.environ["EMACS"] = "/Applications/Emacs.app/Contents/MacOS/Emacs"

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    # All invocations share one Aqua desktop, even though their files are unique.
    with (run.parent / ".desktop.lock").open("a") as lock:
        print("Waiting for the VM desktop…", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        console_user = subprocess.check_output(
            ["stat", "-f", "%Su", "/dev/console"], text=True,
        ).strip()
        if console_user != os.environ["USER"]:
            raise RuntimeError("Log in to the VM desktop as the SSH user first")
        if shutil.disk_usage(run).free < 5 * 1024**3:
            raise RuntimeError("The VM needs at least 5 GiB free for a fresh build")
        awake = subprocess.Popen(["caffeinate", "-disu", "-w", str(os.getpid())])
        try:
            result = run_stage(["./build.sh"], root, run / "build.log", timeout, lock.fileno())
            if result == 0:
                # Direct SSH launches bypass LaunchServices' app environment.
                # Keep Homebrew's native compiler library paths for Emacs -Q.
                with Path("/Applications/Emacs.app/Contents/Info.plist").open("rb") as info:
                    library_path = plistlib.load(info).get("LSEnvironment", {}).get("LIBRARY_PATH")
                if library_path:
                    os.environ["LIBRARY_PATH"] = library_path
                result = run_stage(command, root, run / "test.log", timeout, lock.fileno())
            (run / "exit-status").write_text(f"{result}\n")
            if result == 0:
                shutil.rmtree(root)
            return result if result >= 0 else 128 - result
        finally:
            awake.terminate()
            awake.wait()


def host(args):
    root = Path(__file__).resolve().parent.parent
    if args.host.startswith("-") or any(c.isspace() for c in args.host):
        raise ValueError("Use an SSH host alias or user@hostname")
    ssh = ["ssh", "-T", "-o", "BatchMode=yes", args.host]
    run = subprocess.check_output(
        ssh + ['umask 077; mkdir -p "$HOME/portal-test-runs" && '
               'mktemp -d "$HOME/portal-test-runs/run.XXXXXXXX"'], text=True,
    ).strip()
    if not run.startswith("/") or "\n" in run:
        raise RuntimeError(f"Unexpected VM run path: {run!r}")
    logs = root / ".cache" / "vm-gui" / Path(run).name
    logs.mkdir(parents=True, exist_ok=False)
    (logs / "remote.txt").write_text(f"{args.host}:{run}\n")
    print(f"VM run: {args.host}:{run}\nLocal logs: {logs}", flush=True)
    subprocess.run(
        ["rsync", "-a", "--from0", "--files-from=-", "-e", "ssh -o BatchMode=yes",
         "./", f"{args.host}:{shlex.quote(run + '/repo/')}"],
        cwd=root, input=source_files(root), check=True,
    )
    command = args.command or ["sh", "test/launcher-daily-use.sh"]
    if command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("Supply a command after --")
    remote = shlex.join([
        "/opt/homebrew/bin/python3", run + "/repo/test/vm-gui.py", "--guest",
        run, "--timeout", str(args.timeout), "--", *command,
    ])
    try:
        return subprocess.call(ssh + [remote])
    finally:
        # Failed runs retain their source/build tree in the guest for diagnosis.
        fetched = subprocess.call([
            "rsync", "-a", "-e", "ssh -o BatchMode=yes", "--include=/*.log",
            "--include=/exit-status", "--exclude=*",
            f"{args.host}:{shlex.quote(run + '/')}", str(logs) + "/",
        ])
        if fetched:
            print(f"Could not fetch logs; retained at {args.host}:{run}", file=sys.stderr)
        print(f"Logs: {logs}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("PORTAL_TEST_VM", "portal-vm"))
    parser.add_argument("--timeout", type=float, default=1200,
                        help="seconds per build/test stage after acquiring the desktop")
    parser.add_argument("--guest", help=argparse.SUPPRESS)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if args.guest:
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        return guest(args.guest, command, args.timeout)
    return host(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
