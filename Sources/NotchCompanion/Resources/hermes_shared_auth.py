"""Provider-neutral authentication policy for the protected shared frontend.

Hermes keeps provider, endpoint, model and static-key resolution. This process
cannot own refresh grants or persist pool changes. It borrows existing Codex
access tokens; other account/SDK/child-process auth needs a reviewed adapter.
Nothing here is used by the legacy private-home bridge.
"""
from __future__ import annotations

import base64
import importlib
import json
import math
import sys
import time


class SharedAuthError(RuntimeError):
    """An authored, credential-free diagnostic safe to show in the companion."""


UNSUPPORTED = "This Hermes authentication method is not supported by the companion yet. Choose an API-key provider or an externally managed local endpoint with 'hermes model', or use Hermes directly."
RENEW_CODEX = "Hermes Codex sign-in needs renewal or cannot be read. Renew it in your existing Hermes, then reconnect. The companion never refreshes that login."
NO_PROVIDER = "Hermes has no usable provider credentials. Complete 'hermes model' in your existing Hermes profile, then reconnect. API keys can stay in that profile's .env or credential store."
NO_REFRESH = "The companion cannot refresh your existing Hermes login. Renew it in Hermes, then reconnect."


def _expiry(token):
    try:
        body = token.split(".")[1]
        return float(json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))).get("exp", 0))
    except (ValueError, IndexError, TypeError, AttributeError):
        return 0


def _replace_aliases(original, replacement):
    """Replace already-imported Hermes aliases as well as future origin imports."""
    for name, module in tuple(sys.modules.items()):
        if module is None or not name.startswith(("hermes_cli.", "agent.", "tools.", "tui_gateway.", "gateway.")):
            continue
        for key, value in tuple(vars(module).items()):
            if value is original:
                setattr(module, key, replacement)


def install_authentication_guard():
    """Install before frontend imports, then return the guarded native resolver.

    API-key pools use native selection/cooldowns in memory. Native load_pool
    seeds/normalizes/persists auth.json even on reads, so it is deliberately not
    called. Only existing static rows enter this process; OAuth rows never do.
    """
    from hermes_cli import auth, auth_codex, runtime_provider
    from agent import credential_pool, anthropic_credentials

    def fail(message=UNSUPPORTED):
        error = auth.AuthError(message)
        error.notch_message = message
        raise error

    def no_refresh(*_args, **_kwargs):
        fail(NO_REFRESH)

    def unsupported(*_args, **_kwargs):
        fail()

    class ReadOnlyPool(credential_pool.CredentialPool):
        def _persist(self, *_args, **_kwargs):
            # Cooldowns remain process-local; the owner's credential store wins.
            pass

    def load_static_pool(provider):
        entries = []
        for row in auth.read_credential_pool(provider):
            if not isinstance(row, dict) or row.get("refresh_token") or row.get("auth_type", "api_key") != "api_key":
                continue
            entry = credential_pool.PooledCredential.from_dict(provider, row)
            # Native normalization recognizes OAuth tokens mislabeled as keys.
            if entry.auth_type == "api_key" and not entry.refresh_token:
                entries.append(entry)
        return ReadOnlyPool(provider, entries)

    _replace_aliases(credential_pool.load_pool, load_static_pool)
    # Preserve native API-key exhaustion/rotation on 401; only OAuth refresh
    # requires ownership. Also protect pools retained before this hook installs.
    native_pool_refresh = credential_pool.CredentialPool._refresh_entry

    def refresh_static_entry(pool, entry, *, force):
        if entry.auth_type == credential_pool.AUTH_TYPE_OAUTH or entry.refresh_token:
            fail(NO_REFRESH)
        return native_pool_refresh(pool, entry, force=force)

    credential_pool.CredentialPool._refresh_entry = refresh_static_entry

    def read_codex(*, _lock=True):
        # These native readers honor named-profile/global-root fallback without
        # resolving, refreshing, importing or copying a grant into another store.
        state = auth.get_provider_auth_state("openai-codex") or {}
        tokens = state.get("tokens") or {}
        def usable(token):
            expiry = _expiry(token)
            return isinstance(token, str) and token and math.isfinite(expiry) and expiry > time.time() + 15

        # Keep the owner's selected account, even if another account has a
        # longer-lived access token. Never choose an account by token expiry.
        token = tokens.get("access_token")
        if usable(token):
            return {"tokens": {"access_token": token}, "last_refresh": state.get("last_refresh")}
        candidates = {}
        for row in auth.read_credential_pool("openai-codex"):
            if isinstance(row, dict) and row.get("last_status") not in ("dead", "exhausted") and usable(row.get("access_token")):
                candidates[row["access_token"]] = row.get("last_refresh")
        if not candidates:
            fail(RENEW_CODEX)
        if len(candidates) > 1:
            fail("Hermes has multiple usable Codex accounts but no current account token. Select and renew the intended account in Hermes, then reconnect.")
        token, stamp = next(iter(candidates.items()))
        return {"tokens": {"access_token": token}, "last_refresh": stamp}

    def resolve_codex(**_kwargs):
        value = read_codex()
        return auth_codex._codex_runtime_result(value["tokens"]["access_token"],
            source="notch-read-only-hermes", last_refresh=value["last_refresh"])

    _replace_aliases(auth_codex._read_codex_tokens, read_codex)
    _replace_aliases(auth_codex.resolve_codex_runtime_credentials, resolve_codex)

    # Block refresh at the actual provider origins too: helpers, 401 recovery,
    # model fallbacks and aliases must not bypass the central provider resolver.
    refresh_functions = {
        "hermes_cli.auth_codex": ("_refresh_codex_auth_tokens", "refresh_codex_oauth_pure"),
        "hermes_cli.auth_nous": ("_refresh_access_token", "refresh_nous_oauth_pure", "refresh_nous_oauth_from_state", "resolve_nous_runtime_credentials"),
        "hermes_cli.auth_xai": ("_refresh_xai_oauth_tokens", "refresh_xai_oauth_pure", "resolve_xai_oauth_runtime_credentials"),
        "hermes_cli.auth_qwen": ("_refresh_qwen_cli_tokens", "resolve_qwen_runtime_credentials"),
        "hermes_cli.auth_minimax": ("_refresh_minimax_oauth_state", "resolve_minimax_oauth_runtime_credentials"),
        "agent.anthropic_credentials": ("_refresh_oauth_token", "refresh_anthropic_oauth_pure"),
    }
    for module_name, names in refresh_functions.items():
        module = importlib.import_module(module_name)
        for name in names:
            original = getattr(module, name, None)
            if callable(original):
                _replace_aliases(original, no_refresh)
    _replace_aliases(auth.resolve_nous_access_token, no_refresh)

    # Anthropic's native API-key resolver also auto-discovers Claude OAuth and
    # reads Keychain. Keep API-key support, but do not borrow that other app's login.
    _replace_aliases(anthropic_credentials.read_claude_code_credentials, lambda: None)
    original_anthropic = anthropic_credentials.resolve_anthropic_token

    def resolve_anthropic(*args, **kwargs):
        token = original_anthropic(*args, **kwargs)
        if token and anthropic_credentials._is_oauth_token(token):
            fail()
        return token

    _replace_aliases(original_anthropic, resolve_anthropic)
    original_provider = auth.resolve_provider

    def resolve_provider(*args, **kwargs):
        provider = original_provider(*args, **kwargs)
        config = auth.PROVIDER_REGISTRY.get(provider)
        if provider not in ("openai-codex", "openrouter", "custom") and (
            provider == "copilot" or not config or config.auth_type != "api_key"
        ):
            fail()
        return provider

    _replace_aliases(original_provider, resolve_provider)
    # Native shortcut providers run before resolve_provider. Their SDK token
    # chains or child interpreters have not been reviewed for refresh ownership.
    from hermes_cli import runtime_provider_backends
    for module, name in ((runtime_provider, "_resolve_vertex_runtime"),
                         (runtime_provider_backends, "_azure_entra_credentials"),
                         (runtime_provider_backends, "_resolve_bedrock_runtime"),
                         (runtime_provider_backends, "_resolve_external_process_runtime")):
        _replace_aliases(getattr(module, name), unsupported)

    # Auxiliary models (title, compression, vision, MoA) sometimes construct
    # clients directly. Guard their credential origins too, before any helper
    # can mint tokens, refresh an SDK chain, or spawn a credential subprocess.
    unsupported_origins = {
        "agent.command_token_source": ("build_command_token_provider", "_mint"),
        "agent.vertex_adapter": ("get_vertex_credentials", "get_vertex_config", "has_vertex_credentials"),
        "agent.bedrock_adapter": ("has_aws_credentials", "_cached_client", "build_bedrock_openai_http_client", "configure_bedrock_openai_client_kwargs"),
        "hermes_cli.copilot_auth": ("resolve_copilot_token", "exchange_copilot_token", "get_copilot_api_token"),
    }
    # These optional SDK adapters otherwise auto-install dependencies at import.
    # No native/frontend threads exist yet; restore the installer immediately.
    from tools import lazy_deps
    native_ensure = lazy_deps.ensure
    try:
        lazy_deps.ensure = lambda *_args, **_kwargs: False
        for module_name, names in unsupported_origins.items():
            module = importlib.import_module(module_name)
            for name in names:
                replacement = (lambda *_args, **_kwargs: False) if name in ("has_aws_credentials", "has_vertex_credentials") else unsupported
                _replace_aliases(getattr(module, name), replacement)
    finally:
        lazy_deps.ensure = native_ensure
    _replace_aliases(auth.resolve_external_process_provider_credentials, unsupported)

    native_resolve = runtime_provider.resolve_runtime_provider

    def resolve_runtime(**kwargs):
        # Some Hermes versions apply this override later in agent construction.
        # Reject before resolving credentials as well as checking the result.
        if str(runtime_provider._get_model_config().get("openai_runtime", "")).lower() == "codex_app_server":
            fail()
        result = native_resolve(**kwargs)
        if callable(result.get("api_key")) or result.get("api_mode") in ("codex_app_server", "external_process"):
            fail()
        if not result.get("api_key") and result.get("provider") not in ("custom", "opencode-free"):
            fail(NO_PROVIDER)
        return result

    _replace_aliases(native_resolve, resolve_runtime)
    return resolve_runtime


def validate_provider(resolve):
    """Readiness only, without returning credentials/endpoint URLs to the UI."""
    try:
        resolve()
    except Exception as error:
        raise SharedAuthError(getattr(error, "notch_message", NO_PROVIDER)) from None
