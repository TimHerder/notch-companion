"""Offline policy checks for the shared frontend. No real credentials or stores."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
import io
import sys
import os
import tempfile
from types import ModuleType

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

    def test_guard_is_loaded_without_preparing_private_home(self):
        guard = frontend.load_auth_guard()
        self.assertTrue(callable(guard.install_authentication_guard))
        self.assertTrue(callable(guard.validate_provider))


if __name__ == "__main__":
    unittest.main()
