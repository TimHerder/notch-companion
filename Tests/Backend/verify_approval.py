#!/usr/bin/env python3
"""One real approval round-trip, denied against an owned empty fixture directory."""
import json
from pathlib import Path
import tempfile

from verify_bridge import Backend, source_snapshot, gateway_identity


def main():
    baseline, gateway = source_snapshot(), gateway_identity()
    results = {}
    backend = None
    try:
        with tempfile.TemporaryDirectory(prefix="notch-approval-check-") as directory:
            root = Path(directory)
            harmless = root / "empty-fixture"
            harmless.mkdir()
            backend = Backend(root / "hermes")
            session = backend.request("session.create", title="Approval check", cwd=str(root))
            sid = session["session_id"]
            # Original Hermes has approvals disabled. This setting changes only
            # the temporary test runtime, never the owner's preference.
            backend.request("config.set", session_id=sid, key="approval_mode", value="manual")
            marker = len(backend.events)
            backend.request("prompt.submit", session_id=sid, surface="hud", text=f"Use terminal to run exactly: rm -rf '{harmless}' . It is an empty temporary fixture I created for an approval test. If the user denies approval, do not retry, and reply 'Denied as requested'.")
            event = backend.wait_event("approval.request", sid, after=marker).get("payload", {})
            response = backend.request("approval.respond", session_id=sid, request_id=event["request_id"], choice="deny")
            final = backend.wait_event("message.complete", sid, after=marker).get("payload", {})
            results["approval_event"] = "deny" in event.get("choices", [])
            results["approval_denied"] = bool(response.get("resolved"))
            results["denied_fixture_preserved"] = harmless.is_dir()
            results["turn_completed_after_denial"] = final.get("status") == "complete"
            backend.close()
            backend = None
    finally:
        if backend:
            backend.close()
        results["existing_hermes_files_unchanged"] = baseline == source_snapshot()
        results["existing_gateway_same_process"] = gateway == gateway_identity()
        print(json.dumps(results, indent=2))
    assert all(results.values())


if __name__ == "__main__":
    main()
