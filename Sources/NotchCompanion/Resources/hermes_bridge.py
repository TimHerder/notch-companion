#!/usr/bin/env python3
"""Launch the installed Hermes RPC runtime with private state and borrowed access.

Never runs the messaging gateway, edits the installation, or refreshes its OAuth
grant. The native launcher adds an OS write denial for the source Hermes home.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import sys
import time


def private_write(path: Path, contents: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".notch-tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(contents)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def token_expiry(token: str) -> float:
    try:
        body = token.split(".")[1]
        return float(json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))).get("exp", 0))
    except (ValueError, IndexError, TypeError):
        return 0


def borrowed_codex_token(source_home: Path) -> tuple[str, str | None]:
    """Return only access tokens; never copy or submit the owner's refresh grant."""
    try:
        store = json.loads((source_home / "auth.json").read_text())
    except (OSError, ValueError):
        raise RuntimeError("Hermes sign-in could not be read. Sign in with Hermes, then reconnect.") from None
    state = (store.get("providers") or {}).get("openai-codex") or {}
    candidates = [(str((state.get("tokens") or {}).get("access_token") or ""), state.get("last_refresh"))]
    for row in (store.get("credential_pool") or {}).get("openai-codex") or []:
        candidates.append((str(row.get("access_token") or ""), row.get("last_refresh")))
    usable = [(token, stamp) for token, stamp in candidates if token and (not token_expiry(token) or token_expiry(token) > time.time() + 15)]
    if not usable:
        raise RuntimeError("Hermes sign-in needs renewal. Open your existing Hermes and send a message, then reconnect the companion. Its refresh token is never used by this app.")
    return max(usable, key=lambda pair: token_expiry(pair[0]))


def scrub_auth(value):
    """Keep static API-key rows only; never fork an OAuth owner."""
    if not isinstance(value, dict):
        return {"version": 1, "providers": {}, "credential_pool": {}}
    pools = {}
    for provider, rows in (value.get("credential_pool") or {}).items():
        safe = [row for row in rows if isinstance(row, dict)
                and row.get("auth_type") == "api_key" and not row.get("refresh_token")]
        if safe:
            pools[provider] = safe
    return {"version": value.get("version", 1), "providers": {}, "credential_pool": pools}


def prepare(source: Path, source_home: Path, app_home: Path) -> dict:
    source, source_home, app_home = source.resolve(), source_home.resolve(), app_home.resolve()
    if app_home == source_home or source_home in app_home.parents or app_home in source_home.parents:
        raise RuntimeError("The companion needs its own Hermes data directory outside your existing installation.")
    if not (source / "tui_gateway" / "entry.py").is_file():
        raise RuntimeError("The installed Hermes version does not have the required JSON-RPC gateway.")
    app_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(app_home, 0o700)
    workspace = app_home.parent / "Workspace"
    workspace.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.environ["HERMES_HOME"] = str(app_home)
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    os.environ["PYTHONUNBUFFERED"] = "1"
    os.environ["HERMES_TUI_PLATFORM"] = "cli"
    for key in ("HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE", "HERMES_TUI_SIDECAR_URL", "HERMES_SESSION_ID", "HERMES_SESSION_KEY"):
        os.environ.pop(key, None)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(source))
    import yaml
    from dotenv import dotenv_values
    config = yaml.safe_load((source_home / "config.yaml").read_text()) or {}
    # The copied settings retain the user's chosen model, reasoning and tools.
    # State-bearing paths and background services belong only to this frontend.
    config.setdefault("terminal", {})["cwd"] = str(workspace)
    config.setdefault("display", {})["tool_progress"] = "all"
    config.setdefault("dashboard", {})["process_isolation"] = False
    config["fallback_providers"] = []
    private_write(app_home / "config.yaml", yaml.safe_dump(config, sort_keys=False))
    env_values = dotenv_values(source_home / ".env")
    # Preserve provider/tool environment values while stripping path-routing
    # overrides and explicitly named refresh grants. No messaging service starts.
    excluded = ("HERMES_HOME", "HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE", "HERMES_TUI_SIDECAR_URL")
    env_text = "\n".join(f"{key}={json.dumps(value)}" for key, value in env_values.items()
                         if value is not None and key not in excluded and "REFRESH_TOKEN" not in key.upper()) + "\n"
    private_write(app_home / ".env", env_text)
    auth_path = source_home / "auth.json"
    auth = json.loads(auth_path.read_text()) if auth_path.is_file() else {}
    private_write(app_home / "auth.json", json.dumps(scrub_auth(auth)))
    # Copy identity, not personal memories, sessions, schedules, hooks, or plugins.
    soul = source_home / "SOUL.md"
    if soul.is_file():
        private_write(app_home / "SOUL.md", soul.read_text())
    os.chdir(workspace)
    return config


def install_borrowed_codex(source_home: Path) -> None:
    """Process-local adapter: the original Hermes remains sole OAuth refresh owner.

    The access token is reread for each resolver invocation (including recovery
    after a 401). No refresh-token request is ever made by this adapter.
    """
    from hermes_cli import auth, auth_codex

    def read_tokens(*, _lock=True):
        try:
            token, stamp = borrowed_codex_token(source_home)
        except RuntimeError as error:
            raise auth.AuthError(str(error)) from None
        return {"tokens": {"access_token": token}, "last_refresh": stamp}

    def resolve(**_kwargs):
        value = read_tokens()
        return auth_codex._codex_runtime_result(value["tokens"]["access_token"], source="notch-read-only-hermes", last_refresh=value["last_refresh"])

    def no_refresh(*_args, **_kwargs):
        raise auth.AuthError("The companion cannot rotate your existing Hermes login. Renew it in Hermes, then reconnect.")

    for module in (auth, auth_codex):
        module._read_codex_tokens = read_tokens
        module.resolve_codex_runtime_credentials = resolve
        module._refresh_codex_auth_tokens = no_refresh
        module.refresh_codex_oauth_pure = no_refresh
    # Imported aliases in this version's runtime-provider module must match.
    from hermes_cli import runtime_provider
    runtime_provider.resolve_codex_runtime_credentials = resolve


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-home", type=Path, required=True)
    parser.add_argument("--app-home", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.source, args.source_home, args.app_home)
        install_borrowed_codex(args.source_home)
        from tui_gateway.entry import main as gateway_main
        gateway_main()
    except Exception as error:
        # No repr/tracebacks: auth/config failures can include credential material.
        message = str(error) if isinstance(error, RuntimeError) else "Hermes could not start. Check that your existing Hermes installation works, then reconnect."
        print(json.dumps({"jsonrpc": "2.0", "method": "event", "params": {"type": "bridge.error", "payload": {"message": message}}}), file=sys.__stdout__, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
