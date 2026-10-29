#!/usr/bin/env python3
"""Validate runtime integration seams without modifying either installation.

--codex creates one clearly named, real Codex thread and sends two tiny prompts.
It leaves that thread available for checking in the desktop app. No client
identity spoofing, credential copying, config changes, or existing-process stops.
Hermes live probing is read-only. Native search/memory checks run in a disposable
fixture home with OS write denial over the real Hermes installation.
Only sanitized evidence is emitted; raw RPC/stderr/config/auth are never saved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERMES_HOME = Path.home() / ".hermes"
HERMES_SOURCE = HERMES_HOME / "hermes-agent"


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def protected_snapshot():
    paths = [HERMES_HOME / n for n in ("config.yaml", ".env", "auth.json", "gateway.pid", "gateway.lock")]
    paths += list((HERMES_HOME / "memories").glob("*.md"))
    return {str(p): hashlib.sha256(p.read_bytes()).digest() for p in paths if p.is_file()}


def gateway_request(verb):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(4)
        connection.connect(str(HERMES_HOME / "gateway.sock"))
        connection.sendall((json.dumps({"id": 1, "verb": verb}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n") and len(data) < 524288:
            chunk = connection.recv(8192)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def gateway_identity():
    value = gateway_request("identify").get("result", {})
    return {k: value.get(k) for k in ("pid", "start_time", "profile", "kind")}


def hermes_fixture_worker(source):
    # HERMES_HOME is already a fresh temporary directory before any import.
    sys.path.insert(0, source)
    from hermes_constants import get_hermes_home
    from hermes_state import SessionDB
    from tools.memory_tool import MemoryStore, memory_tool
    from tools.session_search_tool import session_search

    fixture = Path(os.environ["HERMES_HOME"]).resolve()
    assert fixture != HERMES_HOME.resolve() and HERMES_HOME.resolve() not in fixture.parents
    assert get_hermes_home().resolve() == fixture
    db = SessionDB(db_path=fixture / "state.db")
    notch_id, external_id = "notch-validation-" + uuid.uuid4().hex, "cli-validation-" + uuid.uuid4().hex
    marker = "notchcontinuity" + uuid.uuid4().hex
    db.create_session(notch_id, source="notch_companion")
    db.set_session_title(notch_id, "Notch Companion validation fixture")
    db.append_message(notch_id, "user", "Validation marker: " + marker)
    db.append_message(notch_id, "assistant", "Recorded fixture marker " + marker)
    db.create_session(external_id, source="cli")
    db.set_session_title(external_id, "External search validation fixture")
    search = session_search(query=marker, db=db, current_session_id=external_id)
    store = MemoryStore()
    store.load_from_disk()
    memory_write = json.loads(memory_tool(action="add", target="memory",
        content="Runtime validation fixture marker: " + marker, store=store))
    fresh_store = MemoryStore()
    fresh_store.load_from_disk()
    memory_in_new_session = marker in (fresh_store.format_for_system_prompt("memory") or "")
    saved = db.get_session(notch_id)
    db.close()
    reopened = SessionDB(db_path=fixture / "state.db", read_only=True)
    after_restart = session_search(query=marker, db=reopened, current_session_id=external_id)
    reopened.close()
    return {
        "scope": "installed native modules, disposable fixture home; not a live gateway conversation",
        "native_session_record": bool(saved and saved.get("source") == "notch_companion"),
        "searchable_from_other_session": notch_id in search and marker in search,
        "searchable_after_reopen": notch_id in after_restart and marker in after_restart,
        "native_memory_tool_write": memory_write.get("success") is True,
        "memory_loaded_in_fresh_session_snapshot": memory_in_new_session,
        "real_hermes_home_write_denied": True,
    }


def hermes_readonly_worker(source):
    sys.path.insert(0, source)
    from hermes_cli.config import load_config_readonly
    from hermes_constants import get_hermes_home
    from tools.memory_tool import MemoryStore, get_builtin_memory_config, get_builtin_memory_store_flags

    config = load_config_readonly()
    memory = get_builtin_memory_config(config)
    flags = get_builtin_memory_store_flags(config)
    store = MemoryStore(int(memory.get("memory_char_limit", 2200)), int(memory.get("user_char_limit", 1375)),
                        memory_enabled=flags[0], user_profile_enabled=flags[1])
    store.load_from_disk()
    return {"real_profile_memory_read_only": True,
        "profile_matches_default": get_hermes_home() == HERMES_HOME,
        "memory_enabled": flags[0], "user_profile_enabled": flags[1],
        "memory_has_entries": bool(store.memory_entries), "user_profile_has_entries": bool(store.user_entries),
        "memory_in_prompt": bool(store.format_for_system_prompt("memory")),
        "user_profile_in_prompt": bool(store.format_for_system_prompt("user"))}


def validate_hermes():
    identity = gateway_identity()
    capabilities = gateway_request("notch.validation.capabilities")
    result = {"gateway": identity, "live_supported_verbs": capabilities.get("supported_verbs", []),
              "live_prompt_endpoint_verified": False}
    python = next((p for p in (HERMES_SOURCE / "venv/bin/python", HERMES_SOURCE / ".venv/bin/python") if p.exists()), None)
    if python is None:
        raise RuntimeError("Hermes Python installation unavailable")
    with tempfile.TemporaryDirectory(prefix="notch-runtime-fixture-") as folder:
        policy = '(version 1)(allow default)(deny file-write* (subpath ' + json.dumps(str(HERMES_HOME)) + '))'
        env = dict(os.environ)
        for key in ("PYTHONPATH", "PYTHONHOME", "HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE"):
            env.pop(key, None)
        env.update(HERMES_HOME=folder, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
        worker = subprocess.run(["/usr/bin/sandbox-exec", "-p", policy, str(python), "-B", str(Path(__file__).resolve()),
                                 "--hermes-fixture-worker", str(HERMES_SOURCE)], env=env,
                                cwd=folder, capture_output=True, text=True, timeout=60)
        if worker.returncode:
            # Do not disclose arbitrary library logs or credential-bearing errors.
            result["fixture"] = {"status": "failed", "exit_code": worker.returncode,
                                 "diagnostic_types": [s.split(":", 1)[0].strip() for s in worker.stderr.splitlines()
                                                      if s.startswith(("ImportError:", "AssertionError", "TypeError:", "PermissionError:", "RuntimeError:"))][-3:]}
        else:
            lines = [s for s in worker.stdout.splitlines() if s.startswith("{")]
            result["fixture"] = json.loads(lines[-1])
    env = dict(os.environ)
    for key in ("PYTHONPATH", "PYTHONHOME", "HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE"):
        env.pop(key, None)
    env.update(HERMES_HOME=str(HERMES_HOME), PYTHONDONTWRITEBYTECODE="1")
    read = subprocess.run(["/usr/bin/sandbox-exec", "-p", policy, str(python), "-B", str(Path(__file__).resolve()),
                           "--hermes-readonly-worker", str(HERMES_SOURCE)], env=env,
                          capture_output=True, text=True, timeout=30)
    lines = [s for s in read.stdout.splitlines() if s.startswith("{")]
    result["real_profile"] = json.loads(lines[-1]) if read.returncode == 0 and lines else {"read_failed": True}
    return result


class CodexRPC:
    def __init__(self):
        executable = shutil.which("codex")
        if not executable:
            raise RuntimeError("Codex CLI unavailable")
        env = dict(os.environ)
        # A standalone native client must not inherit this chat's desktop
        # origin, thread identity, or privileged desktop-tools pipe.
        for key in ("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_THREAD_ID",
                    "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH"):
            env.pop(key, None)
        self.process = subprocess.Popen([executable, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, cwd=str(ROOT), env=env)
        self.frames = queue.Queue()
        self.events = []
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"clientInfo": {"name": "notch_companion_validation",
            "title": "Notch Companion validation", "version": "0.1.0"}})
        self.send({"method": "initialized", "params": {}})

    def _read(self):
        for line in self.process.stdout:
            try:
                self.frames.put(json.loads(line))
            except ValueError:
                pass
        self.frames.put({"eof": True})

    def send(self, frame):
        self.process.stdin.write(json.dumps(frame) + "\n")
        self.process.stdin.flush()

    def next(self, timeout):
        frame = self.frames.get(timeout=timeout)
        if frame.get("eof"):
            raise RuntimeError("Owned Codex process ended")
        if "method" in frame:
            if "id" in frame:
                method = frame["method"]
                if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
                    self.send({"id": frame["id"], "result": {"decision": "decline"}})
                else:
                    self.send({"id": frame["id"], "error": {"code": -32601, "message": "Validation only; request unsupported"}})
            self.events.append(frame)
        return frame

    def request(self, method, params, timeout=60):
        self.sequence += 1
        rid = self.sequence
        self.send({"id": rid, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = self.next(max(.1, deadline - time.monotonic()))
            if frame.get("id") == rid and "method" not in frame:
                if "error" in frame:
                    error = frame["error"]
                    raise RuntimeError("RPC %s failed (%s): %s" % (method, error.get("code"), str(error.get("message", ""))[:250]))
                return frame.get("result", {})
        raise TimeoutError(method)

    def turn(self, thread_id, text):
        start = len(self.events)
        turn = self.request("turn/start", {"threadId": thread_id,
            "input": [{"type": "text", "text": text}]})["turn"]
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            for frame in self.events[start:]:
                value = frame.get("params", {})
                if frame.get("method") == "turn/completed" and value.get("turn", {}).get("id") == turn["id"]:
                    items = [e.get("params", {}).get("item", {}) for e in self.events[start:]
                             if e.get("method") == "item/completed"]
                    messages = [v.get("text", "") for v in items if v.get("type") == "agentMessage"]
                    return {"status": value["turn"]["status"], "messages": messages,
                            "item_types": sorted(set(v.get("type", "") for v in items)),
                            "error_category": (value["turn"].get("error") or {}).get("codexErrorInfo")}
            self.next(max(.1, deadline - time.monotonic()))
        self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn["id"]})
        raise TimeoutError("Validation turn")

    def close(self):
        # This is only the child process this object created, never an app server
        # already owned by the user. Normal callers wait for terminal turn events.
        self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


def validate_codex():
    marker = "NOTCH-CODEX-" + uuid.uuid4().hex[:12]
    title = "Notch Companion runtime validation " + marker[-12:]
    client = CodexRPC()
    try:
        account = client.request("account/read", {"refreshToken": False})
        started = client.request("thread/start", {"cwd": str(ROOT), "ephemeral": False,
            "approvalPolicy": "untrusted", "sandbox": "read-only",
            "threadSource": "notch_companion", "serviceName": "notch_companion_validation"})
        thread_id = started["thread"]["id"]
        client.request("thread/name/set", {"threadId": thread_id, "name": title})
        emit({"codex_probe_started": True, "thread_id": thread_id, "title": title,
              "source": started["thread"].get("source"), "model": started.get("model"),
              "auth_type": (account.get("account") or {}).get("type")})
        first = client.turn(thread_id,
            "This is an explicitly requested Notch Companion runtime integration validation. "
            "Do not use tools, inspect files, change memory, or do repository work. "
            "Reply with exactly this marker and nothing else: " + marker)
        client.request("thread/name/set", {"threadId": thread_id, "name": title})
        read = client.request("thread/read", {"threadId": thread_id, "includeTurns": True})
        default = client.request("thread/list", {"limit": 50, "searchTerm": title})
        explicit = client.request("thread/list", {"limit": 50, "searchTerm": title, "sourceKinds": ["appServer"]})
        result = {"thread_id": thread_id, "title": title, "source": started["thread"].get("source"),
            "desktop_origin_and_thread_environment_removed": True,
            "requested_thread_source": "notch_companion",
            "model": started.get("model"), "auth_type": (account.get("account") or {}).get("type"),
            "first_turn_status": first["status"], "first_response_exact": marker in first["messages"],
            "first_turn_item_types": first["item_types"], "error_category": first["error_category"],
            "history_contains_marker": marker in json.dumps(read),
            "listed_by_default_filter": any(t.get("id") == thread_id for t in default.get("data", [])),
            "listed_by_appserver_filter": any(t.get("id") == thread_id for t in explicit.get("data", []))}
    finally:
        client.close()
    emit({"codex_first_connection": result})
    # A fresh process establishes persistence and context restoration, rather
    # than success being confined to the initial in-memory conversation.
    client = CodexRPC()
    try:
        resumed = client.request("thread/resume", {"threadId": thread_id})
        second = client.turn(thread_id, "Validation follow-up. Without tools, repeat only the exact marker from the preceding user message.")
        result.update(resumed_same_id=resumed.get("thread", {}).get("id") == thread_id,
            resumed_turn_status=second["status"], resumed_response_exact=marker in second["messages"],
            resumed_item_types=second["item_types"])
        client.request("thread/name/set", {"threadId": thread_id, "name": title})
    finally:
        client.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes", action="store_true")
    parser.add_argument("--codex", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--hermes-fixture-worker", metavar="SOURCE")
    parser.add_argument("--hermes-readonly-worker", metavar="SOURCE")
    args = parser.parse_args()
    if args.hermes_fixture_worker:
        emit(hermes_fixture_worker(args.hermes_fixture_worker))
        return
    if args.hermes_readonly_worker:
        emit(hermes_readonly_worker(args.hermes_readonly_worker))
        return
    before = protected_snapshot()
    identity = gateway_identity()
    result = {"hermes_gateway_before": identity}
    try:
        if args.hermes:
            result["hermes"] = validate_hermes()
            emit({"hermes": result["hermes"]})
        if args.codex:
            result["codex"] = validate_codex()
    finally:
        result["hermes_protected_files_unchanged"] = before == protected_snapshot()
        result["hermes_gateway_identity_unchanged"] = identity == gateway_identity()
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        emit(result)


if __name__ == "__main__":
    main()
