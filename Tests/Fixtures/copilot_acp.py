#!/usr/bin/python3
"""Offline GitHub Copilot CLI `copilot --acp --stdio` peer. `initialize` matches
copilot 1.0.112; modes are named by URL and models are a `model` config option."""
import json
import os
import sys

assert sys.argv[1:] == ["--acp", "--stdio"]
log = os.path.join(os.path.dirname(sys.argv[0]), "wire.jsonl")
MODES = "https://agentclientprotocol.com/protocol/session-modes#"
prompt_id = None
model = "auto"


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def reply(wire_id, result):
    send(dict(id=wire_id, result=result))


def update(update_kind, **fields):
    send(dict(method="session/update", params=dict(sessionId="copilot-session",
              update=dict(sessionUpdate=update_kind, **fields))))


def config():
    return [dict(id="mode", name="Mode", category="mode", type="select", currentValue=MODES + "agent",
                 options=[dict(value=MODES + m, name=m.title()) for m in ("agent", "plan", "autopilot")]),
            dict(id="allow_all", name="Allow all", type="select", currentValue="off",
                 options=[dict(value="off", name="Off"), dict(value="on", name="On")]),
            dict(id="model", name="Model", category="model", type="select", currentValue=model,
                 options=[dict(value="auto", name="Auto"), dict(value="gpt-5.4", name="GPT-5.4")])]


def opened():
    return dict(sessionId="copilot-session", configOptions=config(), modes=dict(currentModeId=MODES + "agent",
                availableModes=[dict(id=MODES + m, name=m.title()) for m in ("agent", "plan", "autopilot")]))


for line in sys.stdin:
    frame = json.loads(line)
    with open(log, "a") as f:
        f.write(json.dumps(frame) + "\n")
    method, params, wire_id = frame.get("method"), frame.get("params", {}), frame.get("id")
    if method == "initialize":
        reply(wire_id, dict(protocolVersion=1, agentCapabilities=dict(auth=dict(logout={}), loadSession=True,
              mcpCapabilities=dict(http=True, sse=True), promptCapabilities=dict(image=True, audio=False, embeddedContext=True),
              sessionCapabilities=dict(close={}, list={})), agentInfo=dict(name="Copilot", title="Copilot", version="1.0.112"),
              authMethods=[dict(id="copilot-login", name="Log in with Copilot CLI", description="Run `copilot login` in the terminal",
                                _meta={"terminal-auth": dict(command=sys.argv[0], args=["login"], label="Copilot Login")})]))
    elif method == "session/new" and os.path.exists(os.path.join(params["cwd"], ".signed-out")):
        send(dict(id=wire_id, error=dict(code=-32000, message="Authentication required")))
    elif method == "session/new":
        reply(wire_id, opened())
    elif method == "session/load":
        update("user_message_chunk", content=dict(type="text", text="earlier"))
        update("agent_message_chunk", content=dict(type="text", text="answer"))
        reply(wire_id, opened())
    elif method == "session/set_mode":
        assert params["modeId"].startswith(MODES), "A bare mode name is rejected"
        reply(wire_id, {})
    elif method == "session/set_config_option":
        assert params["configId"] == "model"
        model = params["value"]
        reply(wire_id, dict(configOptions=config()))
    elif method == "session/prompt":
        prompt_id = wire_id
        update("tool_call", toolCallId="call-1", title="Write notes.txt", kind="edit", status="pending")
        send(dict(id="perm-1", method="session/request_permission", params=dict(sessionId="copilot-session",
             toolCall=dict(toolCallId="call-1", title="Write notes.txt"),
             options=[dict(optionId="allow_once", name="Allow", kind="allow_once"),
                      dict(optionId="reject_once", name="Reject", kind="reject_once")])))
    elif method is None and wire_id == "perm-1":
        outcome = frame["result"]["outcome"]
        update("agent_message_chunk", content=dict(type="text", text=f"{outcome.get('optionId', outcome['outcome'])}:{model}"))
        reply(prompt_id, dict(stopReason="end_turn"))
    elif wire_id is not None and method is not None:
        send(dict(id=wire_id, error=dict(code=-32601, message="Unsupported fixture method")))
