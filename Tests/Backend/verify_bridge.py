#!/usr/bin/env python3
"""Exercise the installed runtime in temporary private state.

Use --live to send small real provider requests. Never logs source credentials.
Source config/auth hashes are compared only in memory and reported as booleans.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE_HOME = Path.home() / ".hermes"
SOURCE = SOURCE_HOME / "hermes-agent"
BRIDGE = ROOT / "Sources/NotchCompanion/Resources/hermes_bridge.py"


def source_snapshot():
    return {str(path): hashlib.sha256(path.read_bytes()).digest()
            for path in (SOURCE_HOME / name for name in ("config.yaml", ".env", "auth.json", "gateway.pid", "gateway.lock"))
            if path.is_file()}


def gateway_identity():
    path = SOURCE_HOME / "gateway.pid"
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text())
        pid = int(value["pid"] if isinstance(value, dict) else value)
    except (ValueError, KeyError):
        return path.read_bytes()
    return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "pid=,lstart="]).decode().strip()


class Backend:
    def __init__(self, home):
        profile = f'(version 1)(allow default)(deny file-write* (subpath {json.dumps(str(SOURCE_HOME))}))'
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1"}
        env.pop("PYTHONPATH", None)
        env.pop("PYTHONHOME", None)
        self.process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile,
            str(SOURCE / "venv/bin/python"), "-B", "-u", str(BRIDGE), "--source", str(SOURCE),
            "--source-home", str(SOURCE_HOME), "--app-home", str(home)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env)
        self.queue = queue.Queue()
        self.events = []
        self.stderr_tail = []
        self.identifier = 0
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=self.drain_stderr, daemon=True).start()
        self.wait_event("gateway.ready", timeout=60)

    def read(self):
        for line in self.process.stdout:
            try:
                self.queue.put(json.loads(line))
            except ValueError:
                pass
        self.queue.put({"eof": True})

    def drain_stderr(self):
        for line in self.process.stderr:
            # Only keep noncredential diagnostic categories, never arbitrary logs.
            if "Traceback" in line or "Error:" in line or "gateway-exit" in line:
                self.stderr_tail.append(line.split(":", 1)[0].strip())

    def next(self, timeout):
        frame = self.queue.get(timeout=timeout)
        if frame.get("eof"):
            raise RuntimeError(f"Backend exited: {self.process.poll()}, diagnostic types: {self.stderr_tail[-5:]}")
        if frame.get("method") == "event":
            self.events.append(frame["params"])
            if frame["params"]["type"] == "bridge.error":
                raise RuntimeError(frame["params"]["payload"]["message"])
        return frame

    def request(self, method, **params):
        self.identifier += 1
        rid = self.identifier
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            frame = self.next(max(0.1, deadline - time.monotonic()))
            if frame.get("id") == rid:
                if "error" in frame:
                    raise RuntimeError(f"RPC {method} failed: {frame['error']['message']}")
                return frame.get("result", {})
        raise TimeoutError(method)

    def wait_event(self, kind, session_id=None, timeout=120, after=0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for event in self.events[after:]:
                if event["type"] == kind and (session_id is None or event.get("session_id") == session_id):
                    return event
            self.next(max(0.1, deadline - time.monotonic()))
        raise TimeoutError(kind)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--delegation", action="store_true")
    parser.add_argument("--clarify", action="store_true")
    args = parser.parse_args()
    baseline, gateway = source_snapshot(), gateway_identity()
    results = {}
    backend = None
    try:
        with tempfile.TemporaryDirectory(prefix="notch-hermes-check-") as temporary:
            home = Path(temporary) / "hermes"
            backend = Backend(home)
            results["gateway_ready"] = True
            created = backend.request("session.create", title="Companion integration check", cwd=str(Path(temporary)))
            sid, stored = created["session_id"], created["stored_session_id"]
            results["session_create"] = bool(sid and stored)
            fixture = Path(temporary) / "companion-note.txt"
            fixture.write_text("The verification word is juniper.\n")
            attach = backend.request("file.attach", session_id=sid, path=str(fixture))
            results["file_staged"] = attach["attached"] and "@file:" in attach["ref_text"]
            results["attach_does_not_submit"] = not any(e["type"] == "message.start" for e in backend.events)
            image = Path(temporary) / "pixel.png"
            image.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
            attached_image = backend.request("image.attach", session_id=sid, path=str(image))
            detached_image = backend.request("image.detach", session_id=sid, path=attached_image["path"])
            results["image_attach_detach"] = bool(attached_image.get("attached")) and detached_image.get("count") == 0
            private_auth = json.loads((home / "auth.json").read_text())
            results["no_copied_refresh_grants"] = "refresh_token" not in json.dumps(private_auth)
            if args.live:
                marker = len(backend.events)
                backend.request("prompt.submit", session_id=sid, text="Reply with exactly: Companion connected. Do not call any tools.", surface="hud")
                completed = backend.wait_event("message.complete", sid, after=marker)
                payload = completed.get("payload", {})
                results["live_response"] = payload.get("status") == "complete" and "Companion connected" in payload.get("text", "")
                if not results["live_response"]:
                    print("LIVE_RESPONSE_DIAGNOSTIC", json.dumps({k: payload.get(k) for k in ("status", "text", "error", "warning")}))
                marker = len(backend.events)
                backend.request("prompt.submit", session_id=sid, text="Use read_file to read the attached file, then reply only with its verification word. " + attach["ref_text"], surface="hud")
                completed = backend.wait_event("message.complete", sid, after=marker)
                results["attachment_read_by_agent"] = "juniper" in completed.get("payload", {}).get("text", "").lower()
                results["tool_lifecycle"] = all(any(e["type"] == kind for e in backend.events[marker:]) for kind in ("tool.start", "tool.complete"))
                listing = backend.request("session.list")
                results["session_persisted"] = any(s["id"] == stored for s in listing.get("sessions", []))
                resumed = backend.request("session.resume", session_id=stored)
                results["session_resume"] = bool(resumed.get("messages")) and resumed["session_id"] == sid
                if args.clarify:
                    marker = len(backend.events)
                    backend.request("prompt.submit", session_id=sid, text="Call your clarify tool now to ask me exactly 'Which color?' with choices Sage and Cream. Wait for my answer, then echo only my answer.", surface="hud")
                    question = backend.wait_event("clarify.request", sid, after=marker).get("payload", {})
                    answers = {"request_id": question["request_id"], "answer": "Sage"}
                    if question.get("questions"):
                        answers["question_id"] = question["questions"][0]["qid"]
                    backend.request("clarify.respond", **answers)
                    finished = backend.wait_event("message.complete", sid, after=marker).get("payload", {})
                    results["clarify_respond"] = finished.get("status") == "complete" and "sage" in finished.get("text", "").lower()
                if args.delegation:
                    marker = len(backend.events)
                    backend.request("prompt.submit", session_id=sid, text="Use delegate_task to ask one subagent to reply with the single word sage. Then report its answer. This tests delegation; the subagent should use no tools.", surface="hud")
                    completed = backend.wait_event("message.complete", sid, after=marker, timeout=240)
                    # This Hermes version dispatches children asynchronously;
                    # a parent's first message.complete is not their completion.
                    backend.wait_event("subagent.complete", sid, after=marker, timeout=240)
                    results["delegation_lifecycle"] = all(any(e["type"] == kind for e in backend.events[marker:]) for kind in ("subagent.start", "subagent.complete"))
                    results["delegation_response"] = completed.get("payload", {}).get("status") == "complete"
                    print("DELEGATION_EVENTS", json.dumps([{ "type": e["type"], "keys": sorted((e.get("payload") or {}).keys()) } for e in backend.events[marker:] if e["type"].startswith("subagent.")]))
                marker = len(backend.events)
                backend.request("prompt.submit", session_id=sid, text="Count slowly from one to one hundred, spelling each number on its own line.", surface="hud")
                backend.wait_event("message.start", sid, after=marker)
                backend.request("session.interrupt", session_id=sid)
                interrupted = backend.wait_event("message.complete", sid, after=marker)
                results["interrupt_settles"] = interrupted.get("payload", {}).get("status") in ("interrupted", "complete")
            backend.close()
            backend = None
            # A fresh process must resume persisted conversation, not only RAM.
            if args.live:
                backend = Backend(home)
                resumed = backend.request("session.resume", session_id=stored)
                results["resume_after_restart"] = bool(resumed.get("messages")) and resumed.get("session_key") == stored
                backend.close()
                backend = None
    finally:
        if backend:
            backend.close()
        results["existing_hermes_files_unchanged"] = baseline == source_snapshot()
        results["existing_gateway_same_process"] = gateway == gateway_identity()
        print(json.dumps(results, indent=2))
    assert all(results.values()), "One or more integration checks failed"


if __name__ == "__main__":
    main()
