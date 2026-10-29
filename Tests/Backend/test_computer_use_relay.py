"""Offline tests of the in-process compatibility seam, no native UI/services."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('relay', ROOT / 'Sources/NotchCompanion/Resources/hermes_computer_use.py')
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


def native_fixture():
    class Daemon:
        def __init__(self, driver_cmd, permission_mode, capability_manifest=None):
            self.driver_cmd = driver_cmd
            self.permission_mode = permission_mode
            self.capability_manifest = capability_manifest
            self.socket_path = '/tmp/native.sock'

    calls = []
    def spawn(driver_cmd, serve_args, *, platform, app_path=None):
        calls.append((driver_cmd, serve_args, platform, app_path))
        if platform != 'darwin':
            return [driver_cmd, *serve_args]
        return ['/usr/bin/open', '-n', '-g', '-a', app_path, '--args', *serve_args]
    return types.SimpleNamespace(_EmbeddedCuaDaemon=Daemon, _embedded_daemon_spawn_command=spawn, calls=calls)


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='notch-relay-test-')
        self.directory = Path(self.tmp.name).resolve()
        self.module = native_fixture()
        self.messages = []

    def tearDown(self):
        self.tmp.cleanup()

    def install(self):
        with patch.object(relay.sys, 'platform', 'darwin'):
            relay.install_launch_relay(self.directory, module=self.module, emit=self.messages.append)

    def test_only_launch_hop_changes_and_native_mode_manifest_are_preserved(self):
        self.install()
        daemon = self.module._EmbeddedCuaDaemon('/driver', 'bounded', '/approved-manifest')
        self.assertEqual(daemon.permission_mode, 'bounded')
        self.assertEqual(daemon.capability_manifest, '/approved-manifest')
        self.assertEqual(Path(daemon.socket_path).parent, self.directory)
        self.assertRegex(Path(daemon.socket_path).name, r'^hc-[a-f0-9]{12}\.sock$')
        args = ['serve', '--embedded', '--socket', daemon.socket_path, '--no-permissions-gate', '--permission-mode',
                'bounded', '--capability-manifest', daemon.capability_manifest, '--approve-capability-manifest', '--no-overlay']
        with patch.object(relay.time, 'time', return_value=100):
            result = self.module._embedded_daemon_spawn_command('/driver', args, platform='darwin', app_path='/real/CuaDriver.app')
        self.assertEqual(result, ['/usr/bin/true'])
        self.assertEqual(self.module.calls[0][1], args)
        self.assertEqual(self.messages, [{'app':'/real/CuaDriver.app','arguments':args,'expires_at':112}])

    def test_signature_validation_failure_never_requests_launch(self):
        def refusal(driver_cmd, serve_args, *, platform, app_path=None):
            raise RuntimeError('Native signature rejection')
        self.module._embedded_daemon_spawn_command = refusal
        self.install()
        with self.assertRaisesRegex(RuntimeError, 'signature rejection'):
            self.module._embedded_daemon_spawn_command('/driver', ['serve'], platform='darwin')
        self.assertEqual(self.messages, [])

    def test_changed_native_contract_fails_closed_without_patching(self):
        original = lambda *args: []
        self.module._embedded_daemon_spawn_command = original
        with self.assertRaisesRegex(RuntimeError, 'launcher changed'):
            self.install()
        self.assertIs(self.module._embedded_daemon_spawn_command, original)

    def test_optional_missing_dependency_does_not_block_chat_startup(self):
        with patch.object(relay.sys, 'platform', 'darwin'), \
                patch.object(relay.importlib, 'import_module', side_effect=ModuleNotFoundError('optional CUA absent')):
            self.assertIsNone(relay.install_optional_launch_relay(self.directory))
        self.assertEqual(self.messages, [])

    def test_optional_changed_contract_blocks_tool_use_including_existing_class_alias(self):
        daemon_alias = self.module._EmbeddedCuaDaemon
        self.module._embedded_daemon_spawn_command = lambda *args: self.fail('unreviewed launch ran')
        with patch.object(relay.sys, 'platform', 'darwin'):
            self.assertIsNone(relay.install_optional_launch_relay(
                self.directory, module=self.module, emit=self.messages.append))
        with self.assertRaisesRegex(relay.ComputerUseUnavailable, 'Computer use is unavailable'):
            daemon_alias('/driver', 'unrestricted')
        with self.assertRaises(relay.ComputerUseUnavailable):
            self.module._embedded_daemon_spawn_command('/driver', [], platform='darwin')
        self.assertEqual(self.messages, [])
        self.assertEqual(self.module.calls, [])

    def test_optional_missing_helpers_fail_only_when_computer_use_is_requested(self):
        module = types.SimpleNamespace()
        with patch.object(relay.sys, 'platform', 'darwin'):
            self.assertIsNone(relay.install_optional_launch_relay(self.directory, module=module))
        with self.assertRaises(relay.ComputerUseUnavailable):
            module._EmbeddedCuaDaemon('/driver', 'bounded')

    def test_optional_compatible_contract_still_installs_cleanup(self):
        with patch.object(relay.sys, 'platform', 'darwin'):
            cleanup = relay.install_optional_launch_relay(
                self.directory, module=self.module, emit=self.messages.append)
        self.assertTrue(callable(cleanup))
        cleanup()
        with self.assertRaisesRegex(relay.ComputerUseRelayError, 'closing'):
            self.module._EmbeddedCuaDaemon('/driver', 'unrestricted')

    def test_optional_does_not_swallow_invalid_lease(self):
        self.directory.chmod(0o755)
        with patch.object(relay.sys, 'platform', 'darwin'), \
                self.assertRaisesRegex(relay.ComputerUseRelayError, 'not private'):
            relay.install_optional_launch_relay(self.directory, module=self.module)

    def test_unknown_command_does_not_reach_native_parent(self):
        def unexpected(driver_cmd, serve_args, *, platform, app_path=None):
            return ['/bin/sh', '-c', 'do something']
        self.module._embedded_daemon_spawn_command = unexpected
        self.install()
        with self.assertRaisesRegex(RuntimeError, 'unsupported'):
            self.module._embedded_daemon_spawn_command('/driver', ['serve'], platform='darwin')
        self.assertEqual(self.messages, [])

    def test_unprivate_or_symlink_directory_rejected(self):
        self.directory.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, 'not private'):
            self.install()
        self.directory.chmod(0o700)
        link = self.directory / 'link'
        link.symlink_to(self.directory, target_is_directory=True)
        with patch.object(relay.sys, 'platform', 'darwin'), self.assertRaisesRegex(RuntimeError, 'not private'):
            relay.install_launch_relay(link, module=self.module)

    def test_cleanup_blocks_any_later_launch(self):
        self.install()
        self.module._notch_launch_cleanup()
        with self.assertRaisesRegex(RuntimeError, "closing"):
            self.module._EmbeddedCuaDaemon('/driver', 'unrestricted')
        self.assertEqual(self.messages, [])

    def test_repeat_install_keeps_one_hook_and_native_nonmac_path(self):
        self.install()
        before = self.module._embedded_daemon_spawn_command
        self.install()
        self.assertIs(self.module._embedded_daemon_spawn_command, before)
        self.assertEqual(before('/driver', ['serve'], platform='linux'), ['/driver','serve'])
        self.assertEqual(self.messages, [])


if __name__ == '__main__':
    unittest.main()
