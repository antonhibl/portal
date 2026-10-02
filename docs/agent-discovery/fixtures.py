#!/usr/bin/env python3
"""Write compact, sanitized replay fixtures from the spike's raw traces.
usage: fixtures.py OUT_DIR RUNS_DIR SCRATCH_DIR
RUNS_DIR holds capture.py traces and the graphical runs' traces under the
names used below; SCRATCH_DIR is replaced by $SCRATCH in every string."""
import json, os, re, sys
OUT, R, SCRATCH = sys.argv[1], sys.argv[2].rstrip('/') + '/', os.path.realpath(sys.argv[3])
HOME = os.path.expanduser('~')

def clean(value):
    if isinstance(value, str):
        value = value.replace('/private' + SCRATCH if not SCRATCH.startswith('/private') else SCRATCH, '$SCRATCH')
        value = value.replace(SCRATCH, '$SCRATCH').replace('$SCRATCH/probe/..', '$SCRATCH')
        value = value.replace(HOME, '~')
        return value
    if isinstance(value, list):
        return [clean(v) for v in value]
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    return value

def pty_events(path, until=None):
    """Signals from a ptyrun trace: titles, notifications, progress, BEL, OSC 133, marks, Claude status."""
    out = []
    for line in open(path):
        e = json.loads(line)
        if until is not None and e['t'] > until:
            break
        k = e['kind']
        if k == 'osc':
            code, payload = e['code'], e['payload']
            if code == '8':
                continue
            if code in ('0', '2'):
                out.append({'t': e['t'], 'kind': 'title', 'title': payload})
            elif code == '9' and payload.startswith('4;'):
                parts = payload.split(';')
                out.append({'t': e['t'], 'kind': 'progress', 'state': int(parts[1]),
                            **({'percent': int(parts[2])} if len(parts) > 2 and parts[2] else {})})
            elif code == '9':
                out.append({'t': e['t'], 'kind': 'notification', 'osc': 9, 'body': payload})
            elif code == '777':
                _, title, body = (payload.split(';', 2) + ['', ''])[:3]
                out.append({'t': e['t'], 'kind': 'notification', 'osc': 777, 'title': title, 'body': body})
            elif code == '133':
                out.append({'t': e['t'], 'kind': 'semantic_prompt', 'mark': payload})
            continue
        if k == 'bel':
            out.append({'t': e['t'], 'kind': 'bell', 'count': e['count']})
        elif k == 'mark':
            out.append({'t': e['t'], 'kind': 'step', 'label': e['label']})
        elif k == 'focus':
            out.append({'t': e['t'], 'kind': 'focus', 'state': e['state'], 'reporting': e['reporting']})
        elif k == 'claude_status':
            out.append({'t': e['t'], 'kind': 'claude_agents_status', 'status': e['status']})
        elif k == 'spawn':
            out.append({'t': e['t'], 'kind': 'spawn', 'argv': e['cmd'][:1] + [a for a in e['cmd'][1:] if not a.startswith('/')]})
        elif k == 'exit':
            out.append({'t': e['t'], 'kind': 'exit', 'wait_status': e['status']})
        elif k == 'mode' and e['mode'] == '1004':
            out.append({'t': e['t'], 'kind': 'focus_reporting', 'enabled': e['set']})
        elif k in ('timeout', 'kill'):
            out.append({'t': e['t'], 'kind': 'harness_' + k})
    return out

def pi_events(path, offset):
    rows = [json.loads(l) for l in open(path)]
    t0 = rows[0]['wall']
    return [{'t': round((r['wall'] - t0) / 1000 + offset, 3), 'kind': 'pi_event', 'event': r['event'], 'idle': r['idle']}
            for r in rows if r['event'] not in ('turn_start', 'turn_end', 'input')]

def write(name, meta, events):
    events = sorted(events, key=lambda e: e['t'])
    with open(os.path.join(OUT, name), 'w') as f:
        f.write(json.dumps(clean(meta), ensure_ascii=False) + '\n')
        for e in events:
            f.write(json.dumps(clean(e), ensure_ascii=False) + '\n')
    print(name, len(events))

ENV = {'TERM': 'xterm-ghostty', 'TERM_PROGRAM': 'ghostty', 'TERM_PROGRAM_VERSION': '1.3.2-HEAD-+82938b633',
       'COLORTERM': 'truecolor', 'INSIDE_EMACS': 'portal-ghostty', 'size': '120x40'}
def meta(harness, version, scenario, **kw):
    return {'fixture': 'agent-signals', 'harness': harness, 'version': version, 'scenario': scenario,
            'source': 'headless pty (test harness answers terminal queries)', 'clock': 't = seconds since spawn',
            'terminal': ENV, 'recorded': '2026-10-02', **kw}

write('claude-lifecycle.jsonl', meta('claude', '2.1.287', 'first prompt, approved and denied permission, cancel, /exit', model='haiku', status_poll_s=0.4),
      pty_events(R + 'claude2.jsonl'))
write('claude-idle-notification.jsonl', meta('claude', '2.1.287', 'turn while unfocused, then the 60 s idle notification', model='haiku'),
      pty_events(R + 'claude1.jsonl', until=81))
write('claude-trust-dialog.jsonl', meta('claude', '2.1.287', 'untrusted folder: trust dialog, declined'), pty_events(R + 'claude-trust.jsonl'))
write('claude-model-error.jsonl', meta('claude', '2.1.287', 'turn fails: unknown model'), pty_events(R + 'claude-fail2.jsonl'))
write('claude-queued-compact.jsonl', meta('claude', '2.1.287', 'message queued during a tool call, then /compact', model='haiku'),
      pty_events(R + 'claude-queue.jsonl'))
write('codex-turn-notification.jsonl', meta('codex', '0.155.1', 'first prompt and a turn while unfocused; sandboxed command ran without approval', reasoning='low'),
      pty_events(R + 'codex1.jsonl', until=40))
write('codex-approval.jsonl', meta('codex', '0.155.1', 'approved and denied escalation, cancel, /quit', reasoning='low'), pty_events(R + 'codex2.jsonl'))
write('codex-model-error.jsonl', meta('codex', '0.155.1', 'turn fails: unknown model, then a model-switch menu waits'), pty_events(R + 'codex-fail.jsonl'))
write('pi-provider-error.jsonl', meta('pi', '0.87.0', 'trust dialog, then turns that fail on an expired OAuth token',
                                       pi_events='lifecycle from a logging extension; t aligned to the first title'),
      pty_events(R + 'pi1.jsonl') + pi_events(R + 'pi1.lifecycle.jsonl', 4.2))
write('pi-turns.jsonl', meta('pi', '0.87.0', 'trust dialog, a turn, a tool turn with a queued follow-up, a short turn', model='openrouter/anthropic/claude-haiku-4.5',
                              pi_events='lifecycle from a logging extension; t aligned to the first title'),
      pty_events(R + 'pi2.jsonl') + pi_events(R + 'pi2.lifecycle.jsonl', 4.19))
write('pi-progress-extension.jsonl', meta('pi', '0.87.0', 'Portal-style extension reporting OSC 9;4: a tool turn, a cancelled turn, exit',
                                          model='openrouter/anthropic/claude-haiku-4.5', pi_events='lifecycle from a logging extension; t aligned to the baseline report'),
      pty_events(R + 'pi4.jsonl') + pi_events(R + 'pi4.lifecycle.jsonl', 2.191))

def gui(native, lisp, name, scenario):
    n = [json.loads(l) for l in open(R + native)]
    l = [json.loads(x) for x in open(R + lisp)]
    t0 = min(n[0]['wall'], l[0]['wall'])
    out = []
    for e in n:
        rec = {'t': round(e['wall'] - t0, 3), 'source': 'native', 'target': e['target'], 'kind': e['event']}
        rec.update({k: v for k, v in e.items() if k not in ('wall', 'mono_ns', 'target', 'event')})
        out.append(rec)
    for e in l:
        if e['event'] in ('scan_stats',):
            continue
        rec = {'t': round(e['wall'] - t0, 3), 'source': 'lisp', 'kind': e['event']}
        rec.update({k: v for k, v in e.items() if k not in ('wall', 'event')})
        out.append(rec)
    write(name, {'fixture': 'portal-gui', 'scenario': scenario, 'source': 'graphical emacs -Q, Portal build with spike instrumentation',
                 'clock': 't = seconds since the first record', 'versions': {'claude': '2.1.287', 'codex': '0.155.1', 'pi': '0.87.0',
                 'emacs': '31.1', 'ghostty': '82938b633ba6 (libghostty-spm 1.6.20260909)'}, 'recorded': '2026-10-02'}, out)

gui('gui-native.jsonl', 'gui-lisp.jsonl', 'portal-run-discovery.jsonl', 'run 1: discovery, controls, Claude activity, Codex, Pi, quick terminal, exit/relaunch, close')
gui('gui2-native.jsonl', 'gui2-lisp.jsonl', 'portal-run-triggers.jsonl', 'run 2: progress trigger, Pi at trust dialog, Codex exit, change-record cost')
