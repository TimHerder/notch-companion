#!/usr/bin/env python3
"""Run opt-in production AppModel checks and retain sanitized ownership evidence.

Creates clearly titled native Hermes/Codex test conversations. Uses temporary UI
state; never quits/reloads the running app. No tokens, memory text or raw runtime
frames are persisted. Native validation sessions remain for independent lookup.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from verify_shared_hermes import gateway_identity, snapshot

ROOT = Path(__file__).resolve().parents[2]
HERMES = Path.home() / '.hermes'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--models', action='store_true', help='Check model selection, context usage, and resumed selections')
    args = parser.parse_args()
    args.output = args.output or ROOT / ('output/runtime-validation/2026-10-03-model-context.json' if args.models
                                        else 'output/runtime-validation/2026-10-03-app-model.json')
    protected = [HERMES / name for name in ('config.yaml', '.env', 'auth.json', 'SOUL.md', 'gateway.pid', 'gateway.lock')]
    protected += list((HERMES / 'memories').glob('*.md'))
    before, gateway_before = snapshot(protected), gateway_identity()
    env = dict(os.environ)
    if args.models:
        env.update(NOTCH_RUN_LIVE_MODEL_TESTS='1', NOTCH_MODEL_LIVE_EVIDENCE=str(args.output.resolve()))
    else:
        env.update(NOTCH_RUN_LIVE_RUNTIME_TESTS='1', NOTCH_LIVE_EVIDENCE=str(args.output.resolve()))
    test = 'RuntimeLiveTests/testModelSelectionAndContext' if args.models else 'RuntimeLiveTests/testNativeConversationsThroughAppModel'
    result = subprocess.run(['xcrun', 'swift', 'test', '--filter', test], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
    evidence = json.loads(args.output.read_text()) if result.returncode == 0 and args.output.exists() else {}
    evidence.update(app_model_live_passed=result.returncode == 0,
                    protected_hermes_files_unchanged=before == snapshot(protected),
                    messaging_gateway_identity_unchanged=gateway_before == gateway_identity(),
                    test_scope='Production AppModel and adapters; temporary UI registry; no running app relaunch')
    args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
    print(json.dumps({key: value for key, value in evidence.items() if key not in ('app_model_native_sessions', 'model_context_sessions')}, sort_keys=True))
    if result.returncode or not evidence['protected_hermes_files_unchanged'] or not evidence['messaging_gateway_identity_unchanged']:
        for line in result.stdout.splitlines():
            if 'RuntimeLiveTests.swift:' in line and 'error:' in line:
                print(line, file=sys.stderr)
        print('App-model live validation failed; raw runtime logs were not saved.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
