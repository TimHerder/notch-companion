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


def watch_parent(cleanup=None):
    """A crashed/quitting parent cannot leave an orphaned owned frontend."""
    try:
        while sys.stdin.buffer.read(1):
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
        threading.Thread(target=watch_parent, args=(cleanup_computer_use,), daemon=True).start()
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
