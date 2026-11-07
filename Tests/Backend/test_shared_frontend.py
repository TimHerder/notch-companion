"""Offline policy checks for the shared frontend. No real credentials or stores."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
import io
import sys
import os
import tempfile
from types import ModuleType, SimpleNamespace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time

spec = importlib.util.spec_from_file_location("frontend", Path(__file__).resolve().parents[2] / "Sources/NotchCompanion/Resources/hermes_frontend.py")
frontend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontend)


class SharedFrontendTests(unittest.TestCase):
    def test_reasoning_catalog_uses_installed_vocabulary_without_changing_native_payload(self):
        inventory = ModuleType("hermes_cli.inventory")
        constants = ModuleType("hermes_constants")
        constants.VALID_REASONING_EFFORTS = ("low", "high", "future")
        native = {"model": "test", "providers": []}
        inventory.build_model_options_payload = Mock(return_value=native)
        cli = ModuleType("hermes_cli")
        cli.inventory = inventory
        with patch.dict(sys.modules, {"hermes_cli": cli, "hermes_cli.inventory": inventory, "hermes_constants": constants}):
            frontend.install_reasoning_catalog()
            result = inventory.build_model_options_payload(explicit_only=True)
        self.assertEqual(result["reasoning_efforts"], ["none", "low", "high", "future"])
        self.assertNotIn("reasoning_efforts", native)

    def test_surface_hint_describes_companion_sessions_without_replacing_existing_hints(self):
        builder = ModuleType("agent.prompt_builder")
        builder.PLATFORM_HINTS = {"desktop": "native desktop"}
        agent = ModuleType("agent")
        agent.prompt_builder = builder
        with patch.dict(sys.modules, {"agent": agent, "agent.prompt_builder": builder}):
            frontend.install_surface_hint()
            self.assertIn("MEDIA:/absolute/path", builder.PLATFORM_HINTS["notch_companion"])
            self.assertEqual(builder.PLATFORM_HINTS["desktop"], "native desktop")
            builder.PLATFORM_HINTS["notch_companion"] = "native override"
            frontend.install_surface_hint()
            self.assertEqual(builder.PLATFORM_HINTS["notch_companion"], "native override")
        with patch.dict(sys.modules, {"agent": None, "agent.prompt_builder": None}):
            frontend.install_surface_hint()

    def test_normal_shared_profile_allowed(self):
        frontend.validate_configuration({})
        frontend.validate_configuration({"dashboard": {"turn_isolation": False}, "memory": {"enabled": True}})

    def test_no_unowned_managed_model_service(self):
        with self.assertRaisesRegex(RuntimeError, "managed local model services"):
            frontend.validate_configuration({"local_runtime": {"enabled": True}})

    def test_no_unrelated_session_archival(self):
        with self.assertRaisesRegex(RuntimeError, "unrelated conversations"):
            frontend.validate_configuration({"sessions": {"auto_archive": True}})

    def test_no_unguarded_compute_child(self):
        for value in (True, "true", "on", "1", "yes"):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "no-refresh"):
                frontend.validate_configuration({"dashboard": {"turn_isolation": value}})

    def test_public_dashboard_is_reported_without_disabling_native_security(self):
        for url in ("", "http://localhost:8080", "http://127.0.0.1", "http://[::1]:1234"):
            frontend.validate_public_dashboard(url)
        with self.assertRaisesRegex(RuntimeError, "public dashboard authentication"):
            frontend.validate_public_dashboard("https://dashboard.example.test")

    def test_native_profile_arguments_pin_root_and_named_profiles_without_reexec(self):
        profiles = ModuleType("hermes_cli.profiles")
        for profile in (Path("/tmp/existing-hermes").resolve(), Path("/tmp/existing-hermes/profiles/work").resolve()):
            profiles.resolve_profile_env = Mock(return_value=str(profile))
            with patch.dict(sys.modules, {"hermes_cli.profiles": profiles}):
                arguments = frontend.frontend_arguments(profile)
            expected = "work" if profile.name == "work" else "default"
            self.assertEqual(arguments[:5], ["hermes", "--profile", expected, "serve", "--isolated"])
            profiles.resolve_profile_env.assert_called_once_with(expected)
        profiles.resolve_profile_env = Mock(return_value="/tmp/other-profile")
        with patch.dict(sys.modules, {"hermes_cli.profiles": profiles}), self.assertRaisesRegex(RuntimeError, "different folder"):
            frontend.frontend_arguments(Path("/tmp/existing-hermes"))

    def test_equivalent_profile_symlink_is_canonicalized(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "actual"
            profile.mkdir()
            alias = root / "alias"
            alias.symlink_to(profile, target_is_directory=True)
            with patch.dict(os.environ, {"HERMES_HOME": str(alias)}, clear=True):
                frontend.validate_profile_environment(profile.resolve())
                self.assertEqual(os.environ["HERMES_HOME"], str(profile.resolve()))
                os.environ["HERMES_HOME"] = str(root)
                with self.assertRaisesRegex(RuntimeError, "selected profile"):
                    frontend.validate_profile_environment(profile.resolve())

    def test_native_dotenv_reload_preserves_process_token_and_profile(self):
        package = ModuleType("hermes_cli")
        loader = ModuleType("hermes_cli.env_loader")
        package.env_loader = loader
        profile = Path("/tmp/hermes-profile").resolve()
        def native_loader(**kwargs):
            os.environ["HERMES_DASHBOARD_SESSION_TOKEN"] = "saved-dashboard-token"
            return [profile / ".env"]
        loader.load_hermes_dotenv = native_loader
        with patch.dict(sys.modules, {"hermes_cli": package, "hermes_cli.env_loader": loader}), patch.dict(os.environ, {
            "HERMES_HOME": str(profile), "HERMES_DASHBOARD_SESSION_TOKEN": "process-only-token"}, clear=True):
            frontend.load_profile_environment(Path("/tmp/source"), profile)
            self.assertEqual(os.environ["HERMES_DASHBOARD_SESSION_TOKEN"], "process-only-token")
            loader.load_hermes_dotenv(project_env=Path("/tmp/source/.env"))
            self.assertEqual(os.environ["HERMES_DASHBOARD_SESSION_TOKEN"], "process-only-token")
            with self.assertRaisesRegex(RuntimeError, "different profile"):
                loader.load_hermes_dotenv(hermes_home=Path("/tmp/other-profile"))

    def test_parent_eof_cleans_computer_use_before_sigterm(self):
        calls = []
        stream = type("Input", (), {"buffer": io.BytesIO(b"")})()
        with patch.object(frontend.sys, "stdin", stream), patch.object(frontend.os, "kill", side_effect=lambda *_: calls.append("signal")):
            frontend.watch_parent(lambda: calls.append("cleanup"))
        self.assertEqual(calls, ["cleanup", "signal"])

    def test_parent_lines_reach_delegation_and_eof_still_terminates(self):
        calls, lines = [], []
        def receive(line):
            lines.append(line)
            raise ValueError("a bad line never stops the ownership watcher")
        stream = type("Input", (), {"buffer": io.BytesIO(b'{"bind": "a"}\n{"bind": "b"}\n')})()
        with patch.object(frontend.sys, "stdin", stream), patch.object(frontend.os, "kill", side_effect=lambda *_: calls.append("signal")):
            frontend.watch_parent(lambda: calls.append("cleanup"), receive)
        self.assertEqual(lines, [b'{"bind": "a"}\n', b'{"bind": "b"}\n'])
        self.assertEqual(calls, ["cleanup", "signal"])

    def test_guard_is_loaded_without_preparing_private_home(self):
        guard = frontend.load_auth_guard()
        self.assertTrue(callable(guard.install_authentication_guard))
        self.assertTrue(callable(guard.validate_provider))


class FakeRegistry:
    """Hermes 0.22.3's registry surface: register(..., execution_timeout) and get_entry."""
    def __init__(self, timeout_parameter=True):
        self.entries = {}
        if not timeout_parameter:
            self.register = lambda name, toolset, schema, handler: None

    def register(self, name, toolset, schema, handler, check_fn=None, execution_timeout=None):
        existing = self.entries.get(name)
        if existing is not None and existing.toolset != toolset:
            return  # Hermes logs and rejects cross-toolset shadowing
        self.entries[name] = SimpleNamespace(name=name, toolset=toolset, schema=schema, handler=handler,
                                             execution_timeout=execution_timeout)

    def get_entry(self, name):
        return self.entries.get(name)


class Companion(BaseHTTPRequestHandler):
    """The companion's loopback MCP endpoint, recording what each call carried."""
    calls, status, result, release = [], 200, {}, None

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Companion.calls.append((self.headers["Authorization"], body))
        if Companion.release is not None:
            Companion.release.wait(5)
        payload = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": Companion.result}).encode()
        self.send_response(Companion.status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


class NotchDelegationTests(unittest.TestCase):
    TOOLS = [{"name": "delegate_task", "description": "Delegate.", "inputSchema": {"type": "object", "properties": {"task": {"type": "string"}}}},
             {"name": "task_status", "description": "Status.", "inputSchema": {"type": "object", "properties": {}}}]

    def setUp(self):
        self.registry = FakeRegistry()
        self.server = ModuleType("tui_gateway.server")
        self.server._sessions = {"live-a": {"session_key": "key-a", "agent": None},
                                 "live-b": {"session_key": "key-b", "agent": None},
                                 "live-c": {"session_key": "key-c", "agent": None}}
        self.server._sessions_lock = threading.RLock()
        self.configured = ["file", "terminal"]
        self.server._load_enabled_toolsets = lambda platform=None: self.configured
        self.builder = ModuleType("agent.prompt_builder")
        self.builder.PLATFORM_HINTS = {}
        registry_module = ModuleType("tools.registry")
        registry_module.registry = self.registry
        modules = {"tui_gateway.server": self.server, "tools.registry": registry_module, "agent": ModuleType("agent"),
                   "agent.prompt_builder": self.builder, "tools.interrupt": None}
        modules["agent"].prompt_builder = self.builder
        patcher = patch.dict(sys.modules, modules)
        patcher.start()
        self.addCleanup(patcher.stop)
        frontend.install_surface_hint()
        self.reports = []
        self.delegation = frontend.NotchDelegation(report=self.reports.append)

    def send(self, message):
        self.delegation.receive(json.dumps(message).encode() + b"\n")

    def companion(self):
        Companion.calls, Companion.status, Companion.release = [], 200, None
        Companion.result = {"content": [{"type": "text", "text": '{"taskId": "t1"}'}], "isError": False}
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Companion)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        return "http://127.0.0.1:%d/mcp" % httpd.server_port

    def call(self, tool, session_id, arguments=None):
        return self.registry.get_entry("mcp__notch__" + tool).handler(arguments or {}, session_id=session_id)

    def test_tools_register_once_as_native_tools_with_the_hour_long_budget(self):
        self.send({"tools": self.TOOLS, "instructions": "## Notch Companion delegation"})
        self.send({"tools": self.TOOLS, "instructions": "## Notch Companion delegation"})
        self.assertEqual(self.reports, [{"ready": True}, {"ready": True}])
        entry = self.registry.get_entry("mcp__notch__delegate_task")
        self.assertEqual((entry.toolset, entry.execution_timeout), ("notch", 3900))
        self.assertEqual(entry.schema["parameters"], self.TOOLS[0]["inputSchema"])
        hint = self.builder.PLATFORM_HINTS["notch_companion"]
        self.assertTrue(hint.startswith(frontend.COMPANION_SURFACE_HINT))
        self.assertEqual(hint.count("## Notch Companion delegation"), 1, "A repeated tools line adds the instructions once")

    def test_toolset_joins_explicit_selections_only(self):
        self.send({"tools": self.TOOLS})
        self.assertEqual(self.server._load_enabled_toolsets("notch_companion"), ["file", "terminal", "notch"])
        self.configured = None  # every toolset, which already includes registered ones
        self.assertIsNone(self.server._load_enabled_toolsets())
        self.configured = []  # the profile's explicit zero-tool state stays empty
        self.assertEqual(self.server._load_enabled_toolsets(), [])

    def test_incompatible_hermes_fails_closed_without_patching(self):
        original = self.server._load_enabled_toolsets
        for registry in (FakeRegistry(timeout_parameter=False), None):
            with self.subTest(registry=registry):
                if registry is None:  # a user's MCP server called notch already owns the names
                    registry = FakeRegistry()
                    registry.register("mcp__notch__task_status", "mcp-notch", {}, print)
                sys.modules["tools.registry"].registry = registry
                self.reports.clear()
                self.send({"tools": self.TOOLS, "instructions": "rules"})
                self.assertFalse(self.reports[0]["ready"])
                self.assertIn("delegat", self.reports[0]["message"])
                self.assertIs(self.server._load_enabled_toolsets, original)
                self.assertNotIn("rules", self.builder.PLATFORM_HINTS["notch_companion"])
                self.send({"bind": "live-a", "url": "http://127.0.0.1:9/mcp", "token": "token-a"})
                self.assertEqual(self.delegation.bindings, {})

    def test_each_call_carries_the_calling_sessions_own_token(self):
        url = self.companion()
        self.send({"tools": self.TOOLS})
        self.send({"bind": "live-a", "url": url, "token": "token-a"})
        self.send({"bind": "live-b", "url": url, "token": "token-b"})
        self.send({"bind": "live-c", "url": "http://198.51.100.7/mcp", "token": "token-c"})
        self.assertEqual(self.call("delegate_task", "key-b", {"task": "Review"}), '{"taskId": "t1"}')
        authorization, body = Companion.calls[0]
        self.assertEqual(authorization, "Bearer token-b")
        self.assertEqual((body["method"], body["params"]), ("tools/call", {"name": "delegate_task", "arguments": {"task": "Review"}}))
        # Compression rotates the agent's key before the live session follows.
        self.server._sessions["live-a"]["agent"] = SimpleNamespace(session_id="key-a-2")
        self.call("task_status", "key-a-2")
        self.assertEqual(Companion.calls[1][0], "Bearer token-a")
        for session in ("key-c", "unknown", None):  # off-loopback binds and unknown callers never reach the companion
            self.assertEqual(json.loads(self.call("task_status", session))["code"], "capability_denied")
        self.assertEqual(len(Companion.calls), 2)

    def test_errors_and_revocation_reach_the_agent(self):
        url = self.companion()
        self.send({"tools": self.TOOLS})
        self.send({"bind": "live-a", "url": url, "token": "token-a"})
        Companion.result = {"content": [{"type": "text", "text": '{"code": "task_not_found", "message": "No such task."}'}], "isError": True}
        self.assertEqual(json.loads(self.call("task_status", "key-a")), {"error": "No such task.", "code": "task_not_found"})
        Companion.status = 401
        self.assertEqual(json.loads(self.call("task_status", "key-a"))["code"], "capability_denied")
        self.assertNotIn("live-a", self.delegation.bindings, "A revoked token is forgotten")

    def test_stop_closes_the_waiting_request(self):
        url = self.companion()
        Companion.release = threading.Event()
        self.addCleanup(Companion.release.set)
        stop_at = time.monotonic() + 0.3
        started = time.monotonic()
        with self.assertRaises(InterruptedError):
            frontend.post_json(url, "token", {"jsonrpc": "2.0", "id": 1, "method": "tools/call"},
                               interrupted=lambda: time.monotonic() > stop_at)
        self.assertLess(time.monotonic() - started, 3, "Stop must not wait for the companion's answer")


if __name__ == "__main__":
    unittest.main()
