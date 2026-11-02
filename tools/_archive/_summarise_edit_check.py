"""Summarise an `edit-check` run from `run_headless_task.py` stdout.

Reads the `[CLI PRINT]` stream and prints one line per failure plus the tally.
Empty input is treated as an error, not as "0 checks, all fine" — that is the
P9.3 lesson applied to this script itself.
"""
import json
import sys

fails = []
total = 0
final = None

for line in sys.stdin:
    if '[CLI PRINT]' not in line:
        continue
    payload = json.loads(line.split('[CLI PRINT]', 1)[1])
    if payload.get('message') == 'Check':
        entry = payload['data']
        total += 1
        if not entry['passed']:
            fails.append(entry)
    elif payload.get('status') in ('success', 'error'):
        final = payload

if total == 0:
    print('NO CHECKS PARSED -- the run produced nothing to judge')
    sys.exit(2)

print('total', total, 'fails', len(fails))
if final is not None:
    print('FINAL:', final['status'], final['message'])
for entry in fails:
    print('  FAIL', entry['name'], '|', entry['detail'][:260])

sys.exit(0 if not fails else 1)