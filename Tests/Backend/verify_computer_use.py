#!/usr/bin/env python3
"""User-requested live AX capture regression; sanitized results only."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from verify_shared_adapter import snapshot, gateway_identity

ROOT = Path(__file__).resolve().parents[2]
HERMES = Path.home() / '.hermes'

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'output/runtime-validation/2026-10-03-computer-use.json')
    parser.add_argument('--pid',type=int)
    parser.add_argument('--window-id',type=int)
    args=parser.parse_args()
    if (args.pid is None) != (args.window_id is None): parser.error('Pass both pid and window-id, or neither')
    paths=[HERMES/name for name in ('config.yaml','.env','auth.json','SOUL.md','gateway.pid','gateway.lock')]
    paths+=list((HERMES/'memories').glob('*.md'))
    before,identity=snapshot(paths),gateway_identity()
    with tempfile.TemporaryDirectory(prefix='notch-cua-verify-') as tmp:
        bundle=Path(tmp)/'Resources.bundle';bundle.mkdir()
        for name in ('hermes_bridge.py','hermes_frontend.py','hermes_shared_auth.py','hermes_computer_use.py'):
            shutil.copyfile(ROOT/'Sources/NotchCompanion/Resources'/name,bundle/name)
        result=Path(tmp)/'result.json'
        env=dict(os.environ,NOTCH_SMOKE_RESOURCES=str(bundle))
        if args.pid and args.window_id: env.update(NOTCH_CUA_TEST_PID=str(args.pid),NOTCH_CUA_TEST_WINDOW_ID=str(args.window_id))
        subprocess.run([str(args.executable.resolve()),str(result)],env=env,check=True,timeout=210)
        evidence=json.loads(result.read_text())
    evidence['protected_hermes_files_unchanged']=before==snapshot(paths)
    evidence['messaging_gateway_identity_unchanged']=identity==gateway_identity()
    sys.path.insert(0,str(HERMES/'hermes-agent'))
    from hermes_state import SessionDB
    db=SessionDB(read_only=True)
    try:
        for row in db.get_messages_as_conversation(evidence.get('native_session_id','')):
            if row.get('role')!='tool': continue
            try: data=json.loads(row.get('content',''))
            except (ValueError,TypeError): continue
            if isinstance(data,dict) and data.get('mode')=='ax':
                evidence.update(capture_element_count=data.get('total_elements',0),
                                capture_width=data.get('width',0),capture_height=data.get('height',0),
                                native_ax_capture_nonempty=data.get('total_elements',0)>0)
    finally: db.close()
    args.output.write_text(json.dumps(evidence,indent=2,sort_keys=True)+'\n')
    print(json.dumps(evidence,sort_keys=True))
    required=('native_ax_capture_nonempty','turn_completed','capture_reported_success','computer_use_called','only_requested_tool_called','tool_completed','no_daemon_startup_timeout','protected_hermes_files_unchanged','messaging_gateway_identity_unchanged')
    return 0 if all(evidence.get(k) is True for k in required) else 1

if __name__=='__main__':
    raise SystemExit(main())
