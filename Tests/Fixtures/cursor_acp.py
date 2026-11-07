#!/usr/bin/python3
"""Offline Cursor CLI `agent acp` peer using its documented extension shapes."""
import json
import sys

assert sys.argv[1:] == ["acp"]
authenticated = False
prompt_id = None


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def reply(wire_id, result):
    send(dict(id=wire_id, result=result))


def update(kind, **fields):
    send(dict(method="session/update", params=dict(sessionId="cursor-chat",
              update=dict(sessionUpdate=kind, **fields))))


def finish(text):
    global prompt_id
    update("agent_message_chunk", content=dict(type="text", text=text))
    reply(prompt_id, dict(stopReason="end_turn"))
    prompt_id = None


for line in sys.stdin:
    frame = json.loads(line)
    method, params, wire_id = frame.get("method"), frame.get("params", {}), frame.get("id")
    if method == "initialize":
        reply(wire_id, dict(protocolVersion=1, authMethods=[dict(id="cursor_login", name="Cursor login")],
              agentCapabilities=dict(loadSession=True)))
    elif method == "authenticate":
        assert params == dict(methodId="cursor_login")
        authenticated = True
        reply(wire_id, {})
    elif method == "session/new":
        assert authenticated
        reply(wire_id, dict(sessionId="cursor-chat", modes=dict(currentModeId="agent", availableModes=[
              dict(id="agent", name="Agent"), dict(id="plan", name="Plan"), dict(id="ask", name="Ask")])))
    elif method == "session/set_mode":
        assert params["modeId"] in ("agent", "plan", "ask")
        reply(wire_id, {})
    elif method == "session/prompt":
        prompt_id = wire_id
        text = params["prompt"][0]["text"]
        update("tool_call", toolCallId="call-1", title=text, status="in_progress")
        # Documented without a sessionId; the client attributes them by tool call.
        if text == "question":
            send(dict(id="ask-1", method="cursor/ask_question", params=dict(toolCallId="call-1", title="Need input",
                 questions=[dict(id="q1", prompt="Which colors?", allowMultiple=True, options=[
                     dict(id="sage", label="Sage"), dict(id="pearl", label="Pearl"), dict(id="ink", label="Ink")])])))
        else:
            send(dict(id="plan-1", method="cursor/create_plan", params=dict(toolCallId="call-1", name="Fixture plan",
                 plan="1. Read\n2. Edit", todos=[])))
    elif method is None and wire_id == "ask-1":
        outcome = frame["result"]["outcome"]
        assert outcome["outcome"] == "answered" and outcome["answers"][0]["questionId"] == "q1"
        finish(",".join(outcome["answers"][0]["selectedOptionIds"]))
    elif method is None and wire_id == "plan-1":
        finish(frame["result"]["outcome"]["outcome"])
    elif wire_id is not None and method is not None:
        send(dict(id=wire_id, error=dict(code=-32601, message="Unsupported fixture method")))
