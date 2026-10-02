#!/usr/bin/env python3
"""Agent discovery spike: run an agent CLI in a headless pseudo-terminal,
answer the terminal queries Ghostty would answer, drive it with a scripted
scenario, and record terminal signals (OSC titles, progress, notifications,
BEL, modes) plus optional `claude agents --json` status samples, all on one
monotonic clock.  See docs/agent-discovery-research.md.

usage: capture.py OUT_PREFIX SCENARIO.json -- COMMAND...
Needs pyte (pip install pyte).  Run it from a shell outside Claude Code, or
the agent sees CLAUDECODE variables.  The scenario's cwd defaults to the
current directory; $VARS and ~ expand in cwd, env values and typed text.
Writes OUT_PREFIX.jsonl (events), OUT_PREFIX.raw (output bytes, which can be
replayed with cat but hold whole screens: do not commit them) and
OUT_PREFIX.screens.txt (screen snapshots at marks).  Exits 1 when the capture
is incomplete: a required wait timed out, or the program exited while steps
that observe it (waits, marks, process or status samples) remained."""
import json, os, pty, re, select, signal, subprocess, sys, threading, time, codecs, fcntl, termios, struct
import pyte

T0 = time.monotonic()
def now():
    return round(time.monotonic() - T0, 3)

out_prefix, script_path = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index('--') + 1:]
script = json.load(open(script_path))
cols, rows = 120, 40

env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG') if k in os.environ}
env['PATH'] = script.get('path', os.environ['PATH'])
env.update({'SHELL': '/bin/zsh', 'TERM': 'xterm-ghostty', 'TERM_PROGRAM': 'ghostty',
            'TERM_PROGRAM_VERSION': '1.3.2-HEAD-+82938b633', 'COLORTERM': 'truecolor',
            'INSIDE_EMACS': 'portal-ghostty', 'PORTAL_TERMINAL': 'spike:1'})
env.update({k: os.path.expandvars(v) for k, v in script.get('env', {}).items()})
cwd = os.path.expanduser(os.path.expandvars(script.get('cwd', os.getcwd())))

events = open(out_prefix + '.jsonl', 'w')
raw = open(out_prefix + '.raw', 'wb')
screens = open(out_prefix + '.screens.txt', 'w')
lock = threading.Lock()
def log(kind, **fields):
    with lock:
        events.write(json.dumps({'t': now(), 'kind': kind, **fields}) + '\n')
        events.flush()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvpe(cmd[0], cmd, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
log('spawn', pid=pid, cmd=cmd, cwd=cwd)

screen = pyte.Screen(cols, rows)
stream = pyte.Stream(screen)
def reply(data):
    os.write(fd, data.encode() if isinstance(data, str) else data)
screen.write_process_input = lambda data: reply(data)
decoder = codecs.getincrementaldecoder('utf-8')('replace')

OSC = re.compile(rb'\x1b\](\d+)(?:;([^\x07\x1b]*))?(?:\x07|\x1b\\)')
MODE = re.compile(rb'\x1b\[\?([\d;]+)([hl])')
QUERIES = [
    # no kitty keyboard reply: Ink then falls back to legacy keys
    (re.compile(rb'\x1b\[>0?q'), b'\x1bP>|ghostty 1.3.2\x1b\\'),
    (re.compile(rb'\x1b\[>0?c'), b'\x1b[>1;10;0c'),
    (re.compile(rb'\x1b\[14t'), b'\x1b[4;800;1200t'),
    (re.compile(rb'\x1b\[16t'), b'\x1b[6;20;10t'),
    (re.compile(rb'\x1b\[18t'), ('\x1b[8;%d;%dt' % (rows, cols)).encode()),
]
pending = b''
focus_reporting = False
def scan(data):
    """Log signals and answer queries in DATA, keeping a partial tail."""
    global pending, focus_reporting
    buf = pending + data
    for m in OSC.finditer(buf):
        code, payload = m.group(1).decode(), (m.group(2) or b'').decode('utf-8', 'replace')
        if code in ('10', '11', '12') and payload == '?':
            reply('\x1b]%s;rgb:%s\x1b\\' % (code, 'ffff/ffff/ffff' if code != '11' else '1c1c/1c1c/1c1c'))
            continue
        if code == '4' and payload.endswith('?'):
            continue
        log('osc', code=code, payload=payload[:200])
    for m in MODE.finditer(buf):
        for mode in m.group(1).decode().split(';'):
            if mode in ('1004', '2004', '1049', '2026', '1000', '1002', '1003', '1006', '25', '1', '2031', '2048'):
                if mode == '1004':
                    focus_reporting = m.group(2) == b'h'
                log('mode', mode=mode, set=m.group(2) == b'h')
    for rx, answer in QUERIES:
        for _ in rx.finditer(buf):
            reply(answer)
    for m in re.finditer(rb'\x1b\[\?(\d+)\$p', buf):
        reply(b'\x1b[?' + m.group(1) + b';2$y')
    # Bare BEL outside OSC.
    stripped = OSC.sub(b'', buf)
    if b'\x07' in stripped:
        log('bel', count=stripped.count(b'\x07'))
    cut = buf.rfind(b'\x1b')
    pending = buf[cut:] if cut != -1 and len(buf) - cut < 512 and not OSC.search(buf[cut:]) else b''

alive = True
def reader():
    global alive
    while alive:
        try:
            r, _, _ = select.select([fd], [], [], 0.05)
        except OSError:
            break
        if not r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b''
        if not data:
            alive = False
            break
        with lock:
            raw.write(data)
        scan(data)
        with lock:
            stream.feed(decoder.decode(data))
threading.Thread(target=reader, daemon=True).start()

def screen_text():
    with lock:
        return '\n'.join(line.rstrip() for line in screen.display)

def snapshot(label):
    with lock:
        screens.write('==== %s @ %.3f\n%s\n' % (label, now(), '\n'.join(l.rstrip() for l in screen.display)))
        screens.flush()

sampler_on = script.get('claude_status', False)
def agents_json():
    try:
        p = subprocess.run(['claude', 'agents', '--json'], capture_output=True, text=True, timeout=10,
                           env={**env, 'TERM': 'dumb'})
        return json.loads(p.stdout)
    except Exception as e:
        return {'error': str(e)}

def proc_tree():
    """Descendants of the spawned process: pid, pgid, comm, argv[0..1]."""
    p = subprocess.run(['ps', '-ax', '-o', 'pid=,ppid=,pgid=,tpgid=,stat=,comm='], capture_output=True, text=True)
    rows_ = [l.split(None, 5) for l in p.stdout.splitlines()]
    kids = {}
    for r in rows_:
        if len(r) == 6:
            kids.setdefault(int(r[1]), []).append(r)
    out, todo = [], [pid]
    me = [r for r in rows_ if len(r) == 6 and int(r[0]) == pid]
    out += me
    while todo:
        for r in kids.get(todo.pop(), []):
            out.append(r); todo.append(int(r[0]))
    return [' '.join(r) for r in out]

last_status = None
def sampler():
    global last_status
    while alive and sampler_on:
        data = agents_json()
        mine = [s for s in data if isinstance(s, dict) and s.get('pid') == pid] if isinstance(data, list) else data
        status = mine[0].get('status') if mine and isinstance(mine, list) else ('absent' if isinstance(data, list) else 'error')
        if status != last_status:
            log('claude_status', status=status, entry={k: v for k, v in (mine[0] if mine and isinstance(mine, list) else {}).items()
                                                       if k in ('status', 'kind', 'statusUpdatedAt', 'updatedAt', 'name', 'startedAt')})
            last_status = status
        time.sleep(script.get('status_interval', 0.5))
threading.Thread(target=sampler, daemon=True).start()

KEYS = {'enter': '\r', 'esc': '\x1b', 'up': '\x1b[A', 'down': '\x1b[B', 'tab': '\t',
        'ctrl-c': '\x03', 'ctrl-d': '\x04', 'space': ' ', 'shift-tab': '\x1b[Z', 'alt-enter': '\x1b\r'}
def run_step(step):
    if 'mark' in step:
        log('mark', label=step['mark']); snapshot(step['mark'])
    if 'sleep' in step:
        time.sleep(step['sleep'])
    if 'wait_text' in step:
        rx = re.compile(step['wait_text'], re.S)
        deadline = time.monotonic() + step.get('timeout', 60)
        while time.monotonic() < deadline and alive:
            if rx.search(screen_text()):
                log('seen', pattern=step['wait_text']); break
            time.sleep(0.1)
        else:
            log('timeout', pattern=step['wait_text']); snapshot('timeout ' + step['wait_text'])
            if step.get('required', True) and alive:
                return False
    if 'type' in step:
        for ch in os.path.expandvars(step['type']):
            reply(ch); time.sleep(0.02)
    if 'key' in step:
        reply(KEYS[step['key']])
    if 'focus' in step:
        log('focus', state=step['focus'], reporting=focus_reporting)
        reply('\x1b[I' if step['focus'] == 'in' else '\x1b[O')
    if step.get('tree'):
        log('tree', procs=proc_tree())
    if step.get('agents'):
        log('agents', data=agents_json())
    return True

INPUT_KEYS = {'type', 'key', 'focus', 'sleep'}
ok = True
for index, step in enumerate(script['steps']):
    if not alive:
        log('exited_early')
        # Leftover input, such as a second quit key, is harmless; a step that
        # would have observed the program means the trace is incomplete.
        if any(set(rest) - INPUT_KEYS for rest in script['steps'][index:]):
            ok = False
        break
    if not run_step(step):
        ok = False; break

deadline = time.monotonic() + script.get('exit_timeout', 10)
while alive and time.monotonic() < deadline:
    time.sleep(0.1)
if alive:
    log('kill'); os.kill(pid, signal.SIGTERM); time.sleep(1)
    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
alive = False
try:
    _, status = os.waitpid(pid, 0)
    log('exit', status=status)
except ChildProcessError:
    pass
snapshot('final')
if sampler_on:
    data = agents_json()
    log('agents_after_exit', present=any(isinstance(s, dict) and s.get('pid') == pid for s in data) if isinstance(data, list) else data)
print('ok' if ok else 'FAILED', out_prefix)
sys.exit(0 if ok else 1)
