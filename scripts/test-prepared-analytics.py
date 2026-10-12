#!/usr/bin/env python3
"""Numeric analytics regression test; no Messages access or socket required."""
import json
import os
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parent.parent
if not (root / 'ui-probe/MessagesUIProbe').exists():
    print('SKIP: retained historical analytics tests require the retired experimental UI probe')
    raise SystemExit(0)
with tempfile.TemporaryDirectory() as directory:
    records = [dict(mode='append', phase='automatic-rerun', success=True, fetch_ms=value) for value in [1, 2, 3, 4, 100]]
    records.append(dict(mode='append', phase='automatic-rerun', success=False, fetch_ms=9999))
    pathlib.Path(directory, 'prepared-timing.jsonl').write_text('\n'.join(json.dumps(row) for row in records) + '\n')
    result = json.loads(subprocess.check_output([str(root / 'ui-probe/MessagesUIProbe'), 'prepared-analytics'], env=dict(os.environ, PROBE_ANALYTICS_DIR=directory)))
    group = result['groups']['append/automatic-rerun']
    assert group == dict(count=5, average_ms=22, p50_ms=3, p95_ms=100, max_ms=100), group
    assert result['failed_samples'] == 1
    pathlib.Path(directory, 'prepared-timing.jsonl').unlink()
    empty = json.loads(subprocess.check_output([str(root / 'ui-probe/MessagesUIProbe'), 'prepared-analytics'], env=dict(os.environ, PROBE_ANALYTICS_DIR=directory)))
    assert empty['groups'] == {} and empty['failed_samples'] == 0
print('PASS: numeric analytics average/median/p95/max, failure exclusion and empty history')

with tempfile.TemporaryDirectory() as directory:
    rows = [dict(status='restored', observed_disabled_ms=10), dict(status='restored', observed_disabled_ms=30), dict(status='no-observed-update-transition')]
    pathlib.Path(directory, 'ax-experiment.jsonl').write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
    result = json.loads(subprocess.check_output([str(root / 'ui-probe/MessagesUIProbe'), 'ax-stats'], env=dict(os.environ, PROBE_ANALYTICS_DIR=directory)))
    assert result['statuses']['restored'] == 2
    assert result['observed_disabled_samples'] == 2 and result['observed_disabled_average_ms'] == 20
print('PASS: AX analytics exclude unobserved intervals and aggregate numeric outcomes')
