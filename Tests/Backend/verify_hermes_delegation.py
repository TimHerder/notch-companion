#!/usr/bin/env python3
"""Check the frontend's delegation tools against the installed Hermes internals.

No prompt, model call, profile or credential is used: a throwaway process with
a temporary HOME/HERMES_HOME imports the installed tui_gateway, registers the
tools through the launcher, binds a fake session and runs one call through
Hermes's own dispatch to a local stand-in for the companion. Writes to the real
~/.hermes are denied by a sandbox for the whole run.

    python3 Tests/Backend/verify_hermes_delegation.py [--source ~/.hermes/hermes-agent]
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Sources/NotchCompanion/Resources"

CHILD = r"""
import importlib.util, json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
source, resources = sys.argv[1], sys.argv[2]
sys.path.insert(0, source)
try:
    import dotenv  # noqa: F401  the managed install's active environment is already on the path
except ImportError:
    import hermes_bootstrap  # noqa: F401  (it takes the install lock, which the sandbox denies)
spec = importlib.util.spec_from_file_location("hermes_frontend", resources + "/hermes_frontend.py")
frontend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontend)
frontend.install_surface_hint()
import tui_gateway.server as server
import model_tools
from agent import prompt_builder
from agent.tool_dispatch_helpers import _extend_tool_timeout

seen = []
class Companion(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.headers["Authorization"], body["params"]))
        reply = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": {"content": [{"type": "text", "text": '{"ok": true}'}], "isError": False}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(reply))); self.end_headers(); self.wfile.write(reply)
    def log_message(self, *_): pass
httpd = ThreadingHTTPServer(("127.0.0.1", 0), Companion)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
url = "http://127.0.0.1:%d/mcp" % httpd.server_port

reports = []
delegation = frontend.NotchDelegation(report=reports.append)
tools = [{"name": "delegate_task", "description": "Delegate a task.", "inputSchema": {"type": "object", "properties": {"task": {"type": "string"}}, "required": ["task"]}},
         {"name": "task_status", "description": "Read a task.", "inputSchema": {"type": "object", "properties": {"taskId": {"type": "string"}}}}]
delegation.receive(json.dumps({"tools": tools, "instructions": "## Notch Companion delegation"}))
with server._sessions_lock:
    server._sessions["live-1"] = {"session_key": "stored-1", "agent": None}
delegation.receive(json.dumps({"bind": "live-1", "url": url, "token": "fixture-token"}))
enabled = server._load_enabled_toolsets("notch_companion")
# The raw catalog; Hermes's tool search may then defer these behind tool_search, as it does MCP tools.
names = {item["function"]["name"] for item in model_tools.get_tool_definitions(enabled_toolsets=enabled, quiet_mode=True, skip_tool_search_assembly=True)}
offered = {item["function"]["name"] for item in model_tools.get_tool_definitions(enabled_toolsets=enabled, quiet_mode=True)}
result = model_tools.handle_function_call("mcp__notch__task_status", {"taskId": "t1"}, task_id="verify", session_id="stored-1")
bridged = model_tools.handle_function_call("tool_call", {"calls": [{"name": "mcp__notch__task_status", "arguments": {"taskId": "t2"}}]},
                                           task_id="verify", session_id="stored-1", enabled_toolsets=enabled)
denied = model_tools.handle_function_call("mcp__notch__task_status", {"taskId": "t1"}, task_id="verify", session_id="someone-else")
print("NOTCH_VERIFY " + json.dumps({
    "reports": reports, "enabled": enabled, "registered": sorted(n for n in names if n.startswith("mcp__notch__")),
    "offered": sorted(n for n in offered if n.startswith(("mcp__notch__", "tool_"))),
    "agent_build_reads_server_globals": server._make_agent.__globals__ is vars(server),
    "timeout": _extend_tool_timeout("mcp__notch__delegate_task", 300.0),
    "hint": "## Notch Companion delegation" in prompt_builder.PLATFORM_HINTS.get("notch_companion", ""),
    "result": result, "bridged": bridged, "denied": json.loads(denied).get("code"), "seen": seen}), flush=True)
import os; os._exit(0)
"""


def interpreter(source, real_home):
    """The managed install's active environment, read-only, else a checkout venv."""
    for facts in sorted((real_home / "installs").glob("*/facts.json")):
        venv = json.loads(facts.read_text()).get("packages", {}).get("venv", {}).get("environment")
        if venv and Path(venv, "bin/python").exists():
            return str(Path(venv, "bin/python"))
    launcher = source / ".hermes/bin/hermes"
    match = re.search(r"exec (\S+python3?\S*)", launcher.read_text()) if launcher.is_file() else None
    if match:
        return match.group(1)
    for candidate in (source / "venv/bin/python", source / ".venv/bin/python"):
        if candidate.exists():
            return str(candidate)
    raise SystemExit("No Hermes interpreter found under " + str(source))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path.home() / ".hermes/hermes-agent")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    real_home = (Path.home() / ".hermes").resolve()
    with tempfile.TemporaryDirectory(prefix="notch-hermes-delegation-") as directory:
        home, hermes_home = Path(directory, "home"), Path(directory, "hermes")
        home.mkdir(); hermes_home.mkdir()
        # An explicit CLI selection, like a configured profile, so the toolset append is exercised.
        (hermes_home / "config.yaml").write_text("platform_toolsets:\n  cli: [file, todo]\n")
        environment = {"HOME": str(home), "HERMES_HOME": str(hermes_home), "PATH": "/usr/bin:/bin",
                       "PYTHONDONTWRITEBYTECODE": "1", "HERMES_DISABLE_LAZY_INSTALLS": "1"}
        profile = '(version 1)(allow default)(deny file-write* (subpath "%s") (subpath "%s"))' % (real_home, source)
        result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, interpreter(source, real_home), "-I", "-B", "-c", CHILD,
                                 str(source), str(RESOURCES)], cwd=home, env=environment,
                                capture_output=True, text=True, timeout=180)
    line = next((l for l in result.stdout.splitlines() + result.stderr.splitlines() if l.startswith("NOTCH_VERIFY ")), None)
    if line is None:
        sys.stderr.write(result.stderr[-3000:])
        raise SystemExit("The check did not finish (exit %d)." % result.returncode)
    report = json.loads(line[len("NOTCH_VERIFY "):])
    print(json.dumps(report, indent=2, sort_keys=True))
    checks = {
        "tools confirmed": report["reports"] == [{"ready": True}],
        "toolset appended": report["enabled"] is not None and "notch" in report["enabled"],
        "tools in the session catalog": report["registered"] == ["mcp__notch__delegate_task", "mcp__notch__task_status"],
        "agent builds read the patched toolsets": report["agent_build_reads_server_globals"],
        "hour-long budget": report["timeout"] == 3900,
        "instructions in the surface hint": report["hint"],
        "direct and tool_call-bridged calls reached the companion with the session token": report["seen"] == [
            ["Bearer fixture-token", {"name": "task_status", "arguments": {"taskId": "t1"}}],
            ["Bearer fixture-token", {"name": "task_status", "arguments": {"taskId": "t2"}}]],
        "results returned": '"ok": true' in report["result"] and '"ok": true' in report["bridged"],
        "unbound session denied": report["denied"] == "capability_denied",
    }
    for name, passed in checks.items():
        print(("PASS " if passed else "FAIL ") + name)
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
