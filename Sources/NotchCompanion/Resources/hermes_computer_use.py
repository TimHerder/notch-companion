"""Companion-owned launch compatibility for Hermes's private macOS CUA daemon.

Only the LaunchServices hop moves to the native parent. Hermes still resolves
and validates its driver, chooses the immutable permission mode and manifest,
probes readiness, uses its private socket, and tears its backend down normally.
Installed Hermes files and the machine-wide CUA daemon are never modified.
"""
from __future__ import annotations

import atexit
import functools
import importlib
import inspect
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import threading
import time
import uuid


class ComputerUseRelayError(RuntimeError):
    pass


class ComputerUseUnavailable(ComputerUseRelayError):
    pass


def install_optional_launch_relay(directory, *, module=None, emit=None):
    """Chat does not require Hermes's optional, version-specific CUA helpers.

    An absent dependency will produce its normal native tool-import failure.
    An unrecognized helper is explicitly blocked when used, never delegated to
    the native parent without the reviewed launch/permission contract. All
    ordinary child processes retain the frontend's filesystem protection.
    """
    if sys.platform != "darwin":
        return
    if module is None:
        try:
            module = importlib.import_module("tools.computer_use.cua_backend_daemon")
        except ImportError:
            return
    try:
        return install_launch_relay(directory, module=module, emit=emit)
    except ComputerUseUnavailable:
        def unavailable(*args, **kwargs):
            raise ComputerUseUnavailable(
                "Computer use is unavailable with this Hermes installation. "
                "Update Notch Companion before using computer use."
            )

        daemon = getattr(module, "_EmbeddedCuaDaemon", None)
        if isinstance(daemon, type):
            # Patch the class itself so imports holding an existing class alias
            # also fail before native initialization or launch can happen.
            daemon.__init__ = unavailable
        else:
            module._EmbeddedCuaDaemon = unavailable
        module._embedded_daemon_spawn_command = unavailable
        return


def install_launch_relay(directory, *, module=None, emit=None):
    if sys.platform != "darwin":
        return
    directory = Path(directory)
    info = directory.lstat()
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid() or info.st_mode & 0o077
            or directory != directory.resolve()):
        raise ComputerUseRelayError("The companion computer-use launch directory is not private.")
    if module is None:
        from tools.computer_use import cua_backend_daemon as module
    if getattr(module, "_notch_launch_relay_installed", False):
        return module._notch_launch_cleanup
    daemon = getattr(module, "_EmbeddedCuaDaemon", None)
    native_init = getattr(daemon, "__init__", None)
    native_spawn = getattr(module, "_embedded_daemon_spawn_command", None)
    # A changed private helper must be reviewed, not silently adapted into a
    # different security/permission contract.
    try:
        compatible = (isinstance(daemon, type)
            and list(inspect.signature(native_spawn).parameters) == ["driver_cmd", "serve_args", "platform", "app_path"]
            and list(inspect.signature(native_init).parameters) == ["self", "driver_cmd", "permission_mode", "capability_manifest"])
    except (TypeError, ValueError):
        compatible = False
    if not compatible:
        raise ComputerUseUnavailable("This Hermes computer-use launcher changed. Update Notch Companion before using it.")
    lock = threading.RLock()
    owned = set()
    issued = {}
    closing = threading.Event()

    def lease_is_original():
        try:
            current = directory.lstat()
            return (stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode)
                    and current.st_uid == info.st_uid and current.st_mode & 0o077 == 0
                    and (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino))
        except OSError:
            return False

    def cleanup():
        # The parent-EOF watcher calls this explicitly BEFORE SIGTERM: Hermes
        # re-raises that signal, which does not run Python atexit handlers.
        with lock:
            if closing.is_set():
                return
            closing.set()
            daemons = list(owned)
            launches = dict(issued)
        for daemon in daemons:
            if not lease_is_original():
                break
            try:
                daemon.stop()
            except Exception:
                pass
        # A request already accepted by LaunchServices may bind after native
        # stop. Watch only this lease's issued endpoints until their startup
        # deadlines, covering that race without touching any existing daemon.
        deadline = max((expiry + 3 for _, expiry in launches.values()), default=0)
        while True:
            for socket, (executable, _) in launches.items():
                try:
                    socket_info = Path(socket).lstat()
                    owned_socket = stat.S_ISSOCK(socket_info.st_mode) and socket_info.st_uid == info.st_uid
                except OSError:
                    owned_socket = False
                if lease_is_original() and owned_socket:
                    try:
                        subprocess.run([executable, "stop", "--socket", socket],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env={"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}, timeout=3)
                    except (OSError, subprocess.SubprocessError):
                        pass
            if time.time() >= deadline:
                break
            time.sleep(0.1)
        if lease_is_original():
            try:
                directory.rmdir()  # only empty; never delete evidence of a live socket
            except OSError:
                pass

    atexit.register(cleanup)

    def emit_to_parent(payload):
        with lock:
            sys.__stdout__.write("NOTCH_CUA_LAUNCH " + json.dumps(payload, separators=(",", ":")) + "\n")
            sys.__stdout__.flush()

    send = emit or emit_to_parent

    @functools.wraps(native_init)
    def initialize(self, driver_cmd, permission_mode, capability_manifest=None):
        if closing.is_set():
            raise ComputerUseRelayError("The companion computer-use frontend is closing.")
        native_init(self, driver_cmd, permission_mode, capability_manifest)
        # A lease isolates sockets from every other frontend/session and lets
        # the native parent clean up only daemons it launched, even after a crash.
        self.socket_path = str(directory / ("hc-" + uuid.uuid4().hex[:12] + ".sock"))
        with lock:
            owned.add(self)

    @functools.wraps(native_spawn)
    def spawn(driver_cmd, serve_args, *, platform, app_path=None):
        command = native_spawn(driver_cmd, serve_args, platform=platform, app_path=app_path)
        if platform != "darwin":
            return command
        if (command[:4] != ["/usr/bin/open", "-n", "-g", "-a"] or len(command) < 7
                or command[5] != "--args" or command[6:] != list(serve_args)):
            raise ComputerUseRelayError("Hermes returned an unsupported computer-use launch command.")
        # The parent independently checks the signature, command allowlist,
        # lease, mode acknowledgement, manifest and deadline. No shell or
        # arbitrary-executable escape exists in this control message.
        with lock:
            if closing.is_set():
                raise ComputerUseRelayError("The companion computer-use frontend is closing.")
            expiry = time.time() + 12
            socket = str(serve_args[3])
            if Path(socket).parent != directory:
                raise ComputerUseRelayError("The computer-use socket is outside its companion lease.")
            issued[socket] = (str(Path(command[4]) / "Contents/MacOS/cua-driver"), expiry)
            send({"app": command[4], "arguments": list(serve_args), "expires_at": expiry})
        # Native start() already treats a successful `open` exit as a launch
        # acknowledgement and polls readiness; all that logic stays unchanged.
        return ["/usr/bin/true"]

    module._EmbeddedCuaDaemon.__init__ = initialize
    module._embedded_daemon_spawn_command = spawn
    module._notch_launch_relay_installed = True
    module._notch_launch_cleanup = cleanup
    return cleanup
