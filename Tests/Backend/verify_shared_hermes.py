#!/usr/bin/env python3
"""Live validation through Hermes's supported local headless dashboard frontend.

Uses the existing profile and native stores, with the messaging gateway left
running. The owned frontend is protected from changing source/config/auth and
cannot refresh the owner's OAuth grant. A temporary memory entry is added and
removed through actual agent tool calls; test conversations remain identifiable.
Raw transport frames, tokens, private memory, and backend logs are never saved.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import runpy
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes"
SOURCE = HERMES / "hermes-agent"
BRIDGE = ROOT / "Sources/NotchCompanion/Resources/hermes_bridge.py"


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def load_guard():
    spec = importlib.util.spec_from_file_location("notch_borrowed_auth", BRIDGE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def serve_worker():
    sys.path.insert(0, str(SOURCE))
    guard = load_guard()
    guard.borrowed_codex_token(HERMES)  # fails before startup if owner renewal is needed
    guard.install_borrowed_codex(HERMES)
    sys.argv = ["hermes", "serve", "--host", "127.0.0.1", "--port", "0"]
    runpy.run_module("hermes_cli.main", run_name="__main__")


def snapshot(paths):
    return {str(p): hashlib.sha256(p.read_bytes()).digest() if p.exists() else None for p in paths}


def gateway_identity():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(4)
        sock.connect(str(HERMES / "gateway.sock"))
        sock.sendall(b'{"verb":"identify"}\n')
        data = b""
        while not data.endswith(b"\n"):
            data += sock.recv(8192)
    result = json.loads(data)["result"]
    return {k: result.get(k) for k in ("pid", "start_time", "kind", "profile", "code_sha")}


def preflight(startup_only=False):
    sys.path.insert(0, str(SOURCE))
    from hermes_cli.config import load_config_readonly
    from tools.memory_tool import MemoryStore, get_builtin_memory_config
    config = load_config_readonly()
    memory = get_builtin_memory_config(config)
    if config.get("sessions", {}).get("auto_archive", False):
        raise RuntimeError("Validation refuses an enabled automatic-archive policy")
    if config.get("local_runtime", {}).get("enabled", False):
        raise RuntimeError("Validation refuses to start managed local model services")
    if memory.get("write_approval", False):
        raise RuntimeError("Live memory validation requires an interactive approval path")
    store = MemoryStore(memory_char_limit=int(memory.get("memory_char_limit", 2200)))
    store.load_from_disk()
    free = store.memory_char_limit - store._char_count("memory")
    if not startup_only and free < 16:
        raise RuntimeError("Not enough unused memory capacity for a temporary marker; no consolidation allowed")
    guard = load_guard()
    token, _stamp = guard.borrowed_codex_token(HERMES)
    expiry = guard.token_expiry(token)
    if expiry and expiry < time.time() + 600:
        raise RuntimeError("Owner access token needs renewal before a no-refresh validation")
    return {"memory_marker_capacity_available": True, "owner_access_token_valid_without_refresh": True,
            "auto_archive_disabled": True, "managed_local_runtime_disabled": True}


class Frontend:
    def __init__(self):
        self.token = secrets.token_urlsafe(32)
        self.ready = queue.Queue()
        self.live_sessions = []
        protected = [HERMES / name for name in ("config.yaml", ".env", "auth.json", "SOUL.md",
                     "gateway.pid", "gateway.lock")]
        profile = '(version 1)(allow default)'
        for path in (SOURCE, HERMES / "skills", HERMES / "profiles", Path.home() / ".codex"):
            profile += '(deny file-write* (subpath ' + json.dumps(str(path)) + '))'
        for path in protected:
            profile += '(deny file-write* (literal ' + json.dumps(str(path)) + '))'
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(("HERMES_", "CODEX_")) or key in ("PYTHONPATH", "PYTHONHOME"):
                env.pop(key, None)
        env.update(HERMES_HOME=str(HERMES), HERMES_DASHBOARD_SESSION_TOKEN=self.token,
                   PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
        # Run the shipped standalone frontend path. HERMES_DESKTOP is deliberately
        # absent so its optional gateway/cron lifecycle ownership is not enabled.
        self.process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile,
            str(SOURCE / "venv/bin/python"), "-B", str(Path(__file__).resolve()), "--serve-worker"],
            env=env, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.diagnostics = []
        threading.Thread(target=self._read, args=(self.process.stdout,), daemon=True).start()
        threading.Thread(target=self._read, args=(self.process.stderr,), daemon=True).start()
        try:
            self.port = self.ready.get(timeout=65)
        except queue.Empty:
            self.close()
            raise RuntimeError("Native frontend startup did not become ready; categories=" + repr(self.diagnostics[-6:]))
        if not self.port:
            self.close()
            raise RuntimeError("Native frontend exited before readiness; categories=" + repr(self.diagnostics[-6:]))

    def _read(self, pipe):
        for line in pipe:
            match = re.search(r"HERMES_(?:BACKEND|DASHBOARD)_READY port=(\d+)", line)
            if match:
                self.ready.put(int(match.group(1)))
            # Categorize without retaining arbitrary lines, which may be private.
            for category in ("PermissionError", "ImportError", "ModuleNotFoundError", "AuthError",
                             "RuntimeError", "FileNotFoundError", "Error loading ASGI", "error:"):
                if category in line:
                    self.diagnostics.append(category)
        if self.process.poll() is not None:
            self.ready.put(None)

    def client(self):
        from websockets.sync.client import connect
        url = f"ws://127.0.0.1:{self.port}/api/ws?token=" + urllib.parse.quote(self.token)
        connection = connect(url, proxy=None, open_timeout=15, max_size=16 * 1024 * 1024,
                             origin=f"http://127.0.0.1:{self.port}")
        return RPC(connection)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


class RPC:
    def __init__(self, connection):
        self.connection = connection
        self.sequence = 0
        self.events = []
        self.wait_event("gateway.ready", timeout=35)

    def receive(self, timeout):
        frame = json.loads(self.connection.recv(timeout=timeout))
        if frame.get("method") == "event":
            event = frame.get("params", {})
            self.events.append(event)
            if event.get("type") in ("approval.request", "clarify.request", "sudo.request", "secret.request"):
                raise RuntimeError("Validation turn requested unexpected interactive input")
        return frame

    def request(self, method, **params):
        self.sequence += 1
        rid = self.sequence
        self.connection.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            frame = self.receive(max(.1, deadline - time.monotonic()))
            if frame.get("id") == rid:
                if "error" in frame:
                    error = frame["error"]
                    raise RuntimeError(f"RPC {method} failed ({error.get('code')}): {str(error.get('message',''))[:160]}")
                return frame.get("result", {})
        raise TimeoutError(method)

    def wait_event(self, name, sid=None, after=0, timeout=150):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for event in self.events[after:]:
                if event.get("type") == name and (sid is None or event.get("session_id") == sid):
                    return event
            self.receive(max(.1, deadline - time.monotonic()))
        raise TimeoutError(name)

    def prompt(self, sid, text):
        first = len(self.events)
        self.request("prompt.submit", session_id=sid, text=text, surface="hud")
        event = self.wait_event("message.complete", sid=sid, after=first)
        payload = event.get("payload", {})
        tools = [e.get("payload", {}) for e in self.events[first:] if e.get("type") == "tool.complete"]
        return {"status": payload.get("status"), "text": payload.get("text", ""), "tools": tools}

    def close(self):
        self.connection.close()


def external_search(marker, target_id):
    # Independent native session-search invocation, read-only against the user's
    # real store. It cannot insert or rewrite a test conversation.
    from hermes_state import SessionDB
    from tools.session_search_tool import session_search
    db = SessionDB(db_path=HERMES / "state.db", read_only=True)
    try:
        row = db.get_session(target_id)
        result = session_search(query=marker, db=db, current_session_id="notch-external-validation")
        return {"normal_store_record": bool(row), "source": (row or {}).get("source"),
                "searchable_outside_frontend": target_id in result and marker in result}
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve-worker", action="store_true")
    parser.add_argument("--startup-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "output/runtime-validation/2026-10-02-hermes-live.json")
    args = parser.parse_args()
    if args.serve_worker:
        serve_worker()
        return
    files = [HERMES / n for n in ("config.yaml", ".env", "auth.json", "SOUL.md", "gateway.pid", "gateway.lock")]
    before = snapshot(files)
    memory_paths = [HERMES / "memories" / name for name in ("MEMORY.md", "USER.md")]
    memory_before = snapshot(memory_paths)
    identity = gateway_identity()
    result = {"gateway_before": identity, "preflight": preflight(args.startup_only)}
    frontend, client, reader = None, None, None
    sid, stored, reader_sid = None, None, None
    memory_entry = "NCV:" + uuid.uuid4().hex[:8]
    marker = "notchprobe" + uuid.uuid4().hex[:16]
    wrote_memory = False
    try:
        frontend = Frontend()
        client = frontend.client()
        result["frontend"] = {"native_headless_ready": True, "authenticated_ws_ready": True,
                              "loopback_only": True, "pid": frontend.process.pid}
        emit({"stage": "native_frontend_connected", "pid": frontend.process.pid})
        if args.startup_only:
            return
        session = client.request("session.create", title="Notch Companion Hermes connection validation",
                                 source="notch_companion", cwd=str(ROOT), follow_profile_config=True)
        sid, stored = session["session_id"], session["stored_session_id"]
        result["session_id"] = stored
        turn = client.prompt(sid, "This is an explicit user-requested Hermes integration validation. "
            "Do not use tools or modify anything for this first check. Reply with exactly: " + marker)
        result["prompt"] = {"status": turn["status"], "exact_response": turn["text"].strip() == marker,
                            "tool_count": len(turn["tools"])}
        emit({"stage": "first_real_turn", **result["prompt"]})
        if turn["status"] != "complete":
            raise RuntimeError("Initial provider turn did not complete")
        result["external_search"] = external_search(marker, stored)
        # Explicitly bounded write through the real agent and its native memory
        # tool. Never ask it to consolidate or remove existing user entries.
        turn = client.prompt(sid, "Continue the user-requested validation. Use only the memory tool to add "
            "exactly this temporary entry to target memory: " + memory_entry +
            ". Do not consolidate, replace, or remove any existing entries. If it cannot fit, stop and report that. "
            "Do not save anything else or invoke other tools. Reply TEST_MEMORY_SAVED only after the tool succeeds.")
        wrote_memory = memory_entry in (HERMES / "memories/MEMORY.md").read_text()
        result["memory_write"] = {"status": turn["status"], "marker_persisted": wrote_memory,
                                  "native_memory_tool_called": any(t.get("name") == "memory" for t in turn["tools"])}
        emit({"stage": "real_memory_write", **result["memory_write"]})
        if not wrote_memory:
            raise RuntimeError("Native memory marker was not persisted")
        reader = frontend.client()
        second = reader.request("session.create", title="Notch Companion Hermes cross-session validation",
                                source="notch_validation_reader", cwd=str(ROOT), follow_profile_config=True)
        reader_sid = second["session_id"]
        result["reader_session_id"] = second["stored_session_id"]
        recall = reader.prompt(reader_sid, "User-requested validation: your persistent memory contains one "
            "temporary integration-test entry beginning 'NCV:'. Without tools, output exactly the 8-character "
            "marker after that prefix, and nothing else. Do not change any memory or files.")
        result["fresh_session_memory"] = {"status": recall["status"],
            "recalled_without_marker_in_prompt": recall["text"].strip() == memory_entry.split(":", 1)[-1],
            "tool_count": len(recall["tools"])}
        search = reader.prompt(reader_sid, "Use only session_search to find the prior conversation containing "
            "the unique token " + marker + ". Return its session ID only. Do not change memory or files.")
        result["live_cross_session_search"] = {"status": search["status"],
            "returned_original_session": stored in search["text"],
            "session_search_called": any(t.get("name") == "session_search" for t in search["tools"])}
        result["reader_external_search"] = external_search(marker, stored)
        emit({"stage": "cross_session_checks", "memory": result["fresh_session_memory"],
              "search": result["live_cross_session_search"]})
    finally:
        if wrote_memory and client and sid:
            try:
                cleanup = client.prompt(sid, "Finish the user-requested validation. Use only memory(action=remove, "
                    "target=memory) to remove exactly the temporary entry whose old_text is " + memory_entry +
                    ". Do not remove or change any other entry. Do not save anything new. Reply TEST_MEMORY_REMOVED.")
                result["cleanup"] = {"status": cleanup["status"],
                    "marker_removed": memory_entry not in (HERMES / "memories/MEMORY.md").read_text()}
            except Exception as exc:
                result["cleanup"] = {"failed": True, "error_type": type(exc).__name__}
        for connection, live_id in ((reader, reader_sid), (client, sid)):
            if connection:
                if live_id:
                    try:
                        connection.request("session.close", session_id=live_id)
                    except Exception:
                        pass
                connection.close()
        if frontend:
            frontend.close()
        if stored:
            result["after_frontend_exit"] = external_search(marker, stored)
        result["protected_files_unchanged"] = before == snapshot(files)
        result["memory_files_restored_exactly"] = memory_before == snapshot(memory_paths)
        result["gateway_identity_unchanged"] = identity == gateway_identity()
        result["owned_frontend_stopped"] = frontend is None or frontend.process.poll() is not None
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        emit(result)


if __name__ == "__main__":
    main()
