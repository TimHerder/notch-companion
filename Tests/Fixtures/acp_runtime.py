#!/usr/bin/python3
"""Offline ACP v1 peer. It reads/writes only the test's temporary profile."""
import json
import os
import sys

path = os.path.join(os.environ["OPENCODE_CONFIG_DIR"], "fixture-native.json")
model = "provider/native-default"
history = []
prompt_id = None
mode = None


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def reply(wire_id, result):
    send(dict(id=wire_id, result=result))


def options():
    return [dict(id="model", category="model", type="select", currentValue=model,
                 options=[dict(value="provider/native-default", name="Default"),
                          dict(value="provider/other", name="Other")])]


def update(kind, **fields):
    send(dict(method="session/update", params=dict(sessionId="native-fixture",
              update=dict(sessionUpdate=kind, **fields))))


def finish(text, reason="end_turn"):
    global prompt_id
    if text:
        history.append(dict(role="assistant", text=text, id="message-" + str(len(history))))
        update("agent_message_chunk", content=dict(type="text", text=text))
    with open(path, "w") as handle:
        json.dump(dict(history=history, model=model), handle)
    reply(prompt_id, dict(stopReason=reason))
    prompt_id = None


for line in sys.stdin:
    frame = json.loads(line)
    method, params, wire_id = frame.get("method"), frame.get("params", {}), frame.get("id")
    if method == "initialize":
        assert params["protocolVersion"] == 1
        assert params["clientCapabilities"]["terminal"] is False
        reply(wire_id, dict(protocolVersion=1, agentInfo=dict(name="offline-fixture"),
              agentCapabilities=dict(loadSession=True, promptCapabilities=dict(image=True))))
    elif method == "session/new":
        assert params["mcpServers"] == []
        reply(wire_id, dict(sessionId="native-fixture", configOptions=options()))
    elif method == "session/load":
        assert params["sessionId"] == "native-fixture"
        with open(path) as handle:
            stored = json.load(handle)
        history, model = stored["history"], stored["model"]
        for row in history:
            update("user_message_chunk" if row["role"] == "user" else "agent_message_chunk",
                   messageId=row["id"], content=dict(type="text", text=row["text"]))
        reply(wire_id, dict(configOptions=options()))
    elif method == "session/set_config_option":
        assert params["configId"] == "model"
        model = params["value"]
        reply(wire_id, dict(configOptions=options()))
    elif method == "session/prompt":
        assert prompt_id is None
        prompt_id = wire_id
        text = params["prompt"][0]["text"]
        mode = text
        history.append(dict(role="user", text=text, id="message-" + str(len(history))))
        update("tool_call", toolCallId="tool-1", title="Read fixture", status="in_progress")
        if text == "permission":
            send(dict(id="permission-1", method="session/request_permission",
                 params=dict(sessionId="native-fixture", toolCall=dict(title="Edit fixture"),
                 options=[dict(optionId="allow-once", kind="allow_once"),
                          dict(optionId="reject-once", kind="reject_once")])))
        elif text == "question":
            send(dict(id="question-1", method="elicitation/create", params=dict(
                 sessionId="native-fixture", mode="form", message="Choose a color",
                 requestedSchema=dict(type="object", properties=dict(color=dict(type="string", enum=["Sage", "Pearl"])), required=["color"]))))
        elif text != "wait":
            update("tool_call_update", toolCallId="tool-1", status="completed", rawOutput="fixture read")
            update("usage_update", used=200, size=8000)
            finish("reply:" + model)
    elif method == "session/cancel":
        if prompt_id is not None:
            finish("", "cancelled")
    elif method is None and wire_id == "permission-1":
        assert frame["result"]["outcome"]["optionId"] == "reject-once"
        update("tool_call_update", toolCallId="tool-1", status="failed", rawOutput="denied")
        finish("denied")
    elif method is None and wire_id == "question-1":
        assert frame["result"]["action"] == "accept"
        finish(frame["result"]["content"]["color"])
    else:
        send(dict(id=wire_id, error=dict(code=-32601, message="Unsupported fixture method")))
