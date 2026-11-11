import XCTest
@testable import NotchCompanion

final class ClaudeProtocolTests: XCTestCase {
    let id = "7a25b06b-7560-4a06-a28c-07ef651fd840"

    func testSteeringCapabilityRequiresTheNativeVersion() throws {
        var state = ClaudeProtocolState(sessionID: id)
        for (version, supported) in [("", false), ("2.1.285", false), ("2.1.286", true), ("2.1.287", true), ("2.bad.1.286", false), ("unknown", false)] {
            let events = try state.receive(["type": "system", "subtype": "init", "claude_code_version": version])
            XCTAssertEqual(state.supportsSteering, supported)
            XCTAssertEqual((events.first?.payload["capabilities"] as? [String: Bool])?["steering"], supported)
        }
    }

    func testPendingSteeringCannotSettleOnTheOriginalResult() throws {
        var state = ClaudeProtocolState(sessionID: id)
        try state.begin("original")
        state.pendingSteering.insert("steer")
        _ = try state.receive(["type": "command_lifecycle", "command_uuid": "other", "state": "started"])
        XCTAssertEqual(state.pendingSteering, ["steer"])
        XCTAssertTrue(try state.receive(["type": "result", "result": "Original response"]).isEmpty)
        XCTAssertTrue(state.active)
        _ = try state.receive(["type": "command_lifecycle", "command_uuid": "steer", "state": "started"])
        XCTAssertNil(state.result)
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.turnID, "original")
        let events = try state.receive(["type": "result", "result": "Steered response"])
        XCTAssertEqual(events.last?.payload["text"] as? String, "Steered response")
        XCTAssertFalse(state.active)
    }

    func testApprovalsPreserveInputAndAreScopedToSession() throws {
        var state = ClaudeProtocolState(sessionID: id)
        try state.begin("turn")
        let input: [String: Any] = ["command": "git status", "description": "Inspect working tree"]
        let request = state.interaction(["request_id": "approval", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": input]])
        XCTAssertNil(request.reply)
        XCTAssertEqual(request.events.first?.name, "approval.request")
        XCTAssertEqual(request.events.first?.payload["choices"] as? [String], ["once", "deny"])
        XCTAssertEqual(request.events.first?.payload["plan"] as? Bool, false)
        let plan = state.interaction(["request_id": "plan", "request": ["subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "1. Build"]]])
        XCTAssertEqual(plan.events.first?.payload["plan"] as? Bool, true, "Answering it settles the turn's Plan ready banner")
        XCTAssertThrowsError(try state.answer(["session_id": "other", "request_id": "approval", "choice": "once"], approval: true))
        XCTAssertThrowsError(try state.answer(["session_id": id, "request_id": "approval", "choice": "session"], approval: true))
        let reply = try XCTUnwrap(state.answer(["session_id": id, "request_id": "approval", "choice": "once"], approval: true))
        let body = (reply["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(body?["behavior"] as? String, "allow")
        XCTAssertEqual((body?["updatedInput"] as? [String: Any])?["command"] as? String, "git status")
        XCTAssertNil(body?["updatedPermissions"])
        XCTAssertThrowsError(try state.answer(["session_id": id, "request_id": "approval", "choice": "once"], approval: true))
    }

    func testComputerUseDialogGrantsListedAppsAndDenyGrantsNothing() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        let payload: [String: Any] = ["reason": "Check the build in Finder" + String(repeating: " and more", count: 2_000), "requestedFlags": ["clipboardRead": true],
            "apps": [["requestedName": "Finder", "resolved": ["bundleId": "com.apple.finder", "displayName": "Finder"], "alreadyGranted": false],
                     ["requestedName": "Finder", "resolved": ["bundleId": "com.apple.finder", "displayName": "Finder"], "alreadyGranted": false],
                     ["requestedName": "Safari", "resolved": ["bundleId": "com.apple.Safari", "displayName": "Safari"], "alreadyGranted": true],
                     ["requestedName": "Nonexistent"]]]
        func dialog(_ request: String) -> (events: [ClaudeProtocolState.Event], reply: [String: Any]?) {
            state.interaction(["request_id": request, "request": ["subtype": "request_user_dialog", "dialog_kind": "computer_use_approval", "payload": payload]])
        }
        let asked = dialog("cu")
        XCTAssertNil(asked.reply)
        XCTAssertEqual(asked.events.first?.name, "approval.request")
        XCTAssertEqual(asked.events.first?.payload["choices"] as? [String], ["session", "deny"], "The grant lasts the session, so no Allow once or glance approval")
        XCTAssertTrue(dialog("cu").events.isEmpty, "A repeated pending request is shown once")
        let command = try XCTUnwrap(asked.events.first?.payload["command"] as? String)
        for text in ["Computer use", "Check the build in Finder", "• Finder (com.apple.finder)", "Already allowed:\n• Safari", "Not installed:\n• Nonexistent", "• Read the clipboard"] {
            XCTAssertTrue(command.contains(text), text)
        }
        XCTAssertLessThan(command.count, 2_600, "A long reason is shortened, never the apps and extras Allow grants")
        XCTAssertThrowsError(try state.answer(["session_id": id, "request_id": "cu", "choice": "once"], approval: true))
        let reply = try XCTUnwrap(state.answer(["session_id": id, "request_id": "cu", "choice": "session"], approval: true))
        let body = try XCTUnwrap((reply["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(body["behavior"] as? String, "completed", "A dialog settles with its result, not a tool allow")
        let result = try XCTUnwrap(body["result"] as? [String: Any])
        XCTAssertEqual((result["granted"] as? [[String: Any]])?.map { $0["bundleId"] as? String }, ["com.apple.finder"])
        XCTAssertEqual((result["denied"] as? [[String: Any]])?.first?["reason"] as? String, "not_installed")
        XCTAssertEqual(result["flags"] as? [String: Bool], ["clipboardRead": true, "clipboardWrite": false, "systemKeyCombos": false])
        XCTAssertThrowsError(try state.answer(["session_id": id, "request_id": "cu", "choice": "session"], approval: true), "A settled grant cannot be answered again")
        _ = dialog("denied")
        let denied = try XCTUnwrap(state.answer(["session_id": id, "request_id": "denied", "choice": "deny"], approval: true))
        let deniedResult = ((denied["response"] as? [String: Any])?["response"] as? [String: Any])?["result"] as? [String: Any]
        XCTAssertEqual((deniedResult?["granted"] as? [Any])?.count, 0)
        XCTAssertEqual(deniedResult?["flags"] as? [String: Bool], ["clipboardRead": false, "clipboardWrite": false, "systemKeyCombos": false])
        let tcc = state.interaction(["request_id": "tcc", "request": ["subtype": "request_user_dialog", "dialog_kind": "computer_use_approval",
            "payload": ["apps": [], "tccState": ["accessibility": true, "screenRecording": false]]]])
        XCTAssertEqual(tcc.events.first?.name, "runtime.notice")
        XCTAssertTrue((tcc.events.first?.payload["message"] as? String ?? "").contains("Screen Recording for Notch Companion"))
        XCTAssertEqual(((tcc.reply?["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String, "completed")
        XCTAssertTrue(state.requests.isEmpty)
        _ = dialog("withdrawn")
        XCTAssertEqual(try state.receive(["type": "control_cancel_request", "request_id": "withdrawn"]).first?.name, "clarify.expire")
        XCTAssertThrowsError(try state.answer(["session_id": id, "request_id": "withdrawn", "choice": "session"], approval: true))
        let undeclared = state.interaction(["request_id": "other", "request": ["subtype": "request_user_dialog", "dialog_kind": "startup_model_switch", "payload": [:]]])
        XCTAssertTrue(undeclared.events.isEmpty && undeclared.reply == nil, "An undeclared kind stays unanswered, without a declined notice")
    }

    func testComputerUseDialogOutsideATurnGrantsNothing() throws {
        var state = ClaudeProtocolState(sessionID: id)
        let idle = state.interaction(["request_id": "idle", "request": ["subtype": "request_user_dialog", "dialog_kind": "computer_use_approval",
            "payload": ["apps": [["requestedName": "Finder", "resolved": ["bundleId": "com.apple.finder", "displayName": "Finder"]]]]]])
        XCTAssertTrue(idle.events.isEmpty)
        let body = (idle.reply?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(body?["behavior"] as? String, "completed")
        XCTAssertEqual(((body?["result"] as? [String: Any])?["granted"] as? [Any])?.count, 0)
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testQuestionsWaitForEveryAnswerAndPreserveNativeShape() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        let questions: [[String: Any]] = [["question": "Which color?", "options": [["label": "Blue", "description": "Quiet"]]], ["question": "Name?"]]
        let translated = state.interaction(["request_id": "question", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": questions]]])
        XCTAssertEqual(translated.events.first?.name, "clarify.request")
        XCTAssertNil(try state.answer(["session_id": id, "request_id": "question", "question_id": "0", "answer": "Blue"], approval: false))
        let reply = try XCTUnwrap(state.answer(["session_id": id, "request_id": "question", "question_id": "1", "answer": "Notch"], approval: false))
        let body = (reply["response"] as? [String: Any])?["response"] as? [String: Any]
        let updated = body?["updatedInput"] as? [String: Any]
        XCTAssertEqual(updated?["answers"] as? [String: String], ["Which color?": "Blue", "Name?": "Notch"])
        XCTAssertEqual((updated?["questions"] as? [[String: Any]])?.count, 2)
    }

    func testUnsupportedInteractionDeclinesVisiblyAndCancellationExpires() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        let unsupported = state.interaction(["request_id": "unsupported", "request": ["subtype": "mcp_message"]])
        XCTAssertEqual(unsupported.events.first?.name, "runtime.notice")
        XCTAssertEqual((unsupported.reply?["response"] as? [String: Any])?["subtype"] as? String, "error")
        _ = state.interaction(["request_id": "approval", "request": ["subtype": "can_use_tool", "tool_name": "Write", "input": [:]]])
        let expired = try state.receive(["type": "control_cancel_request", "request_id": "approval"])
        XCTAssertEqual(expired.first?.name, "clarify.expire")
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testResultWaitsForDelegatedTasksAndNativeIdle() throws {
        var state = ClaudeProtocolState(sessionID: id); state.nativeState = "idle"; try state.begin("turn")
        _ = try state.receive(["type": "system", "subtype": "task_started", "task_id": "child", "task_type": "local_agent"])
        XCTAssertTrue(try state.receive(["type": "result", "result": "Ready", "is_error": false]).isEmpty)
        XCTAssertThrowsError(try state.begin("duplicate"))
        let child = try state.receive(["type": "system", "subtype": "task_notification", "task_id": "child", "status": "completed"])
        XCTAssertEqual(child.map(\.name), ["subagent.complete"])
        XCTAssertTrue(state.active)
        let settled = try state.receive(["type": "system", "subtype": "session_state_changed", "state": "idle"])
        XCTAssertEqual(settled.map(\.name), ["message.complete"])
        XCTAssertFalse(state.active)
        XCTAssertTrue(try state.receive(["type": "result", "result": "Ready"]).isEmpty)
    }

    func testBackgroundShellHoldsTheTurnWithoutBecomingAnAgent() throws {
        var state = ClaudeProtocolState(sessionID: id); state.nativeState = "idle"; try state.begin("turn")
        let started = try state.receive(["type": "system", "subtype": "task_started", "task_id": "shell", "tool_use_id": "bash-call",
                                         "task_type": "local_bash", "description": "Create branch"])
        XCTAssertTrue(started.isEmpty, "A background command is not a Team agent")
        XCTAssertTrue(try state.receive(["type": "result", "result": "Ready", "is_error": false]).isEmpty, "It still holds the turn open")
        XCTAssertTrue(try state.receive(["type": "system", "subtype": "task_notification", "task_id": "shell", "status": "failed"]).isEmpty)
        let finished = try state.receive(["type": "system", "subtype": "session_state_changed", "state": "idle"])
        XCTAssertEqual(finished.map(\.name), ["message.complete"])
        XCTAssertEqual(finished.first?.payload["status"] as? String, "complete", "A command's exit status is not the turn's")
    }

    func testEveryAgentTaskKindStartsAndFinishesItsTeamRow() throws {
        // nil: a CLI that sends no task_type; the originating tool call decides.
        for (type, tool) in [("remote_agent", "Agent"), ("in_process_teammate", "Agent"), (nil, "Agent"), (nil, "Task"), (nil, "Bash")] as [(String?, String)] {
            var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
            _ = try state.receive(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "call", "name": tool, "input": [:]]]]])
            var frame: [String: Any] = ["type": "system", "subtype": "task_started", "task_id": "task", "tool_use_id": "call"]
            frame["task_type"] = type
            let agent = tool != "Bash"
            XCTAssertEqual(try state.receive(frame).map(\.name), agent ? ["subagent.start"] : [], "\(type ?? "no type") from \(tool)")
            let done = try state.receive(["type": "system", "subtype": "task_notification", "task_id": "task", "status": "completed"])
            XCTAssertEqual(done.map(\.name), agent ? ["subagent.complete"] : [], "\(type ?? "no type") from \(tool)")
        }
    }

    func testPartialTextNotDuplicatedByFullAssistantAndUsageNotContext() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        let delta = try state.receive(["type": "stream_event", "event": ["delta": ["type": "text_delta", "text": "Hello"]]])
        XCTAssertEqual(delta.first?.payload["text"] as? String, "Hello")
        XCTAssertTrue(try state.receive(["type": "assistant", "message": ["content": [["type": "text", "text": "Hello"]]]]).isEmpty)
        let result = try state.receive(["type": "result", "result": "Hello", "usage": ["input_tokens": 10000]])
        XCTAssertEqual(result.last?.payload["text"] as? String, "Hello")
        XCTAssertNil(result.last?.payload["usage"])
        XCTAssertThrowsError(try state.receive(["type": "system", "session_id": UUID().uuidString, "subtype": "init"]))
    }

    func testContextUsesLatestParentRequestIncludingCacheAndExactReportedModelWindow() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        var info = RuntimeSessionInfo()
        for usage in [["input_tokens": 100, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 2000],
                      ["input_tokens": 20, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 900]] {
            for event in try state.receive(["type": "assistant", "message": ["model": "parent", "content": [], "usage": usage.merging(["output_tokens": 90000]) { _, new in new }]]) {
                if event.name == "session.info" { info.merge(event.payload, runtime: .claude) }
            }
        }
        state.tools.insert("child")
        let child = try state.receive(["type": "assistant", "parent_tool_use_id": "child", "message": ["model": "other", "content": [], "usage": ["input_tokens": 500000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]])
        XCTAssertFalse(child.contains { $0.name == "session.info" })
        XCTAssertTrue(try state.receive(["type": "system", "subtype": "init", "parent_tool_use_id": "child", "model": "other"]).isEmpty)
        let events = try state.receive(["type": "result", "usage": ["input_tokens": 900000], "modelUsage": [
            "other": ["contextWindow": 1_000_000], "parent": ["inputTokens": 800000, "contextWindow": 200000]]])
        for event in events where event.name == "session.info" { info.merge(event.payload, runtime: .claude) }
        XCTAssertEqual(info.model, "parent")
        XCTAssertEqual(info.context?.used, 1020)
        XCTAssertEqual(info.context?.limit, 200000)
        XCTAssertEqual(info.context?.estimated, true)
        XCTAssertNil(events.last?.payload["usage"], "A terminal billing aggregate must not become context occupancy")
    }

    func testContextClearsAfterCompactionAndDoesNotCarryAnotherModelsWindow() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        var info = RuntimeSessionInfo()
        let usage = ["input_tokens": 64, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]
        let first = try state.receive(["type": "assistant", "message": ["model": "first", "content": [], "usage": usage]])
        let result = try state.receive(["type": "result", "modelUsage": ["first": ["contextWindow": 200000]]])
        for event in first + result where event.name == "session.info" { info.merge(event.payload, runtime: .claude) }
        for event in try state.receive(["type": "system", "subtype": "compact_boundary"]) { info.merge(event.payload, runtime: .claude) }
        XCTAssertNil(info.context?.used)
        XCTAssertEqual(info.context?.limit, 200000)
        try state.begin("next")
        for event in try state.receive(["type": "system", "subtype": "init", "model": "second"]) { info.merge(event.payload, runtime: .claude) }
        XCTAssertNil(info.context)
        for event in try state.receive(["type": "assistant", "message": ["model": "second", "content": [], "usage": usage]]) { info.merge(event.payload, runtime: .claude) }
        for event in try state.receive(["type": "result", "modelUsage": ["first": ["contextWindow": 200000]]]) where event.name == "session.info" { info.merge(event.payload, runtime: .claude) }
        XCTAssertEqual(info.context?.used, 64)
        XCTAssertNil(info.context?.limit, "Another model's catalog window cannot be guessed")
    }

    func testMissingMalformedAndAggregateUsageNeverInventContextCounts() throws {
        for count: Any in [-1, true, "100", 1.5, Int.max] {
            var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
            let events = try state.receive(["type": "assistant", "message": ["model": "native", "content": [], "usage": ["input_tokens": count, "cache_creation_input_tokens": 1, "cache_read_input_tokens": 1]]])
            XCTAssertNil(events.first?.payload["usage"])
            XCTAssertEqual(events.first?.payload["context_reset"] as? Bool, true)
        }
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        _ = try state.receive(["type": "system", "subtype": "init", "model": "native"])
        let events = try state.receive(["type": "result", "usage": ["input_tokens": 1000], "modelUsage": ["native": ["inputTokens": 1000, "contextWindow": 200000]]])
        let usage = events.first?.payload["usage"] as? [String: Any]
        XCTAssertNil(usage?["context_used"])
        XCTAssertEqual(usage?["context_max"] as? Int, 200000)
        for (rows, expected): ([String: [String: Any]], Int?) in [
            (["alias": ["canonicalModel": "native", "contextWindow": 200000]], 200000),
            (["alias": ["canonicalModel": "native", "contextWindow": 200000],
              "another": ["canonicalModel": "native", "contextWindow": 1_000_000]], nil)] {
            var aliased = ClaudeProtocolState(sessionID: id); try aliased.begin("turn")
            _ = try aliased.receive(["type": "system", "subtype": "init", "model": "native"])
            let events = try aliased.receive(["type": "result", "modelUsage": rows])
            let usage = events.first(where: { $0.name == "session.info" })?.payload["usage"] as? [String: Any]
            XCTAssertEqual(usage?["context_max"] as? Int, expected)
        }
    }

    func testDelegatedFramesUseOneStableToolIdentityAndUnknownChildrenAreIgnored() throws {
        var state = ClaudeProtocolState(sessionID: id); try state.begin("turn")
        let started = try state.receive(["type": "system", "subtype": "task_started", "task_id": "native-task", "tool_use_id": "tool-parent", "task_type": "local_agent"])
        XCTAssertEqual(started.first?.payload["subagent_id"] as? String, "tool-parent")
        let text = try state.receive(["type": "assistant", "session_id": "child-session", "parent_tool_use_id": "tool-parent", "message": ["content": [["type": "text", "text": "Child response"]]]])
        XCTAssertEqual(text.first?.payload["subagent_id"] as? String, "tool-parent")
        XCTAssertTrue(try state.receive(["type": "assistant", "parent_tool_use_id": "unregistered", "message": ["content": [["type": "text", "text": "External"]]]]).isEmpty)
        let completed = try state.receive(["type": "system", "subtype": "task_notification", "task_id": "native-task", "status": "completed"])
        XCTAssertEqual(completed.first?.payload["subagent_id"] as? String, "tool-parent")
        XCTAssertTrue(state.children.isEmpty)
    }

    @MainActor func testComputerUseJoinsTheLaunchWithoutDroppingUserServers() throws {
        let args = try ClaudeClient.arguments(id: id, resume: false, delegation: ["read_only_tools": [String]()], computerUse: "/opt/claude")
        let config = try XCTUnwrap(args.firstIndex(of: "--mcp-config").map { args[$0 + 1] })
        let servers = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])?["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.keys.sorted(), ["computer-use"])
        XCTAssertEqual((servers["computer-use"] as? [String: Any])?["args"] as? [String], ["--computer-use-mcp"])
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "mcp__notch__*,mcp__computer-use__*"])
        XCTAssertFalse(args.contains("--strict-mcp-config"))
    }

    @MainActor func testLaunchPreservesNativeContextAndExactResume() throws {
        let args = try ClaudeClient.arguments(id: id, resume: true)
        XCTAssertTrue(args.contains("--resume=\(id)"))
        for forbidden in ["--bare", "--no-session-persistence", "--continue", "--dangerously-skip-permissions", "--system-prompt", "--setting-sources", "--permission-mode"] { XCTAssertFalse(args.contains(forbidden)) }
        XCTAssertThrowsError(try ClaudeClient.arguments(id: "--continue", resume: true))
        XCTAssertThrowsError(try ClaudeClient.trustedDirectory(["cwd": "/tmp"]))
        let catalog = ClaudeClient.catalog([["value": "default", "resolvedModel": "native-model", "displayName": "Default"], ["value": "other", "displayName": "Other"]])
        XCTAssertEqual(catalog.defaultModel?.model, "native-model")
        XCTAssertEqual(catalog.models.map(\.choice.model), ["native-model", "other"])
    }

    @MainActor func testCatalogDeduplicatesResolvedAliasesAndKeepsNativeEfforts() {
        let rows: [[String: Any]] = [
            ["value": "default", "resolvedModel": "native-opus", "displayName": "Default"],
            ["value": "opus", "resolvedModel": "native-opus", "displayName": "Opus", "supportsEffort": true,
             "supportedEffortLevels": ["low", "high", "max"]],
            ["value": "sonnet", "resolvedModel": "native-sonnet", "supportsEffort": true, "supportedEffortLevels": ["low", "high"]],
            ["value": "unavailable", "disabled": true],
            ["value": "older", "supportsEffort": false, "supportedEffortLevels": ["high"]]
        ]
        for input in [rows, Array(rows.reversed())] {
            let catalog = ClaudeClient.catalog(input)
            XCTAssertEqual(Set(catalog.models.map(\.id)).count, catalog.models.count)
            XCTAssertEqual(catalog.models.count, 3)
            XCTAssertEqual(catalog.defaultModel?.model, "native-opus")
            XCTAssertEqual(catalog.option(for: RuntimeModelChoice(model: "native-opus"))?.title, "Opus")
            XCTAssertEqual(catalog.title(for: RuntimeModelChoice(model: "native-opus", provider: "anthropic")), "Opus")
            XCTAssertEqual(catalog.title(for: RuntimeModelChoice(model: "unlisted-model")), "unlisted-model")
            XCTAssertTrue(catalog.contains(RuntimeModelChoice(model: "native-opus", reasoningEffort: "max")))
            XCTAssertFalse(catalog.contains(RuntimeModelChoice(model: "native-sonnet", reasoningEffort: "max")))
            XCTAssertFalse(catalog.contains(RuntimeModelChoice(model: "older", reasoningEffort: "high")))
            XCTAssertFalse(catalog.contains(RuntimeModelChoice(model: "unavailable")))
        }
    }
}
