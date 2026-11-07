#!/usr/bin/python3
"""Offline `agy` peer shaped like the installed 1.5.2: `agy acp` plus the `models` and `/model`
discovery commands. Conversations are listed only once prompted, and load/resume accept any ID."""
import json
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(sys.argv[0]))
STORE = os.path.join(HERE, "conversations.json")
WIRE = os.path.join(HERE, "wire.jsonl")
MODELS = [dict(modelId="gemini-3.8-flash-high", name="Gemini 3.8 Flash (High)"),
          dict(modelId="gemini-3.8-flash-low", name="Gemini 3.8 Flash (Low)"),
          dict(modelId="claude-sonnet-4-6", name="Claude Sonnet 4.6 (Thinking)")]

if "acp" not in sys.argv:
    if "models" in sys.argv:
        data = dict(models=[dict(id=row["modelId"], label=row["name"]) for row in MODELS])
        print(json.dumps(dict(conversation_id="", status="SUCCESS", command=dict(name="models", data=data))))
    else:
        assert sys.argv[1:] == ["--print", "/model", "--output-format", "json"], sys.argv
        print(json.dumps(dict(conversation_id="", status="SUCCESS", command=dict(name="model", data=dict(id=MODELS[0]["modelId"])))))
    sys.exit(0)
assert sys.argv[1:] == ["acp"], sys.argv

listed = json.load(open(STORE)) if os.path.exists(STORE) else ["external-conversation"]
current = {}
prompt_id = None
prompt_sid = None
asking = None
deaf = work = False


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def reply(wire_id, result):
    send(dict(id=wire_id, result=result))


def update(sid, kind, **fields):
    send(dict(method="session/update", params=dict(sessionId=sid, update=dict(sessionUpdate=kind, **fields))))


def opened(sid):
    current.setdefault(sid, MODELS[0]["modelId"])
    return dict(sessionId=sid, models=dict(availableModels=MODELS, currentModelId=current[sid]),
                modes=dict(currentModeId="default", availableModes=[dict(id="default", name="Default"),
                           dict(id="accept-edits", name="Accept edits"), dict(id="plan", name="Plan")]),
                configOptions=[dict(id="model", name="Model", category="model", type="select", currentValue="gemini-3.8-flash",
                                    options=[dict(value="gemini-3.8-flash", name="Gemini 3.8 Flash"),
                                             dict(value="claude-sonnet-4-6", name="Claude Sonnet 4.6 (Thinking)")])])


def finish(text, reason="end_turn"):
    global prompt_id
    if text:
        update(prompt_sid, "agent_message_chunk", content=dict(type="text", text=text))
    reply(prompt_id, dict(stopReason=reason))
    prompt_id = None


for line in sys.stdin:
    frame = json.loads(line)
    method, params, wire_id = frame.get("method"), frame.get("params", {}), frame.get("id")
    with open(WIRE, "a") as log:
        log.write(json.dumps(frame) + "\n")
    assert method not in ("authenticate", "session/load", "session/set_config_option"), method
    if method == "initialize":
        # Without form support agy asks its questions as `interaction_` permission requests.
        assert params["clientCapabilities"]["elicitation"] == {}, params
        reply(wire_id, dict(protocolVersion=1, agentInfo=dict(name="Antigravity ACP Server", version="1.5.2"),
              authMethods=[dict(id="oauth-personal", name="Log in with Google")],
              agentCapabilities=dict(loadSession=True, sessionCapabilities=dict(resume={}, list={}, load={}, close={}),
                                     _meta=dict(antigravity=dict(systemPrompt=dict(append=True))))))
    elif method == "session/new":
        reply(wire_id, opened(str(uuid.uuid4())))
    elif method == "session/resume":
        reply(wire_id, opened(params["sessionId"]))
    elif method == "session/list":
        # One per page, so the client has to follow the cursor.
        index = int(params.get("cursor") or 0)
        page = dict(sessions=[dict(sessionId=sid, cwd=HERE) for sid in listed[index:index + 1]])
        if index + 1 < len(listed):
            page["nextCursor"] = str(index + 1)
        reply(wire_id, page)
    elif method == "session/set_model":
        assert params["modelId"] in [row["modelId"] for row in MODELS]
        current[params["sessionId"]] = params["modelId"]
        reply(wire_id, {})
    elif method == "session/prompt":
        prompt_id, prompt_sid = wire_id, params["sessionId"]
        if prompt_sid not in listed:
            listed.append(prompt_sid)
            json.dump(listed, open(STORE, "w"))
        text = params["prompt"][0]["text"]
        # "stuck" never answers session/cancel; "ask then work" keeps working after its answer.
        deaf, work = text == "stuck", text == "ask then work"
        if text in ("question", "ask then work"):
            update(prompt_sid, "tool_call", toolCallId="interaction_1", title="Running ask_question", status="in_progress")
            asking = "ask-1"
            send(dict(id="ask-1", method="session/request_permission", params=dict(sessionId=prompt_sid,
                 toolCall=dict(toolCallId="interaction_1", title="Which color?"),
                 options=[dict(optionId="opt-sage", name="Sage", kind="allow_once"),
                          dict(optionId="opt-ink", name="Ink", kind="allow_once")])))
        elif text == "permission":
            update(prompt_sid, "tool_call", toolCallId="call-2", title="Running run_command", status="pending")
            asking = "perm-1"
            send(dict(id="perm-1", method="session/request_permission", params=dict(sessionId=prompt_sid,
                 toolCall=dict(toolCallId="call-2", title="Run run_command?", rawInput=dict(CommandLine="rm fixture")),
                 options=[dict(optionId="allow", name="Allow", kind="allow_once"),
                          dict(optionId="always", name="Always", kind="allow_always"),
                          dict(optionId="reject", name="Deny", kind="reject_once")])))
        elif text == "slow":
            update(prompt_sid, "agent_message_chunk", content=dict(type="text", text="Working"))
        elif text in ("silent", "stuck"):
            pass
        else:
            update(prompt_sid, "tool_call", toolCallId="call-1", title="Running delegate_task", status="completed",
                   rawInput=dict(task="fixture"), _meta=dict(is_mcp_tool_call=True))
            finish("reply:" + current[prompt_sid])
    elif method == "session/cancel":
        # A turn waiting on the client ends only once that request is answered, as ACP requires of the client.
        if prompt_id is not None and asking is None and not deaf:
            finish("", "cancelled")
    elif method is None and wire_id in ("ask-1", "perm-1"):
        asking = None
        outcome = frame["result"]["outcome"]
        if work:
            update(prompt_sid, "agent_message_chunk", content=dict(type="text", text="Working. "))
            time.sleep(0.7)
        finish(outcome.get("optionId", outcome["outcome"]), "cancelled" if outcome["outcome"] == "cancelled" else "end_turn")
    elif wire_id is not None and method is not None:
        send(dict(id=wire_id, error=dict(code=-32601, message="Unsupported fixture method")))
