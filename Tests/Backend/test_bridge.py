"""Offline safety checks; fixtures contain fake tokens only."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).resolve().parents[2] / "Sources/NotchCompanion/Resources/hermes_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def fake_token(expiry):
    body = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).decode().rstrip("=")
    return f"fake.{body}.fake"


class BridgeSafetyTests(unittest.TestCase):
    def test_oauth_grants_never_copied(self):
        original = {"version": 1, "providers": {"openai-codex": {"tokens": {"refresh_token": "fake-grant"}}},
                    "credential_pool": {"openai-codex": [{"auth_type": "oauth", "access_token": "fake", "refresh_token": "fake-grant"}],
                                        "api": [{"auth_type": "api_key", "access_token": "fake-static"}]}}
        snapshot = bridge.scrub_auth(original)
        self.assertEqual(snapshot["providers"], {})
        self.assertEqual(snapshot["credential_pool"], {"api": [{"auth_type": "api_key", "access_token": "fake-static"}]})
        self.assertNotIn("refresh_token", json.dumps(snapshot))
        self.assertIn("refresh_token", json.dumps(original))

    def test_borrowed_access_rereads_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            def save(expiry):
                token = fake_token(expiry)
                (home / "auth.json").write_text(json.dumps({"providers": {"openai-codex": {"tokens": {"access_token": token, "refresh_token": "not-returned"}}}}))
                return token
            first = save(time.time() + 300)
            self.assertEqual(bridge.borrowed_codex_token(home)[0], first)
            second = save(time.time() + 600)
            self.assertEqual(bridge.borrowed_codex_token(home)[0], second)
            self.assertNotEqual(first, second)

    def test_expired_access_does_not_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            original = json.dumps({"providers": {"openai-codex": {"tokens": {"access_token": fake_token(1), "refresh_token": "never-use"}}}})
            (home / "auth.json").write_text(original)
            with self.assertRaisesRegex(RuntimeError, "needs renewal"):
                bridge.borrowed_codex_token(home)
            self.assertEqual((home / "auth.json").read_text(), original)

    def test_private_file_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config"
            bridge.private_write(path, "fake")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_home_overlap_refused_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "own Hermes data directory"):
                bridge.prepare(home / "source", home, home / "nested")
            self.assertFalse((home / "nested").exists())

    @unittest.skipUnless(Path("/usr/bin/sandbox-exec").exists(), "macOS sandbox helper")
    def test_os_denies_writes_to_protected_home(self):
        with tempfile.TemporaryDirectory() as directory:
            protected = Path(directory).resolve()
            target = protected / "must-not-exist"
            profile = f"(version 1)(allow default)(deny file-write* (subpath {json.dumps(str(protected))}))"
            result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/touch", str(target)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
