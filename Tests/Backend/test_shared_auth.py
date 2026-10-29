"""Offline native resolver checks using isolated profiles and invented credentials.

Set NOTCH_HERMES_INSTALL to test another supported Hermes checkout. Each case
runs in a fresh process with an empty environment/HOME, denies network/process
launches, and checks that its config, .env and auth.json stayed byte-identical.
No real user store, installed .env, or account-backed model call is used.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

RESOURCES = Path(__file__).resolve().parents[2] / "Sources/NotchCompanion/Resources"
SOURCE = Path(os.environ.get("NOTCH_HERMES_INSTALL", Path.home() / ".hermes/hermes-agent"))

CHILD = r'''
import json, os, pathlib, socket, subprocess
home = pathlib.Path(os.environ["HERMES_HOME"])
from hermes_cli.env_loader import load_hermes_dotenv
load_hermes_dotenv(hermes_home=home, load_external_secrets=False)
from hermes_shared_auth import install_authentication_guard, validate_provider, SharedAuthError

def forbidden(*args, **kwargs):
    raise AssertionError("Authentication resolution attempted network/process access")
socket.socket.connect = forbidden
socket.create_connection = forbidden
subprocess.Popen = forbidden
resolve = install_authentication_guard()
case = json.loads(os.environ["NOTCH_TEST_CASE"])
from hermes_cli import auth, auth_codex
from agent import credential_pool, anthropic_credentials
try:
    if case.get("operation") == "refresh":
        for callback in (auth.refresh_codex_oauth_pure, auth_codex._refresh_codex_auth_tokens,
                         auth.resolve_qwen_runtime_credentials, auth.resolve_xai_oauth_runtime_credentials,
                         auth.resolve_nous_runtime_credentials, auth.resolve_minimax_oauth_runtime_credentials,
                         anthropic_credentials.refresh_anthropic_oauth_pure):
            try:
                callback("fake-refresh-grant")
            except auth.AuthError as error:
                assert "cannot refresh" in str(error)
            else:
                raise AssertionError("Refresh escaped guard")
        print(json.dumps({"ok": True}))
    elif case.get("operation") == "codex_reread":
        before = auth_codex._read_codex_tokens()
        assert set(before["tokens"]) == {"access_token"}
        value = json.loads((home / "auth.json").read_text())
        value["providers"]["openai-codex"]["tokens"]["access_token"] = case["replacement"]
        (home / "auth.json").write_text(json.dumps(value))
        after = auth_codex._read_codex_tokens()
        assert before["tokens"]["access_token"] != after["tokens"]["access_token"]
        assert after["tokens"]["access_token"] == case["replacement"]
        print(json.dumps({"ok": True}))
    elif case.get("operation") == "auxiliary":
        from agent import auxiliary_client
        from agent.command_token_source import build_command_token_provider
        from agent.vertex_adapter import get_vertex_config
        from agent.bedrock_adapter import has_aws_credentials, _get_bedrock_runtime_client
        from hermes_cli.copilot_auth import resolve_copilot_token
        for callback in (lambda: build_command_token_provider("must-not-execute", "office"),
                         get_vertex_config, lambda: _get_bedrock_runtime_client("us-east-1"), resolve_copilot_token,
                         lambda: auth.resolve_external_process_provider_credentials("copilot-acp"),
                         lambda: auxiliary_client._named_custom_api_key({"key_cmd": "must-not-execute"}, "office", "https://office.example.test")):
            try:
                callback()
            except auth.AuthError as error:
                assert "not supported" in str(error)
            else:
                raise AssertionError("Auxiliary credentials escaped guard")
        assert has_aws_credentials() is False
        print(json.dumps({"ok": True}))
    elif case.get("operation") == "pool_rotation":
        pool = credential_pool.load_pool("deepseek")
        first = pool.select()
        assert first is not None
        assert pool.try_refresh_current() is None
        second = pool.select()
        assert second is not None and second.id != first.id
        print(json.dumps({"ok": True}))
    elif case.get("operation") == "pool":
        pool = credential_pool.load_pool("anthropic")
        assert len(pool.entries()) == 1
        entry = pool.select()
        assert entry.auth_type == "api_key" and not entry.refresh_token
        pool._persist()
        print(json.dumps({"ok": True}))
    else:
        validate_provider(resolve)
        runtime = resolve()
        # Compare secrets inside child; never emit one, even on failure.
        if "expected_key" in case:
            assert runtime["api_key"] == case["expected_key"], "Wrong credential selected"
        print(json.dumps({"provider": runtime.get("provider"), "api_mode": runtime.get("api_mode"),
                          "base_url": runtime.get("base_url"), "source": runtime.get("source")}))
except SharedAuthError as error:
    print(json.dumps({"error": str(error)}))
'''


def jwt(expiry):
    payload = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).decode().rstrip("=")
    return "fake." + payload + ".signature"


@unittest.skipIf(os.environ.get("NOTCH_SKIP_HERMES_TESTS") == "1", "Installed Hermes resolver checks are excluded from portable offline checks")
@unittest.skipUnless((SOURCE / "hermes_cli/runtime_provider.py").is_file(), "Requires installed Hermes native resolver")
class SharedAuthTests(unittest.TestCase):
    def run_case(self, model, *, env="", auth=None, operation=None, expected_key=None, replacement=None, config_extra=None, named_profile=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "profiles/work" if named_profile else root
            home.mkdir(parents=True, exist_ok=True)
            files = {home / "config.yaml": json.dumps({"model": model, **(config_extra or {})}), home / ".env": env}
            if auth is not None:
                files[(root if named_profile else home) / "auth.json"] = json.dumps(auth)
            for path, value in files.items():
                path.write_text(value)
            case = {k: v for k, v in {"operation": operation, "expected_key": expected_key, "replacement": replacement}.items() if v is not None}
            environment = {"HOME": str(root), "HERMES_HOME": str(home), "PATH": os.defpath,
                           "PYTHONPATH": os.pathsep.join((str(SOURCE), str(RESOURCES))),
                           "PYTHONDONTWRITEBYTECODE": "1", "NOTCH_TEST_CASE": json.dumps(case)}
            result = subprocess.run([sys.executable, "-B", "-c", CHILD], cwd=home, env=environment, capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, "Offline native auth fixture failed: " + result.stderr[-2000:])
            for path, value in files.items():
                if operation != "codex_reread" or path.name != "auth.json":
                    self.assertEqual(path.read_text(), value, "Provider resolution changed a protected file")
            return json.loads(result.stdout.strip().splitlines()[-1])

    def test_api_key_without_any_codex_login(self):
        result = self.run_case({"provider": "openrouter", "default": "test-model"}, env="OPENROUTER_API_KEY=sk-or-v1-offline-fixture\n", expected_key="sk-or-v1-offline-fixture")
        self.assertEqual(result["provider"], "openrouter")

    def test_native_auto_detects_env_provider(self):
        result = self.run_case({"provider": "auto", "default": "test-model"}, env="GEMINI_API_KEY=offline-google-key\n", expected_key="offline-google-key")
        self.assertEqual(result["provider"], "gemini")

    def test_anthropic_api_key_has_no_claude_login_requirement(self):
        result = self.run_case({"provider": "anthropic", "default": "test-model"}, env="ANTHROPIC_API_KEY=sk-ant-api03-offline-fixture\n", expected_key="sk-ant-api03-offline-fixture")
        self.assertEqual(result["provider"], "anthropic")
        self.assertEqual(result["api_mode"], "anthropic_messages")

    def test_custom_endpoint_keeps_explicit_api_key(self):
        result = self.run_case({"provider": "custom", "default": "test-model", "base_url": "https://inference.example.test/v1", "api_key": "offline-custom-key"}, expected_key="offline-custom-key")
        self.assertEqual(result["provider"], "custom")
        self.assertEqual(result["base_url"], "https://inference.example.test/v1")

    def test_named_custom_endpoint_keeps_native_key_env_and_transport(self):
        result = self.run_case({"provider": "custom:office", "default": "test-model"},
            env="HERMES_CUSTOM_OFFICE_KEY=offline-office-key\n", expected_key="offline-office-key",
            config_extra={"providers": {"office": {"base_url": "https://office.example.test/v1",
                "key_env": "HERMES_CUSTOM_OFFICE_KEY", "transport": "chat_completions"}}})
        self.assertEqual(result["provider"], "custom")
        self.assertEqual(result["base_url"], "https://office.example.test/v1")

    def test_custom_credential_command_is_not_started(self):
        result = self.run_case({"provider": "custom:office", "default": "test-model"},
            config_extra={"providers": {"office": {"base_url": "https://office.example.test/v1",
                "key_cmd": "must-not-execute"}}})
        self.assertIn("not supported", result["error"])

    def test_azure_api_key_keeps_native_endpoint(self):
        result = self.run_case({"provider": "azure-foundry", "base_url": "https://azure.example.test/v1", "default": "test-model"},
            env="AZURE_FOUNDRY_API_KEY=offline-azure-key\n", expected_key="offline-azure-key")
        self.assertEqual(result["provider"], "azure-foundry")

    def test_external_local_endpoint_does_not_need_oauth(self):
        result = self.run_case({"provider": "custom", "default": "local-test-model", "base_url": "http://127.0.0.1:11434/v1"})
        self.assertEqual(result["base_url"], "http://127.0.0.1:11434/v1")

    def test_lmstudio_without_a_key(self):
        result = self.run_case({"provider": "lmstudio", "default": "local-test-model"})
        self.assertEqual(result["provider"], "lmstudio")

    def test_stored_static_key_resolves_without_pool_writes(self):
        store = {"credential_pool": {"deepseek": [{"id": "offline", "auth_type": "api_key", "source": "manual", "access_token": "offline-deepseek-key"}]}}
        result = self.run_case({"provider": "deepseek", "default": "test-model"}, auth=store, expected_key="offline-deepseek-key")
        self.assertEqual(result["provider"], "deepseek")

    def test_missing_credentials_produces_authored_recovery(self):
        for provider in ("openrouter", "auto"):
            result = self.run_case({"provider": provider, "default": "test-model"})
            self.assertIn("hermes model", result["error"])
            self.assertNotIn("Codex", result["error"])

    def test_codex_reads_access_only_and_rereads_owner(self):
        token = jwt(time.time() + 3600)
        store = {"providers": {"openai-codex": {"tokens": {"access_token": token, "refresh_token": "must-not-be-copied"}}}}
        result = self.run_case({"provider": "openai-codex", "default": "test-model"}, auth=store, expected_key=token)
        self.assertEqual(result["provider"], "openai-codex")
        self.assertEqual(result["source"], "notch-read-only-hermes")
        self.assertTrue(self.run_case({"provider": "openai-codex"}, auth=store, operation="codex_reread", replacement=jwt(time.time() + 7200))["ok"])

    def test_codex_account_is_not_selected_by_latest_expiry(self):
        selected = jwt(time.time() + 1800)
        other = jwt(time.time() + 7200)
        store = {"providers": {"openai-codex": {"tokens": {"access_token": selected}}},
                 "credential_pool": {"openai-codex": [{"access_token": other, "auth_type": "oauth"}]}}
        result = self.run_case({"provider": "openai-codex"}, auth=store, expected_key=selected)
        self.assertEqual(result["provider"], "openai-codex")
        store["providers"] = {}
        result = self.run_case({"provider": "openai-codex"}, auth=store, expected_key=other)
        self.assertEqual(result["provider"], "openai-codex")
        store["credential_pool"]["openai-codex"].append({"access_token": selected, "auth_type": "oauth"})
        result = self.run_case({"provider": "openai-codex"}, auth=store)
        self.assertIn("multiple usable Codex accounts", result["error"])

    def test_named_profile_uses_native_root_auth_fallback(self):
        token = jwt(time.time() + 3600)
        store = {"providers": {"openai-codex": {"tokens": {"access_token": token, "refresh_token": "must-not-be-copied"}}}}
        result = self.run_case({"provider": "openai-codex", "default": "test-model"}, auth=store, expected_key=token, named_profile=True)
        self.assertEqual(result["source"], "notch-read-only-hermes")

    def test_malformed_codex_token_is_not_reported_ready(self):
        for token in ("not-a-jwt", "fake.e30.signature", jwt(float("nan")), jwt(float("inf"))):
            with self.subTest(token_kind=token.split(".")[0]):
                store = {"providers": {"openai-codex": {"tokens": {"access_token": token, "refresh_token": "must-not-be-used"}}}}
                result = self.run_case({"provider": "openai-codex"}, auth=store)
                self.assertIn("sign-in needs renewal", result["error"])

    def test_expired_codex_has_no_refresh_attempt(self):
        store = {"providers": {"openai-codex": {"tokens": {"access_token": jwt(time.time() - 60), "refresh_token": "must-not-be-used"}}}}
        result = self.run_case({"provider": "openai-codex"}, auth=store)
        self.assertIn("sign-in needs renewal", result["error"])

    def test_unreviewed_oauth_providers_fail_before_refresh(self):
        for provider in ("nous", "qwen-oauth", "xai-oauth", "minimax-oauth", "copilot", "vertex", "bedrock", "copilot-acp"):
            with self.subTest(provider=provider):
                result = self.run_case({"provider": provider, "default": "test-model"})
                self.assertIn("not supported", result["error"])

    def test_direct_refresh_functions_and_imported_aliases_are_blocked(self):
        self.assertTrue(self.run_case({"provider": "openrouter"}, operation="refresh")["ok"])

    def test_pool_excludes_refresh_grants_and_mislabeled_oauth(self):
        rows = [{"id": "static", "auth_type": "api_key", "source": "manual", "access_token": "sk-ant-api03-offline"},
                {"id": "oauth", "auth_type": "oauth", "access_token": "access", "refresh_token": "grant"},
                {"id": "mislabeled", "auth_type": "api_key", "access_token": "sk-ant-oat01-offline"}]
        self.assertTrue(self.run_case({"provider": "anthropic"}, auth={"credential_pool": {"anthropic": rows}}, operation="pool")["ok"])

    def test_auxiliary_credential_paths_cannot_refresh_or_spawn(self):
        self.assertTrue(self.run_case({"provider": "openrouter"}, operation="auxiliary")["ok"])

    def test_api_key_pool_rotates_after_401_without_writing_owner_store(self):
        rows = [{"id": name, "auth_type": "api_key", "source": "manual", "access_token": "offline-key-" + name} for name in ("first", "second")]
        self.assertTrue(self.run_case({"provider": "deepseek"}, auth={"credential_pool": {"deepseek": rows}}, operation="pool_rotation")["ok"])

    def test_azure_sdk_auth_and_codex_child_runtime_fail_closed(self):
        result = self.run_case({"provider": "azure-foundry", "auth_mode": "entra_id", "base_url": "https://azure.example.test/v1", "default": "test-model"})
        self.assertIn("not supported", result["error"])
        result = self.run_case({"provider": "openai-api", "openai_runtime": "codex_app_server", "default": "test-model"}, env="OPENAI_API_KEY=sk-offline-key\n")
        self.assertIn("not supported", result["error"])
        store = {"providers": {"openai-codex": {"tokens": {"access_token": jwt(time.time() + 3600)}}}}
        result = self.run_case({"provider": "openai-codex", "openai_runtime": "codex_app_server"}, auth=store)
        self.assertIn("not supported", result["error"])


if __name__ == "__main__":
    unittest.main()
