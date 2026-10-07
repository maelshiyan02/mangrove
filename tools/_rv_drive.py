"""Drive the reverse-verification loop: apply fault -> build -> check -> revert.

Usage:
    python tools/_rv_drive.py <fault-id> [<fault-id> ...]
    python tools/_rv_drive.py --all

For each fault it records whether the **targeted** assertion went FAIL. A fault
whose target still passes is reported as NOT DETECTED — that is the whole point:
an assertion nobody can break is a decoration.
"""
import io
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_DIR = os.path.join(ROOT, 'VeneraX')
PY = sys.executable
TOOLS = os.path.join(ROOT, 'tools')
FIXTURE = os.path.join(ROOT, 'ComicLibrary', 'projects', 'S9Fixture',
                       'imgtrans_S9Fixture.json')
RESULTS = os.path.join(ROOT, 'builds', 'reverse_verification.json')


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True,
                          cwd=ROOT, **kw)


def edit_check():
    proc = run([PY, os.path.join(TOOLS, 'run_headless_task.py'),
                'edit-check', FIXTURE,
                '--json', os.path.join(ROOT, 'builds', '_rv_check.json')])
    entries = {}
    for line in proc.stdout.splitlines():
        if '[CLI PRINT]' not in line:
            continue
        payload = json.loads(line.split('[CLI PRINT]', 1)[1])
        if payload.get('message') == 'Check':
            e = payload['data']
            entries[e['name']] = e
    if not entries:
        raise RuntimeError('edit-check produced no checks:\n' +
                           proc.stdout[-2000:] + proc.stderr[-2000:])
    return entries


def build():
    proc = run([PY, os.path.join(TOOLS, 'run_build_task.py')])
    log = io.open(os.path.join(ROOT, 'builds', 'build.log'),
                  encoding='utf-8', errors='replace').read()
    if '=== BUILD_OK ===' not in log:
        errors = [l.strip() for l in log.splitlines() if ' error - ' in l]
        raise RuntimeError('build failed:\n' + '\n'.join(errors[:6]))


def tree_is_clean():
    """True when no source file carries a leftover fault.

    The batch that produced 1/35 had every result shifted by one fault: a run
    killed mid-flight left `.rvbak` files behind, `apply` then reused them as
    the "clean" backup, and `revert` restored an already-faulted file. Faults
    accumulated silently and every measurement was wrong. This check turns that
    class of harness bug into a loud failure.
    """
    hits = []
    # 🔴 `tools/` too: one fault targets the verification harness itself
    # (`@tools/run_headless_task.py`), so a leftover `.rvbak` there would
    # otherwise be invisible.
    for base in (PKG_DIR, os.path.join(ROOT, 'tools')):
        for dirpath, _dirnames, filenames in os.walk(base):
            if '.dart_tool' in dirpath or os.sep + 'build' in dirpath:
                continue
            for name in filenames:
                path = os.path.join(dirpath, name)
                if name.endswith('.rvbak'):
                    hits.append(os.path.relpath(path, ROOT) +
                                ' (stray backup)')
                    continue
                if not (name.endswith('.dart') or name.endswith('.yaml')):
                    continue
                try:
                    with io.open(path, encoding='utf-8') as f:
                        text = f.read()
                except (OSError, UnicodeDecodeError):
                    continue
                # The legitimate mentions live in the assertion set's own prose
                # and in its `known` list.
                for line in text.splitlines():
                    if 'injected fault' not in line:
                        continue
                    if 'docs/P9.6' in line or 'docs/P9.7' in line:
                        continue
                    if line.strip() == "'injected fault',":
                        continue
                    hits.append(
                        f'{os.path.relpath(path, ROOT)}: {line.strip()}')
    return hits


def write_results(results, baseline=None):
    """Persist the report — **after every fault**, not only at the end.

    This file used to be written once, after the loop. The 43/54 batch was
    cancelled mid-flight (these batches take hours and the user stops them),
    so its entire report was lost and `builds/reverse_verification.json` kept
    the *previous* run's numbers — a report that describes a different tree
    and reads as if it were current. That is the failure mode this project
    keeps hitting: a stale number that looks like a measurement.

    Writing per fault costs nothing and makes an interrupted batch partly
    usable instead of actively misleading. `baseline` is recorded so a reader
    can tell whether a target was green *before* the fault.
    """
    undetected = [r['fault'] for r in results if not r['detected']]
    off_target = {r['fault']: r.get('off_target_breakage')
                  for r in results if r.get('off_target_breakage')}
    payload = {'total': len(results), 'undetected': undetected,
               'off_target_breakage': off_target, 'results': results}
    if baseline is not None:
        payload['baseline'] = {
            'checks': len(baseline),
            'fails': [n for n, e in baseline.items() if not e['passed']],
        }
    with io.open(RESULTS, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    return undetected, off_target


def main(argv):
    sys.path.insert(0, TOOLS)
    import _reverse_verify as rv

    ids = argv[1:]
    if ids and ids[0] == '--all':
        ids = sorted(rv.all_faults())
    if not ids:
        print('no faults given')
        return 2

    # 🔴 Refuse to start on a dirty tree. Measuring anything else would produce
    # numbers that look like results and are not.
    dirty = tree_is_clean()
    if dirty:
        print('REFUSING TO START — the source tree is not clean:')
        for hit in dirty:
            print('  ', hit)
        print('Run: python tools/_reverse_verify.py revert <id>  for each '
              'pending id, or delete builds/_rv_backup and the *.rvbak files.')
        return 4

    # Baseline first, so "did it fail?" is measured against a known-good state.
    print('== baseline build ==', flush=True)
    build()
    baseline = edit_check()
    base_fails = [n for n, e in baseline.items() if not e['passed']]
    print('baseline checks:', len(baseline), 'fails:', len(base_fails),
          flush=True)
    if base_fails:
        print('REFUSING TO START — the baseline is not green:', base_fails)
        return 5

    results = []
    for fault_id in ids:
        target = rv.all_faults()[fault_id]
        # 🔴 已知连带：见 `_reverse_verify.EXPECTED_CASCADE`。声明过的连带不算
        # "结果不可信"（那两条断言本来就锁同一行代码）；**没声明**的照样算，
        # 因为那说明测的树不是我们以为的那棵。
        expected = rv.EXPECTED_CASCADE.get(fault_id, set())
        print(f'\n== {fault_id} -> {target} ==', flush=True)
        rc = run([PY, os.path.join(TOOLS, '_reverse_verify.py'),
                  'apply', fault_id]).returncode
        if rc != 0:
            # 3 = anchor/validation refused (the fault cannot be applied
            # cleanly); anything else is an unexpected harness error.
            note = ('anchor not unique or fault already applied'
                    if rc == 3 else f'apply exited {rc}')
            print(f'  APPLY FAILED ({rc}) — skipped: {note}', flush=True)
            results.append({'fault': fault_id, 'target': target,
                            'detected': False, 'note': note})
            write_results(results, baseline)
            continue
        try:
            build()
            entries = edit_check()
            detected = (target in entries and not entries[target]['passed'])
            detail = entries.get(target, {}).get('detail', '(assertion absent)')
            broke = [n for n, e in entries.items()
                     if not e['passed'] and baseline.get(n, {}).get('passed')]
            print(f'  target FAIL: {detected}', flush=True)
            print(f'  detail: {detail[:200]}', flush=True)
            print(f'  also broke: {broke}', flush=True)
            # 🔴 A fault that broke something *other* than its target means the
            # tree was not what we thought it was. Report it rather than
            # counting the run as a clean pass.
            off_target = [n for n in broke if n != target and n not in expected]
            if off_target:
                print(f'  OFF-TARGET BREAKAGE: {off_target}', flush=True)
            cascaded = [n for n in broke if n in expected]
            if cascaded:
                print(f'  expected cascade: {cascaded}', flush=True)
            results.append({'fault': fault_id, 'target': target,
                            'detected': detected,
                            'detail': detail[:400],
                            'also_broke': broke,
                            'expected_cascade': cascaded,
                            'off_target_breakage': off_target})
        except Exception as exc:  # noqa: BLE001 - report and continue
            print('  ERROR:', exc, flush=True)
            results.append({'fault': fault_id, 'target': target,
                            'detected': False, 'note': str(exc)[:300]})
        finally:
            # 🔴 Check the revert's exit status. The old version ignored it
            # completely (`run(...)` and move on), so when the environment's
            # delete guard made `cmd_revert` throw mid-manifest — restore entry
            # one, abandon the rest — the driver printed nothing and the *next*
            # fault was measured against a half-faulted tree. A silent revert
            # failure is worse than a loud one: it turns a bug into a number.
            reverted = run([PY, os.path.join(TOOLS, '_reverse_verify.py'),
                            'revert', fault_id])
            if reverted.returncode != 0 or 'REVERT INCOMPLETE' in reverted.stdout:
                print('  REVERT FAILED (rc=%d):' % reverted.returncode,
                      reverted.stdout.strip()[:400], flush=True)
                if reverted.stderr.strip():
                    print('  stderr:', reverted.stderr.strip()[:400],
                          flush=True)
            leftover = tree_is_clean()
            if leftover:
                print('  TREE NOT CLEAN AFTER REVERT:', leftover, flush=True)
            # 🔴 Per-fault persist — see `write_results`. A run killed here
            # keeps every fault measured so far.
            write_results(results, baseline)

    # Restore a clean build so the next headless run is not on a faulted binary.
    print('\n== restoring clean build ==', flush=True)
    build()
    final_dirty = tree_is_clean()
    if final_dirty:
        print('WARNING — tree still dirty:', final_dirty, flush=True)

    undetected, off_target = write_results(results, baseline)
    print('\n==== reverse verification summary ====')
    print(f'{len(results) - len(undetected)}/{len(results)} faults detected')
    if undetected:
        print('NOT DETECTED (assertion is decorative):')
        for name in undetected:
            print('  ', name)
    if off_target:
        print('OFF-TARGET BREAKAGE (results unreliable):')
        for name, hits in off_target.items():
            print('  ', name, hits)
    print('tree clean at end:', not final_dirty)
    print('report:', RESULTS)
    return 1 if (undetected or off_target or final_dirty) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))