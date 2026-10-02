#!/usr/bin/env python3
"""Collapse a ptyrun trace: spinner title runs become one line with a frame count."""
import json, re, sys
SPIN = re.compile(r'^[⠀-⣿◐-◓✳·✢✶✻✽*]\s*')
for path in sys.argv[1:]:
    print('#####', path)
    run = None
    def flush():
        global run
        if run:
            print('%7.3f-%7.3f title x%-3d %s' % (run[0], run[1], run[2], run[3]))
        run = None
    for line in open(path):
        e = json.loads(line)
        k = e['kind']
        if k == 'mode' or (k == 'osc' and e['code'] == '8'):
            continue
        if k == 'osc' and e['code'] in ('0', '2'):
            p = e['payload']
            braille = re.sub(r'[⠀-⣿]', '⣿', p)
            key = braille
            if run and run[3] == key:
                run[1] = e['t']; run[2] += 1; continue
            flush(); run = [e['t'], e['t'], 1, key]; continue
        flush()
        rest = {x: e[x] for x in e if x not in ('t', 'kind')}
        if k == 'tree':
            rest = {'procs': [p[:90] for p in e['procs']][:6]}
        if k == 'agents':
            rest = {'n': len(e['data'])}
        print('%7.3f %-13s %s' % (e['t'], k, json.dumps(rest, ensure_ascii=False)[:180]))
    flush()
