#!/usr/bin/env python3
"""Run the production Swift Hermes adapter smoke, retaining only boolean evidence.

Compile the standalone SharedHermesSmoke fixture into the --executable path
first. Uses fresh native test sessions and leaves the original gateway running.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes"


def snapshot(paths):
    return {str(p): hashlib.sha256(p.read_bytes()).digest() if p.exists() else None for p in paths}


def gateway_identity():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(4)
        connection.connect(str(HERMES / "gateway.sock"))
        connection.sendall(b'{"verb":"identify"}\n')
        data = b""
        while not data.endswith(b"\n"):
            data += connection.recv(8192)
    result = json.loads(data)["result"]
    return {key: result.get(key) for key in ("pid", "start_time", "kind", "profile", "code_sha")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "output/runtime-validation/2026-10-03-hermes-adapter.json")
    args = parser.parse_args()
    paths = [HERMES / name for name in ("config.yaml", ".env", "auth.json", "SOUL.md", "gateway.pid", "gateway.lock")]
    before = snapshot(paths)
    identity = gateway_identity()
    with tempfile.TemporaryDirectory(prefix="notch-adapter-verification-") as tmp:
        bundle = Path(tmp) / "Resources.bundle"
        bundle.mkdir()
        for name in ("hermes_bridge.py", "hermes_frontend.py", "hermes_shared_auth.py", "hermes_computer_use.py"):
            shutil.copyfile(ROOT / "Sources/NotchCompanion/Resources" / name, bundle / name)
        output = Path(tmp) / "result.json"
        env = dict(os.environ, NOTCH_SMOKE_RESOURCES=str(bundle))
        subprocess.run([str(args.executable), str(output)], env=env, check=True, timeout=300)
        result = json.loads(output.read_text())
    # Give the exact owned process time to flush and exit; do not signal others.
    time.sleep(2)
    result["protected_files_unchanged"] = before == snapshot(paths)
    result["gateway_identity_unchanged"] = identity == gateway_identity()
    sys.path.insert(0, str(HERMES / "hermes-agent"))
    from hermes_state import SessionDB
    from tools.session_search_tool import session_search
    if sid := result.get("session_id"):
        db = SessionDB(db_path=HERMES / "state.db", read_only=True)
        try:
            row = db.get_session(sid)
            result["normal_store_record"] = bool(row)
            result["source_is_companion"] = (row or {}).get("source") == "notch_companion"
            found = session_search(query="notchadapter", db=db, current_session_id="independent-adapter-verification")
            result["independent_native_search_finds_session"] = sid in found
        finally:
            db.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
