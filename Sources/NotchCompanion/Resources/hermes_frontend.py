#!/usr/bin/env python3
"""Start the shipped Hermes headless frontend with the existing profile.

The Swift parent supplies a sandbox, an ephemeral loopback credential and a
stdin ownership pipe. This launcher does not copy a profile, write configuration,
start the messaging gateway or acquire OAuth refresh ownership.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import threading
from urllib.parse import urlparse


class FrontendConfigurationError(RuntimeError):
    """Only explicitly authored messages from this launcher may reach the UI."""


def load_auth_guard():
    path = Path(__file__).with_name("hermes_shared_auth.py")
    spec = importlib.util.spec_from_file_location("notch_shared_auth", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_configuration(config):
    """Fail closed when a frontend would gain unvalidated service ownership."""
    if config.get("local_runtime", {}).get("enabled", False):
        raise FrontendConfigurationError("Hermes managed local model services are enabled. This connection cannot safely take ownership of them.")
    if config.get("sessions", {}).get("auto_archive", False):
        raise FrontendConfigurationError("Hermes automatic session archiving is enabled. The companion cannot start a shared frontend that archives unrelated conversations.")
    # A new compute-host interpreter would not inherit our process-local OAuth
    # guard. Never quietly disable the user's setting or start an unguarded host.
    value = config.get("dashboard", {}).get("turn_isolation", False)
    if value is True or str(value).strip().lower() in ("1", "true", "yes", "on"):
        raise FrontendConfigurationError("Hermes dashboard turn isolation is enabled. Its child runtime cannot preserve the companion's no-refresh authentication guard.")


def validate_public_dashboard(public_url):
    # Native public-dashboard ticket auth rejects the private process token.
    # Do not disable that policy or claim desktop/gateway ownership to bypass it.
    if public_url and urlparse(public_url).hostname not in ("localhost", "127.0.0.1", "::1"):
        raise FrontendConfigurationError("This Hermes profile uses public dashboard authentication, which the companion cannot connect through yet. Use Hermes directly or select an existing local-only profile.")


def frontend_arguments(profile):
    # Pin identity through native startup; otherwise its sticky active_profile
    # can redirect this process. --isolated prevents named-profile serve
    # re-exec, which would lose process-local authentication protections.
    from hermes_cli.profiles import resolve_profile_env
    profile_name = profile.name if profile.parent.name == "profiles" else "default"
    if Path(resolve_profile_env(profile_name)).resolve() != profile:
        raise FrontendConfigurationError("Hermes resolves this profile to a different folder. Select its canonical existing profile folder before reconnecting.")
    return ["hermes", "--profile", profile_name, "serve", "--isolated", "--host", "127.0.0.1", "--port", "0"]


def validate_profile_environment(profile):
    configured = os.environ.get("HERMES_HOME")
    if not configured or Path(configured).resolve() != profile or "HERMES_DESKTOP" in os.environ:
        raise FrontendConfigurationError("Hermes environment settings change the selected profile or frontend ownership. Remove those routing overrides in Hermes before reconnecting.")
    os.environ["HERMES_HOME"] = str(profile)


def load_profile_environment(source, profile):
    """Keep native provider settings and process-owned transport auth on reload."""
    from hermes_cli import env_loader
    original = env_loader.load_hermes_dotenv
    session_token = os.environ["HERMES_DASHBOARD_SESSION_TOKEN"]

    def load(*args, **kwargs):
        requested = kwargs.get("hermes_home")
        if requested and Path(requested).resolve() != profile:
            raise FrontendConfigurationError("The shared Hermes frontend cannot load a different profile's environment.")
        result = original(*args, **kwargs)
        validate_profile_environment(profile)
        # main.py and hot reload call this again. A saved dashboard token must
        # never replace the parent's private process-only credential.
        os.environ["HERMES_DASHBOARD_SESSION_TOKEN"] = session_token
        return result

    env_loader.load_hermes_dotenv = load
    load(hermes_home=profile, project_env=source / ".env")


def install_reasoning_catalog():
    """Expose the installed runtime's effort vocabulary alongside its model catalog."""
    from hermes_cli import inventory
    import hermes_constants
    efforts = getattr(hermes_constants, "VALID_REASONING_EFFORTS", ())
    original = inventory.build_model_options_payload

    def options(*args, **kwargs):
        payload = original(*args, **kwargs)
        return {**payload, "reasoning_efforts": ["none", *efforts] if efforts else []}

    inventory.build_model_options_payload = options


COMPANION_SOURCE = "notch_companion"
COMPANION_SURFACE_HINT = (
    "You are chatting in Notch Companion, a compact native macOS chat panel in the menu-bar notch. Markdown "
    "renders headings, lists, quotes, links and fenced code; tables do not render, so use lists or labeled lines. "
    "Deliver files by writing MEDIA:/absolute/path/to/file on its own line: images show inline and other files "
    "appear as cards the user can open. A local image can also be shown with ![alt](/absolute/path)."
)


def install_surface_hint():
    """Describe the companion's chat surface to the sessions it creates.

    Process-local, like the native desktop app's own platform hint; nothing is
    written. A user's ``platform_hints.notch_companion`` setting still applies.
    """
    try:
        from agent import prompt_builder
    except Exception:
        return
    hints = getattr(prompt_builder, "PLATFORM_HINTS", None)
    if isinstance(hints, dict):
        hints.setdefault(COMPANION_SOURCE, COMPANION_SURFACE_HINT)


NOTCH_TOOLSET = "notch"
# The companion's longest delegation wait is 60 minutes; every harness gets 65.
NOTCH_TOOL_TIMEOUT = 65 * 60
NOTCH_UNAVAILABLE = ("This Hermes version does not offer the tool interfaces Notch Companion delegation needs, "
                     "so this session cannot delegate. It works as usual otherwise.")


def notch_tool_error(code, message):
    return json.dumps({"error": message, "code": code})


def post_json(url, token, payload, interrupted=lambda: False, timeout=NOTCH_TOOL_TIMEOUT):
    """POST one JSON-RPC request; a Hermes Stop closes the connection, which
    cancels the call in the companion (an abandoned wait never acknowledges)."""
    import http.client
    import socket
    target = urlparse(url)
    connection = http.client.HTTPConnection(target.hostname, target.port, timeout=timeout)
    body = json.dumps(payload).encode()
    outcome = {}

    def run():
        try:
            connection.request("POST", target.path, body, {
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                "Authorization": "Bearer " + token})
            response = connection.getresponse()
            outcome["reply"] = (response.status, response.read())
        except Exception as error:
            outcome["error"] = error

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    stopped = False
    while worker.is_alive():
        worker.join(0.25)
        if worker.is_alive() and interrupted():
            stopped = True
            if connection.sock is not None:
                try:
                    connection.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
    connection.close()
    if stopped:
        raise InterruptedError
    if "error" in outcome:
        raise outcome["error"]
    return outcome["reply"]


class NotchDelegation:
    """The companion's delegation tools as native tools of this frontend.

    The parent sends one tools line, then a bind line per session it opens, on
    the ownership pipe; tokens live only in this process's memory. A call
    resolves its calling session and uses that session's own token.
    """

    def __init__(self, report=None):
        self.lock = threading.Lock()
        self.bindings = {}  # live session id -> (url, token)
        self.server = None
        self.ready = False
        self.report = report or (lambda payload: print("NOTCH_DELEGATION " + json.dumps(payload), file=sys.__stderr__, flush=True))

    def receive(self, line):
        try:
            message = json.loads(line)
        except ValueError:
            return
        if not isinstance(message, dict):
            return
        if isinstance(message.get("tools"), list):
            try:
                self.install(message["tools"], message.get("instructions") or "")
                self.report({"ready": True})
            except LookupError as error:
                self.report({"ready": False, "message": str(error)})
            except Exception:
                self.report({"ready": False, "message": NOTCH_UNAVAILABLE})
            return
        sid, url, token = message.get("bind"), message.get("url"), message.get("token")
        target = urlparse(url) if isinstance(url, str) else None
        # Only the companion's loopback server ever receives a session's token.
        if (self.ready and isinstance(sid, str) and isinstance(token, str) and token and target
                and target.scheme == "http" and target.hostname == "127.0.0.1"):
            with self.lock:
                self.bindings[sid] = (url, token)

    def install(self, tools, instructions):
        """Register once; fail closed when Hermes's internals do not match."""
        server = sys.modules.get("tui_gateway.server")
        from tools.registry import registry
        from agent import prompt_builder
        import inspect
        hints = getattr(prompt_builder, "PLATFORM_HINTS", None)
        if (server is None or not isinstance(getattr(server, "_sessions", None), dict)
                or not hasattr(server, "_sessions_lock") or not callable(getattr(server, "_load_enabled_toolsets", None))
                or not isinstance(hints, dict) or not callable(getattr(registry, "get_entry", None))
                or "execution_timeout" not in inspect.signature(registry.register).parameters):
            raise LookupError(NOTCH_UNAVAILABLE)
        tools = [tool for tool in tools if isinstance(tool, dict) and isinstance(tool.get("name"), str) and tool["name"]]
        names = ["mcp__notch__" + tool["name"] for tool in tools]
        for name in names:
            existing = registry.get_entry(name)
            if existing is not None and existing.toolset != NOTCH_TOOLSET:
                raise LookupError("Hermes already has a tool named " + name + ", so Notch Companion did not add its "
                                  "delegation tools. Rename the Hermes MCP server called notch to delegate from Hermes.")
        for name, tool in zip(names, tools):
            handler = self.handler(tool["name"])
            schema = tool.get("inputSchema") if isinstance(tool.get("inputSchema"), dict) else {"type": "object", "properties": {}}
            registry.register(name, NOTCH_TOOLSET, {"name": name, "description": tool.get("description") or name,
                                                    "parameters": schema}, handler, execution_timeout=NOTCH_TOOL_TIMEOUT)
            if getattr(registry.get_entry(name), "handler", None) is not handler:
                raise LookupError(NOTCH_UNAVAILABLE)
        if self.ready:
            return
        original = server._load_enabled_toolsets

        def enabled_toolsets(*args, **kwargs):
            selected = original(*args, **kwargs)
            # None already means every toolset; [] is the profile's explicit zero-tool choice.
            if isinstance(selected, list) and selected and NOTCH_TOOLSET not in selected:
                return [*selected, NOTCH_TOOLSET]
            return selected

        # Split modules are rebound onto tui_gateway.server's globals, so its
        # binding is the one every agent build reads.
        server._load_enabled_toolsets = enabled_toolsets
        if instructions:
            hints[COMPANION_SOURCE] = hints.get(COMPANION_SOURCE, COMPANION_SURFACE_HINT) + "\n\n" + instructions
        self.server = server
        self.ready = True

    def handler(self, tool):
        def call(args, session_id=None):
            return self.call(tool, args, session_id)
        return call

    def binding(self, session_id):
        """The calling session by its stored key; compression rotates that key
        on the agent before the live session record follows."""
        server = self.server
        if not session_id or server is None:
            return None
        with server._sessions_lock:
            sids = [sid for sid, session in server._sessions.items()
                    if session_id in (session.get("session_key"), getattr(session.get("agent"), "session_id", None))]
        with self.lock:
            return next(((sid, self.bindings[sid]) for sid in sids if sid in self.bindings), None)

    def call(self, tool, arguments, session_id=None):
        found = self.binding(session_id)
        if found is None:
            return notch_tool_error("capability_denied", "Notch Companion has not enabled delegation for this Hermes session.")
        sid, (url, token) = found
        try:
            from tools.interrupt import is_interrupted
        except ImportError:
            is_interrupted = lambda: False  # noqa: E731
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                   "params": {"name": tool, "arguments": arguments if isinstance(arguments, dict) else {}}}
        try:
            status, body = post_json(url, token, request, is_interrupted)
        except InterruptedError:
            return notch_tool_error("interrupted", "Stopped before Notch Companion answered.")
        except Exception:
            return notch_tool_error("orchestration_error", "Notch Companion could not be reached.")
        if status == 401:
            # Revoked in the companion: forget it unless a newer bind replaced it.
            with self.lock:
                if self.bindings.get(sid) == (url, token):
                    del self.bindings[sid]
            return notch_tool_error("capability_denied", "Notch Companion ended this session's delegation access.")
        try:
            reply = json.loads(body)
            if isinstance(reply.get("error"), dict):
                return notch_tool_error("orchestration_error", str(reply["error"].get("message") or "Notch Companion refused the call."))
            result = reply["result"]
            text = "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
        except (ValueError, KeyError, TypeError, AttributeError):
            return notch_tool_error("orchestration_error", "Notch Companion returned an unreadable answer.")
        if not result.get("isError"):
            return text
        try:
            failure = json.loads(text)
            return notch_tool_error(str(failure["code"]), str(failure["message"]))
        except (ValueError, KeyError, TypeError):
            return notch_tool_error("orchestration_error", text)


def watch_parent(cleanup=None, receive=None):
    """A crashed/quitting parent cannot leave an orphaned owned frontend. Lines
    on the same pipe carry the companion's delegation tools and bindings."""
    try:
        for line in sys.stdin.buffer:
            if receive is not None:
                try:
                    receive(line)
                except Exception:
                    pass
    finally:
        if cleanup is not None:
            cleanup()
        os.kill(os.getpid(), signal.SIGTERM)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--profile-home", type=Path, required=True)
    args = parser.parse_args()
    try:
        source, profile = args.source.resolve(), args.profile_home.resolve()
        if not (source / "hermes_cli" / "main.py").is_file():
            raise FrontendConfigurationError("The installed Hermes does not provide the supported headless frontend.")
        validate_profile_environment(profile)
        if not os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN"):
            raise FrontendConfigurationError("The Hermes frontend requires a process-only authentication credential.")
        if "HERMES_DESKTOP" in os.environ:
            raise FrontendConfigurationError("The companion cannot take desktop gateway or cron lifecycle ownership.")
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(source))
        # Managed installs activate their existing dependency generation here,
        # before third-party imports, just as the native launcher does.
        if (source / "hermes_bootstrap.py").is_file():
            try:
                importlib.import_module("hermes_bootstrap")
            except (Exception, SystemExit):
                raise FrontendConfigurationError("Hermes could not activate this profile's installed Python dependencies. Open the selected profile in Hermes to complete setup or updates, then reconnect.") from None
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from hermes_cli.config import load_config_readonly
        try:
            configuration = load_config_readonly()
        except PermissionError:
            raise FrontendConfigurationError("This Hermes profile needs setup or an update to its protected files. Open the selected profile in Hermes to complete that step, then reconnect. The companion leaves its configuration and identity unchanged.") from None
        validate_configuration(configuration)
        guard = load_auth_guard()
        try:
            resolve_provider = guard.install_authentication_guard()
        except (ImportError, AttributeError):
            raise FrontendConfigurationError("The installed Hermes authentication interfaces are incompatible with this companion version. Update Hermes or the companion, then reconnect.") from None
        # Match native startup: profile .env wins over stale shell exports;
        # project .env is only its normal fallback. No credentials are copied.
        load_profile_environment(source, profile)
        from hermes_cli.dashboard_auth.prefix import resolve_public_url
        validate_public_dashboard(resolve_public_url())
        arguments = frontend_arguments(profile)
        install_reasoning_catalog()
        install_surface_hint()
        try:
            guard.validate_provider(resolve_provider)
        except guard.SharedAuthError as error:
            raise FrontendConfigurationError(str(error)) from None
        # LaunchServices cannot start a new private CUA app from any Seatbelt
        # sandbox, even allow-default. Relay only that validated launch to our
        # native parent, leaving this frontend's entire protection intact.
        cleanup_computer_use = None
        relay_directory = os.environ.get("NOTCH_CUA_RELAY_DIR")
        if relay_directory:
            from hermes_computer_use import install_optional_launch_relay, ComputerUseRelayError
            try:
                cleanup_computer_use = install_optional_launch_relay(relay_directory)
            except (ComputerUseRelayError, OSError):
                raise FrontendConfigurationError("The companion's computer-use launcher is incompatible or unavailable. Rebuild the app before reconnecting.") from None
        threading.Thread(target=watch_parent, args=(cleanup_computer_use, NotchDelegation().receive), daemon=True).start()
        sys.argv = arguments
        # Import under its real module name, like Hermes's console script.
        # runpy(__main__) lets native helpers import it a second time after
        # --profile was consumed, reapplying the unrelated sticky profile.
        importlib.import_module("hermes_cli.main").main()
    except Exception as error:
        # No traceback or arbitrary backend text: auth/config exceptions can
        # contain credentials. Only this launcher's explicitly authored errors pass.
        message = str(error) if isinstance(error, FrontendConfigurationError) else "Hermes could not start its shared frontend. Check your existing Hermes installation, then reconnect."
        print("NOTCH_FRONTEND_ERROR " + json.dumps({"message": message}), file=sys.__stderr__, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
