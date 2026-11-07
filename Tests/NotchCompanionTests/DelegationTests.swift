import XCTest
@testable import NotchCompanion

/// Each companion session gets runtime ID `rt-<companion id>`; every call is recorded.
@MainActor private final class DelegationFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var steerFails = false
    /// Runtime IDs whose sends the harness refuses outright.
    var rejectSubmits: Set<String> = []
    var failNextCreate = false
    var nextResumeError: Error?
    var createDelay: Duration?
    var modelDelay: Duration?
    /// What each harness's installation reports about hosting delegation, by runtime name.
    var hosts: [String: Bool] = [:]
    struct Rejected: LocalizedError, RuntimeDefinitiveRejection { var errorDescription: String? { "Refused." } }
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "session.create", "session.resume":
            if failNextCreate { failNextCreate = false; throw AppError("The harness did not start.") }
            if method == "session.resume", let error = nextResumeError { nextResumeError = nil; throw error }
            if let createDelay { try await Task.sleep(for: createDelay) }
            let owner = params["companion_id"] as? String ?? UUID().uuidString
            var result: [String: Any] = ["session_id": "rt-" + owner, "stored_session_id": "native-" + owner]
            result["hosts_delegation"] = hosts[params["runtime"] as? String ?? ""]
            return result
        case "runtime.models":
            // Deliberately finish even after cancellation: the caller must
            // recheck before creating a child from this late catalog.
            if let modelDelay { try? await Task.sleep(for: modelDelay) }
            var result: [String: Any] = ["catalog": RuntimeModelCatalog(defaultModel: RuntimeModelChoice(model: "fixture-default"),
                models: [RuntimeModelOption(choice: RuntimeModelChoice(model: "fixture-large"), title: "Large", reasoningEfforts: ["high"])])]
            result["hosts_delegation"] = hosts[params["runtime"] as? String ?? ""]
            return result
        case "prompt.steer" where steerFails: throw AppError("No running turn.")
        case "prompt.submit" where rejectSubmits.contains(params["session_id"] as? String ?? ""): throw Rejected()
        default: return [:]
        }
    }
    func prompts(_ companion: String) -> [String] {
        calls.filter { $0.0 == "prompt.submit" && $0.1["session_id"] as? String == "rt-" + companion }.map { $0.1["text"] as? String ?? "" }
    }
    func count(_ method: String) -> Int { calls.filter { $0.0 == method }.count }
}

@MainActor final class DelegationTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []
    private var models: [AppModel] = []

    override func tearDown() async throws {
        for model in models { model.shutdown() }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        models = []; suites = []; folders = []
    }

    private func preferences(ready: [RuntimeKind] = [.codex, .pi]) -> UserDefaults {
        let suite = "notch-delegation-\(UUID().uuidString)"
        suites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(Dictionary(uniqueKeysWithValues: ready.map { ($0.rawValue, RuntimeRoute.defaultProfile($0, defaults: preferences)) }),
                        forKey: "runtime.configuredProfiles")
        return preferences
    }

    private func makeModel(storage: URL? = nil, preferences: UserDefaults? = nil) -> (AppModel, DelegationFixture, URL, UserDefaults) {
        let url = storage ?? {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-delegation-\(UUID().uuidString)")
            folders.append(folder)
            return folder.appendingPathComponent("sessions.json")
        }()
        let defaults = preferences ?? self.preferences()
        let transport = DelegationFixture()
        let model = AppModel(storageURL: url, playsSounds: false, client: transport, preferences: defaults)
        models.append(model)
        return (model, transport, url, defaults)
    }

    /// A Codex parent in the middle of its turn.
    /// Pi parents never steer, so their wakes always wait for the turn to end.
    private func activeParent(_ model: AppModel, mode: PermissionMode? = nil, runtime: RuntimeKind = .codex) async throws -> (String, DelegationCaller) {
        await model.connect()
        await model.newSession(showPanel: false, runtime: runtime)
        let id = try XCTUnwrap(model.currentID)
        if let mode { model.update(id) { $0.permissionMode = mode; $0.fullAccessConfirmed = true } }
        model.draft = "Coordinate the work"
        await model.send()
        XCTAssertEqual(model.sessions.first { $0.id == id }?.parentTurnComplete, false)
        return (id, DelegationCaller(sessionID: id, runtime: runtime, subagent: false))
    }

    private func finish(_ model: AppModel, _ companion: String, text: String, status: String = "complete") {
        model.receive("message.start", payload: ["session_id": "rt-" + companion])
        model.receive("message.complete", payload: ["session_id": "rt-" + companion, "text": text, "status": status])
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func child(_ model: AppModel, task: Any?) -> CompanionSession? {
        model.sessions.first { $0.delegation?.taskID == task as? String }
    }

    func testStopDuringCatalogPreparationPreventsChildLaunch() async throws {
        for cascade in [true, false] {
            let (model, transport, _, _) = makeModel()
            let (parentID, caller) = try await activeParent(model)
            model.modelCatalogs = [:]
            transport.modelDelay = .milliseconds(300)
            let oldModels = transport.count("runtime.models")
            let delegated = Task { try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Slow catalog", "target": ["model": "fixture-large"]]) }
            await eventually { transport.count("runtime.models") > oldModels }
            XCTAssertFalse(model.sessions.contains { $0.parentSessionID == parentID })
            await model.interrupt(sessionID: parentID, cascade: cascade)
            _ = try? await delegated.value
            let prompts = model.sessions.filter { $0.parentSessionID == parentID }.flatMap { transport.prompts($0.id) }
            XCTAssertEqual(prompts, cascade ? [] : ["Slow catalog"], "Only cascading Stop cancels pending child creation")
            XCTAssertTrue(model.delegationCreations.isEmpty)
        }
    }

    func testReconnectDuringCatalogPreparationPreventsChildLaunch() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        model.modelCatalogs = [:]
        transport.modelDelay = .milliseconds(300)
        let oldModels = transport.count("runtime.models")
        let delegated = Task { try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Slow catalog", "target": ["model": "fixture-large"]]) }
        await eventually { transport.count("runtime.models") > oldModels }
        model.activeOperationDecision = { _ in .stopNow }
        await model.reconnect()
        _ = try? await delegated.value
        XCTAssertFalse(model.sessions.contains { $0.parentSessionID == parentID })
        XCTAssertTrue(model.delegationCreations.isEmpty)
    }

    func testStopDuringWorktreePreparationPreventsChildLaunch() async throws {
        let (model, transport, storage, _) = makeModel()
        let repo = storage.deletingLastPathComponent().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try WorkspaceChanges.run(["init", "-q"], at: repo.path)
        try "fixture".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try WorkspaceChanges.run(["add", "file.txt"], at: repo.path)
        _ = try WorkspaceChanges.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture"], at: repo.path)
        let marker = repo.appendingPathComponent("entered-hook")
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        try ("#!/bin/sh\n/usr/bin/touch '" + marker.path + "'\n/bin/sleep 0.5\n").write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let (parentID, caller) = try await activeParent(model)
        model.update(parentID) { $0.workspacePath = repo.path }
        let delegated = Task { try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Worktree task", "isolation": "worktree"]) }
        await eventually { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertFalse(model.sessions.contains { $0.parentSessionID == parentID })
        await model.interrupt(sessionID: parentID)
        _ = try? await delegated.value
        XCTAssertFalse(model.sessions.contains { $0.parentSessionID == parentID })
        XCTAssertEqual(transport.count("prompt.submit"), 1, "Only the parent's original prompt was sent")
        XCTAssertTrue(model.delegationCreations.isEmpty)
    }

    // MARK: Coordinator

    func testDelegateCreatesAChildInsideItsParentAndARetryIsANoOp() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        XCTAssertNotNil(transport.calls.first { $0.0 == "session.create" }?.1["delegation"], "Codex hosts the tools")
        let arguments: [String: Any] = ["task": "Review the diff", "role": "review", "clientRequestId": "review-1",
                                        "target": ["runtime": "pi", "model": "fixture-large", "options": ["effort": "high"]]]
        let first = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: arguments)
        let child = try XCTUnwrap(self.child(model, task: first["taskId"]))
        XCTAssertEqual(child.parentSessionID, parentID)
        XCTAssertEqual(child.runtime, .pi)
        XCTAssertEqual(child.modelOverride, RuntimeModelChoice(model: "fixture-large", reasoningEffort: "high"))
        XCTAssertEqual(first["status"] as? String, "running")
        XCTAssertEqual(first["next"] as? String, Delegation.next)
        XCTAssertEqual(transport.prompts(child.id), ["Act as the review sub-agent for this task.\n\nReview the diff"], "Only the task, no parent history")
        XCTAssertNotNil(transport.calls.last { $0.0 == "session.create" }?.1["delegation"], "A Pi child gets the tools too, so it can delegate")
        let row = try XCTUnwrap(model.sessions.first { $0.id == parentID }?.agents.first)
        XCTAssertEqual(row.sessionID, child.id)
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.delegationDetail, "Pi · review")
        XCTAssertFalse(model.visibleSessions.contains { $0.id == child.id }, "Children never list at the top level")
        XCTAssertFalse(model.sessionIndicators.contains { $0.id == child.id })
        model.sessionSearch = "Review"
        XCTAssertFalse(model.visibleSessions.contains { $0.id == child.id }, "Or appear in search")
        let again = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: arguments)
        XCTAssertEqual(again["taskId"] as? String, first["taskId"] as? String)
        XCTAssertEqual(model.sessions.filter { $0.parentSessionID == parentID }.count, 1)
        XCTAssertEqual(transport.prompts(child.id).count, 1, "A repeated clientRequestId sends nothing")
        let fresh = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Another look"])
        XCTAssertNotEqual(fresh["taskId"] as? String, first["taskId"] as? String, "Without a key every call is new work")
        XCTAssertEqual(self.child(model, task: fresh["taskId"])?.runtime, .codex, "The default target is the caller's harness")
    }

    func testDelegateNeedsAnActiveTurnAndOnlyTheOwnerReadsATask() async throws {
        let (model, _, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Research it"])
        finish(model, parentID, text: "Waiting")
        do {
            _ = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Too late"])
            XCTFail("A finished turn cannot delegate")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "parent_not_active") }
        await model.newSession(showPanel: false, runtime: .codex)
        let stranger = DelegationCaller(sessionID: try XCTUnwrap(model.currentID), runtime: .codex, subagent: false)
        do {
            _ = try await model.handleDelegationTool(stranger, name: "task_status", arguments: ["taskId": started["taskId"]!])
            XCTFail("Another session's task is not readable")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "task_not_found") }
    }

    func testModesOnlyNarrowAndStepDownToWhatTheTargetOffers() throws {
        let all = PermissionMode.allCases
        XCTAssertEqual(try Delegation.childMode(parent: .autoEdit, requested: nil, supported: all), .autoEdit, "Inherited")
        XCTAssertEqual(try Delegation.childMode(parent: .fullAccess, requested: nil, supported: [.ask, .autoEdit, .plan]), .autoEdit, "Steps down")
        XCTAssertNil(try Delegation.childMode(parent: .fullAccess, requested: nil, supported: []), "A target without modes keeps its own")
        for parent in [PermissionMode.ask, .autoEdit, .plan] {
            XCTAssertThrowsError(try Delegation.childMode(parent: parent, requested: nil, supported: []),
                                 "Under \(parent.title), a target without modes could run unrestricted")
        }
        XCTAssertNil(try Delegation.childMode(parent: nil, requested: nil, supported: all))
        XCTAssertEqual(try Delegation.childMode(parent: .fullAccess, requested: .ask, supported: all), .ask, "Narrowing is allowed")
        XCTAssertEqual(try Delegation.childMode(parent: .autoEdit, requested: .plan, supported: all), .plan)
        XCTAssertEqual(try Delegation.childMode(parent: nil, requested: .ask, supported: all), .ask)
        for (parent, requested) in [(PermissionMode.ask, PermissionMode.fullAccess), (.autoEdit, .fullAccess), (.plan, .ask)] as [(PermissionMode?, PermissionMode)]
            + [(nil, .autoEdit)] {
            XCTAssertThrowsError(try Delegation.childMode(parent: parent, requested: requested, supported: all), "\(String(describing: parent)) → \(requested)")
        }
        XCTAssertThrowsError(try Delegation.childMode(parent: .fullAccess, requested: .autoEdit, supported: [.ask])) {
            XCTAssertEqual(($0 as? DelegationFailure)?.code, "invalid_request", "An explicit mode the target lacks is rejected")
        }
        XCTAssertEqual(try Delegation.requestedMode(["runtimeMode": "auto-accept-edits"]), .autoEdit)
        XCTAssertEqual(try Delegation.requestedMode(["interactionMode": "plan", "runtimeMode": "full-access"]), .plan)
        XCTAssertNil(try Delegation.requestedMode([:]))
    }

    func testAChildInheritsItsParentsModeThroughDelegate() async throws {
        let (model, _, _, _) = makeModel()
        let (_, caller) = try await activeParent(model, mode: .autoEdit)
        let inherited = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Edit"])
        XCTAssertEqual(child(model, task: inherited["taskId"])?.permissionMode, .autoEdit)
        do {
            _ = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "More", "runtimeMode": "full-access"])
            XCTFail("Escalation is rejected")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "runtime_mode_escalation_denied") }
        do {
            _ = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Read", "target": ["runtime": "pi"]])
            XCTFail("Pi maps no modes, so it cannot run under Auto-edit")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "runtime_mode_escalation_denied") }
        let capabilities = try await model.handleDelegationTool(caller, name: "orchestrator_capabilities", arguments: [:])
        let pi = (capabilities["runtimes"] as? [[String: Any]])?.first { $0["runtime"] as? String == "pi" }
        XCTAssertEqual(pi?["canRunChildTask"] as? Bool, false)
    }

    func testStopCascadesDepthFirstButAPlainInterruptDoesNot() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let first = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Child"])
        let childID = try XCTUnwrap(child(model, task: first["taskId"])).id
        let nested = try await model.handleDelegationTool(DelegationCaller(sessionID: childID, runtime: .codex, subagent: true),
                                                          name: "delegate_task", arguments: ["task": "Grandchild"])
        let grandchildID = try XCTUnwrap(child(model, task: nested["taskId"])).id
        XCTAssertEqual(transport.calls.last { $0.0 == "session.create" }?.1["delegation"].map { _ in true }, true, "A child can delegate too")
        await model.interrupt(sessionID: parentID, cascade: false)
        let interrupted = { transport.calls.filter { $0.0 == "session.interrupt" }.compactMap { $0.1["session_id"] as? String } }
        XCTAssertEqual(interrupted(), ["rt-" + parentID], "A plain interrupt leaves the children running")
        XCTAssertTrue(model.sessions.first { $0.id == parentID }!.isBusy, "Live children keep the parent working")
        model.update(parentID) { $0.state = .working; $0.parentTurnComplete = false }
        await model.interrupt(sessionID: parentID)
        XCTAssertEqual(Array(interrupted().dropFirst()), ["rt-" + parentID, "rt-" + grandchildID, "rt-" + childID], "Stop goes depth-first")
        XCTAssertEqual(model.sessions.first { $0.id == childID }?.delegation?.completionWake, false, "Stop drops pending wakes")
        XCTAssertEqual(model.sessions.first { $0.id == grandchildID }?.delegation?.cancelled, true)
    }

    func testAWakeIsDeliveredOnceAcrossARestartAndSkippedAfterTaskStatus() async throws {
        let (model, transport, storage, defaults) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Review", "role": "review"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, parentID, text: "I'll wait for the review.")
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.state, .working, "waiting_for_children keeps the parent working")
        XCTAssertEqual(model.taskResult(childID)["workState"] as? String, "working")
        finish(model, childID, text: "Two findings.")
        await eventually { transport.prompts(parentID).count == 2 }
        let wake = try XCTUnwrap(transport.prompts(parentID).last)
        XCTAssertTrue(wake.contains("Two findings.") && wake.contains(started["taskId"] as! String), wake)
        let row = try XCTUnwrap(model.sessions.first { $0.id == parentID }?.messages.last)
        XCTAssertTrue(row.isDelegationResult, "Shown as a Delegation result row")
        XCTAssertEqual(row.delegationSummary, "Delegated task \"\(model.sessions.first { $0.id == childID }?.title ?? "")\" finished", "T3's one-line notice, not the answer")
        XCTAssertEqual(row.delegationChildID, childID, "The row opens the child")
        XCTAssertEqual(row.role, "user")
        model.shutdown()
        let (restarted, again, _, _) = makeModel(storage: storage, preferences: defaults)
        await restarted.connect()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(again.count("prompt.submit"), 0, "A delivered wake is never repeated")
        XCTAssertFalse(restarted.visibleSessions.contains { $0.id == childID })

        // A second task whose result the parent reads first never wakes it.
        let (other, otherTransport, _, _) = makeModel()
        let (otherParent, otherCaller) = try await activeParent(other, runtime: .pi)
        let task = try await other.handleDelegationTool(otherCaller, name: "delegate_task", arguments: ["task": "Look"])
        let otherChild = try XCTUnwrap(child(other, task: task["taskId"])).id
        finish(other, otherChild, text: "Done looking.")
        let status = try await other.handleDelegationTool(otherCaller, name: "task_status", arguments: ["taskId": task["taskId"]!])
        XCTAssertEqual(status["status"] as? String, "completed")
        XCTAssertEqual(status["summary"] as? String, "Done looking.")
        XCTAssertNil(status["next"])
        finish(other, otherParent, text: "Read it already.")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(otherTransport.prompts(otherParent).count, 1, "Reading the result suppressed the wake")
        XCTAssertEqual(other.sessions.first { $0.id == otherParent }?.state, .finished)
    }

    func testAWakeMarkedBeforeACrashIsSentAfterTheRestart() async throws {
        let (model, _, storage, defaults) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Review"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "Result.")
        // The parent is still in its turn, so nothing is sent yet; then the app dies mid-wake.
        model.update(childID) { $0.delegation?.wokenCompletionID = $0.completionID; $0.delegation?.wakeMessageID = "never-sent" }
        model.save()
        model.shutdown()
        let (restarted, transport, _, _) = makeModel(storage: storage, preferences: defaults)
        await restarted.connect()
        await eventually { transport.prompts(parentID).count == 1 }
        XCTAssertTrue(transport.prompts(parentID).first?.contains("Result.") == true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.prompts(parentID).count, 1, "Exactly once")
    }

    func testAWaitThatTimesOutSwitchesToAWake() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let waited = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Slow", "mode": "wait", "timeoutMs": 300])
        XCTAssertEqual(waited["waitTimedOut"] as? Bool, true)
        XCTAssertEqual(waited["next"] as? String, Delegation.next)
        let childID = try XCTUnwrap(child(model, task: waited["taskId"])).id
        XCTAssertEqual(model.sessions.first { $0.id == childID }?.delegation?.completionWake, true)
        finish(model, parentID, text: "Ending my turn.")
        finish(model, childID, text: "Slow result.")
        await eventually { transport.prompts(parentID).count == 2 }

        // A wait that sees the result returns it and does not wake.
        let (other, otherTransport, _, _) = makeModel()
        let (otherParent, otherCaller) = try await activeParent(other)
        async let result = other.handleDelegationTool(otherCaller, name: "delegate_task", arguments: ["task": "Quick", "mode": "wait"])
        await eventually { other.delegationWaits[otherParent] == 1 }
        let quick = try XCTUnwrap(other.sessions.first { $0.parentSessionID == otherParent })
        finish(other, quick.id, text: "Quick result.")
        let returned = try await result
        XCTAssertEqual(returned["summary"] as? String, "Quick result.")
        XCTAssertEqual(returned["waitTimedOut"] as? Bool, false)
        finish(other, otherParent, text: "Used it.")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(otherTransport.prompts(otherParent).count, 1)
    }

    func testAWaitCountsChildCreationAgainstItsTimeout() async throws {
        let (model, transport, _, _) = makeModel()
        let (_, caller) = try await activeParent(model)
        transport.createDelay = .milliseconds(800)
        let started = Date()
        let waited = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Slow start", "mode": "wait", "timeoutMs": 600])
        XCTAssertEqual(waited["waitTimedOut"] as? Bool, true)
        XCTAssertEqual(waited["next"] as? String, Delegation.next)
        // One budget from the call, so an OpenClaw wait answers inside the Gateway's node deadline.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2, "A 0.8 s creation uses up the 0.6 s budget, so the wait returns at once")
    }

    func testAGrandchildKeepsEveryoneBusyUntilItEnds() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let first = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Child"])
        let childID = try XCTUnwrap(child(model, task: first["taskId"])).id
        let nested = try await model.handleDelegationTool(DelegationCaller(sessionID: childID, runtime: .codex, subagent: true),
                                                          name: "delegate_task", arguments: ["task": "Grandchild"])
        let grandchildID = try XCTUnwrap(child(model, task: nested["taskId"])).id
        finish(model, parentID, text: "Waiting.")
        finish(model, childID, text: "Waiting for my child.")
        XCTAssertEqual(model.taskResult(childID)["workState"] as? String, "waiting_for_children")
        XCTAssertTrue(model.sessions.first { $0.id == parentID }!.isBusy)
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.agents.first?.state, .working)
        XCTAssertTrue(model.hasActiveWork, "Quit and Reconnect wait for app-owned children")
        finish(model, grandchildID, text: "Leaf result.")
        await eventually { transport.prompts(childID).count == 2 }
        XCTAssertTrue(transport.prompts(childID).last!.contains("Leaf result."), "The grandchild wakes its own parent")
        XCTAssertTrue(model.sessions.first { $0.id == parentID }!.isBusy, "The root waits for the child's wake turn")
        finish(model, childID, text: "Combined result.")
        await eventually { transport.prompts(parentID).count == 2 }
        XCTAssertTrue(transport.prompts(parentID).last!.contains("Combined result."))
    }

    func testAResultWakesARunningCodexTurnBySteering() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Side job"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "Side result.")
        await eventually { transport.count("prompt.steer") == 1 }
        XCTAssertEqual(transport.calls.last { $0.0 == "prompt.steer" }?.1["session_id"] as? String, "rt-" + parentID)
        await eventually { model.sessions.first { $0.id == parentID }?.messages.last?.isDelegationResult == true }
        let turn = try XCTUnwrap(model.sessions.first { $0.id == parentID }?.messages.first { $0.role == "user" }?.turnID)
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.messages.last?.turnID, turn, "A steered row stays in the running turn")
        finish(model, parentID, text: "Done.")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.prompts(parentID).count, 1, "A steered result is not queued again")
    }

    func testCapabilitiesListReadyHarnessesModesAndLimits() async throws {
        let (model, _, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, mode: .autoEdit)
        let capabilities = try await model.handleDelegationTool(caller, name: "orchestrator_capabilities", arguments: [:])
        XCTAssertEqual(capabilities["parentSessionId"] as? String, parentID)
        XCTAssertEqual(capabilities["runtimeMode"] as? String, "auto-accept-edits")
        let rows = try XCTUnwrap(capabilities["runtimes"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["runtime"] as? String }, ["codex", "pi"])
        XCTAssertEqual((rows[0]["models"] as? [[String: Any]])?.first?["id"] as? String, "fixture-large")
        XCTAssertEqual(rows[0]["runtimeModes"] as? [String], ["approval-required", "auto-accept-edits", "full-access"])
        XCTAssertEqual(rows[1]["runtimeModes"] as? [String], [])
        XCTAssertEqual((capabilities["features"] as? [String: Any])?["maxBatchThreads"] as? Int, 20)
    }

    func testOpenClawCallersWaitInsideTheGatewayDeadlineAndGetTheInstructions() async throws {
        // A node tool call ends at 120 s, so every OpenClaw wait returns `next` before that.
        XCTAssertEqual(AppModel.waitTimeout([:], runtime: .openclaw), Delegation.openClawMaxWait)
        XCTAssertEqual(AppModel.waitTimeout(["timeoutMs": 3_600_000], runtime: .openclaw), Delegation.openClawMaxWait)
        XCTAssertEqual(AppModel.waitTimeout(["timeoutMs": 5_000], runtime: .openclaw), 5)
        XCTAssertEqual(AppModel.waitTimeout([:], runtime: .codex), Delegation.defaultWait)
        XCTAssertEqual(AppModel.waitTimeout(["timeoutMs": 3_600_000], runtime: .codex), Delegation.maxWait)
        XCTAssertLessThan(Delegation.openClawMaxWait, 120)

        let (model, _, _, _) = makeModel()
        let (_, caller) = try await activeParent(model, runtime: .openclaw)
        let capabilities = try await model.handleDelegationTool(caller, name: "orchestrator_capabilities", arguments: [:])
        XCTAssertEqual(capabilities["instructions"] as? String, Delegation.instructions, "Node tools carry no server instructions")
        let (other, _, _, _) = makeModel()
        let (_, codex) = try await activeParent(other)
        let codexCapabilities = try await other.handleDelegationTool(codex, name: "orchestrator_capabilities", arguments: [:])
        XCTAssertNil(codexCapabilities["instructions"], "Other harnesses already have them in their own prompt")
    }

    func testRegistryRoundTripsDelegationAndOldRegistriesDecode() throws {
        var child = CompanionSession()
        child.parentSessionID = "parent"
        child.delegation = DelegationRecord(taskID: "task", clientRequestID: "key", role: "review", completionWake: false, readCompletionID: "read")
        var parent = CompanionSession()
        parent.messages = [ChatMessage(role: "user", text: "Result", kind: ChatMessage.delegationResult)]
        parent.agents = [ChildAgent(id: "delegation:task", title: "Review", turnID: parent.messages[0].id, sessionID: child.id, runtime: .codex, role: "review")]
        let data = try JSONEncoder().encode([parent, child])
        let restored = try JSONDecoder().decode([CompanionSession].self, from: data)
        XCTAssertEqual(restored, [parent, child])
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        rows[1].removeValue(forKey: "parentSessionID"); rows[1].removeValue(forKey: "delegation")
        var message = (rows[0]["messages"] as! [[String: Any]])[0]; message["kind"] = "futureKind"; rows[0]["messages"] = [message]
        let old = try JSONDecoder().decode([CompanionSession].self, from: JSONSerialization.data(withJSONObject: rows))
        XCTAssertNil(old[1].parentSessionID)
        XCTAssertNil(old[1].delegation)
        XCTAssertEqual(old[0].messages[0].kind, "futureKind", "An unknown kind keeps the conversation")
        XCTAssertFalse(old[0].messages[0].isDelegationResult)
    }

    func testCompanionToolsAreLabelledUnderEveryPrefix() {
        for name in ["mcp__notch__delegate_task", "notch.delegate_task", "delegate_task", "notch_delegate_task", OpenCodeClient.delegationServerName("ses_x") + "_delegate_task"] {
            XCTAssertEqual(ToolActivity(id: "a", name: name, detail: "").displayName, "Delegating a child task", name)
        }
        XCTAssertNil(ToolActivity.delegationTool("notch-docs_search"), "Only a companion server's tools, not a user's server named notch-…")
        // OpenClaw's `notch_` prefix, and the bare tools that already start with `notch_`.
        XCTAssertEqual(ToolActivity.delegationTool("notch_notch_session_list"), "notch_session_list")
        XCTAssertEqual(ToolActivity.delegationTool("notch_session_list"), "notch_session_list")
        XCTAssertNil(ToolActivity.delegationTool("notch_unrelated"))
        XCTAssertEqual(ToolActivity(id: "a", name: "mcp__notch__task_status", detail: "", state: .finished).displayName, "Got delegated task status")
        XCTAssertEqual(NotchHeaderView.status(state: .working, session: CompanionSession(), waitingOnChild: true).text, "Waiting on a child")
        XCTAssertLessThan(Delegation.instructions.utf8.count, 4_000, "Codex truncates a longer context entry")
        XCTAssertEqual(Set(Delegation.tools.compactMap { $0["name"] as? String }), Set(ToolActivity.delegationLabels.keys), "Every tool has a label")
    }

    func testAnInstallationThatCannotHostGetsNoTokenAndIsNotOfferedAsDelegating() async throws {
        for hosts in [false, true] {
            let (model, transport, _, _) = makeModel(preferences: preferences(ready: [.codex, .opencode]))
            transport.hosts["opencode"] = hosts
            // Opened before anything was known: the installation's answer decides whether the token stays.
            await model.connect()
            await model.newSession(showPanel: false, runtime: .opencode)
            let direct = try XCTUnwrap(model.currentID)
            model.draft = "Hello"
            await model.send()
            XCTAssertNotNil(transport.calls.last { $0.0 == "session.create" }?.1["delegation"])
            XCTAssertEqual(model.delegationServer.hasGrant(sessionID: direct), hosts, "OpenCode 1.x never uses its token")

            let (_, caller) = try await activeParent(model)
            let capabilities = try await model.handleDelegationTool(caller, name: "orchestrator_capabilities", arguments: [:])
            let rows = try XCTUnwrap(capabilities["runtimes"] as? [[String: Any]])
            let constraints = rows.first { $0["runtime"] as? String == "opencode" }?["constraints"] as? [String] ?? []
            XCTAssertEqual(constraints.contains("Its children cannot delegate further."), !hosts)
            let task = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Look", "target": ["runtime": "opencode"]])
            let delegated = try XCTUnwrap(child(model, task: task["taskId"]))
            XCTAssertEqual(transport.calls.last { $0.0 == "session.create" }?.1["delegation"] != nil, hosts, "Only a hosting child gets the tools")
            XCTAssertEqual(model.delegationServer.hasGrant(sessionID: delegated.id), hosts)
        }
    }

    func testOpenCodeToolsRefuseACallFromAnotherNativeSession() async throws {
        let (model, _, _, _) = makeModel(preferences: preferences(ready: [.codex, .opencode]))
        let (parentID, caller) = try await activeParent(model, runtime: .opencode)
        let server = model.delegationServer
        let token = server.issueToken(for: caller)
        func post(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let response = await server.respond(method: "POST", path: "/mcp", headers: ["Authorization": "Bearer " + token],
                                                body: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
            return try XCTUnwrap((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["result"] as? [String: Any])
        }
        func list(from native: String?) async throws -> Bool {
            var params: [String: Any] = ["name": "notch_session_list", "arguments": [:]]
            if let native { params["_meta"] = ["ai.opencode/sessionID": native] }
            let result = try await post("tools/call", params)
            if result["isError"] as? Bool == true {
                XCTAssertTrue(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("capability_denied") == true)
            }
            return result["isError"] as? Bool == false
        }
        let initialized = try await post("initialize", ["protocolVersion": "2025-06-18"])
        XCTAssertEqual(initialized["instructions"] as? String, "", "The session instruction entry carries them once, not once per server")
        let own = try XCTUnwrap(model.sessions.first { $0.id == parentID }?.storedID)
        let ownResult = try await list(from: own)
        XCTAssertTrue(ownResult, "The session itself")
        let unnamed = try await list(from: nil)
        XCTAssertTrue(unnamed, "No session named, nothing to check")
        let other = try await list(from: "ses_another")
        XCTAssertFalse(other, "Another session cannot use this session's server and token")
        model.update(parentID) { $0.agents.append(ChildAgent(id: "ses_native_child", nativeID: "ses_native_child", title: "Explore")) }
        let nativeChild = try await list(from: "ses_native_child")
        XCTAssertTrue(nativeChild, "A native subagent works inside its parent's turn")
    }

    // MARK: Session tools

    func testCreateSessionsMakesOrdinaryTopLevelSessionsOnce() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        let arguments: [String: Any] = ["clientRequestId": "batch", "sessions": [
            ["prompt": "Draft the release notes", "title": "Release notes", "target": ["runtime": "pi"]], ["title": "Empty"]]]
        let made = try await model.handleDelegationTool(caller, name: "create_sessions", arguments: arguments)
        let rows = try XCTUnwrap(made["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["Release notes", "Empty"])
        let ids = rows.compactMap { $0["sessionId"] as? String }
        XCTAssertTrue(ids.allSatisfy { id in model.visibleSessions.contains { $0.id == id && $0.parentSessionID == nil } }, "They list normally")
        XCTAssertEqual(transport.prompts(ids[0]), ["Draft the release notes"])
        XCTAssertEqual(model.sessions.first { $0.id == ids[0] }?.runtime, .pi)
        XCTAssertEqual(model.projectPath(of: model.sessions.first { $0.id == ids[1] }!), model.projectPath(of: model.sessions.first { $0.id == parentID }!))
        let again = try await model.handleDelegationTool(caller, name: "create_sessions", arguments: arguments)
        XCTAssertEqual((again["sessions"] as? [[String: Any]])?.compactMap { $0["sessionId"] as? String }, ids)
        XCTAssertEqual(transport.prompts(ids[0]).count, 1, "A retry creates and sends nothing")
        do {
            _ = try await model.handleDelegationTool(caller, name: "create_sessions", arguments: ["sessions": Array(repeating: ["title": "x"], count: 21)])
            XCTFail("At most 20")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "invalid_request") }
    }

    func testListAndReadSessionsIncrementallyAndAReadDeliversAResult() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Look"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        let listed = try await model.handleDelegationTool(caller, name: "notch_session_list", arguments: [:])
        let top = (listed["sessions"] as? [[String: Any]])?.compactMap { $0["sessionId"] as? String } ?? []
        XCTAssertEqual(top.first, parentID, "Newest first")
        XCTAssertFalse(top.contains(childID), "Children only on request")
        let all = try await model.handleDelegationTool(caller, name: "notch_session_list", arguments: ["includeSubagents": true])
        XCTAssertTrue((all["sessions"] as? [[String: Any]])?.contains { $0["sessionId"] as? String == childID } == true)
        XCTAssertEqual((all["sessions"] as? [[String: Any]])?.first { $0["sessionId"] as? String == childID }?["relationshipToParent"] as? String, "subagent")
        finish(model, childID, text: "Found it.")
        let first = try await model.handleDelegationTool(caller, name: "notch_session_read", arguments: ["sessionId": childID, "limit": 1])
        XCTAssertEqual((first["items"] as? [[String: Any]])?.first?["role"] as? String, "user")
        XCTAssertEqual(first["hasMore"] as? Bool, true)
        XCTAssertNil(model.sessions.first { $0.id == childID }?.delegation?.readCompletionID, "The answer was not read yet")
        let rest = try await model.handleDelegationTool(caller, name: "notch_session_read", arguments: ["sessionId": childID, "afterPosition": first["nextPosition"]!])
        XCTAssertEqual((rest["items"] as? [[String: Any]])?.first?["text"] as? String, "Found it.")
        XCTAssertEqual(rest["hasMore"] as? Bool, false)
        finish(model, parentID, text: "Done.")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.prompts(parentID).count, 1, "Reading the final answer delivered it, so no wake")
        let own = try await model.handleDelegationTool(caller, name: "notch_session_read", arguments: ["view": "activity", "maxCharsPerItem": 4])
        XCTAssertEqual((own["session"] as? [String: Any])?["sessionId"] as? String, parentID, "No sessionId reads your own")
        XCTAssertEqual((own["items"] as? [[String: Any]])?.first?["textTruncated"] as? Bool, true)
    }

    func testSendQueuesSteersRestartsAndStartsAFreshTaskInAFinishedChild() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let made = try await model.handleDelegationTool(caller, name: "create_sessions", arguments: ["sessions": [["prompt": "Work", "target": ["runtime": "pi"]]]])
        let otherID = try XCTUnwrap((made["sessions"] as? [[String: Any]])?.first?["sessionId"] as? String)
        let queued = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": otherID, "message": "Also this", "clientRequestId": "m1"])
        XCTAssertEqual(queued["delivery"] as? String, "queued", "A Pi turn cannot be steered, so it waits")
        let retry = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": otherID, "message": "Also this", "clientRequestId": "m1"])
        XCTAssertEqual(retry["delivery"] as? String, "queued")
        finish(model, otherID, text: "Worked.")
        await eventually { transport.prompts(otherID) == ["Work", "Also this"] }
        let row = try XCTUnwrap(model.sessions.first { $0.id == otherID }?.messages.first { $0.text == "Also this" })
        XCTAssertEqual(row.agentLabel, "From another session")
        XCTAssertTrue(model.sessions.first { $0.id == otherID }!.queuedSends.isEmpty)

        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "First pass"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "First result.")
        _ = try await model.handleDelegationTool(caller, name: "task_status", arguments: ["taskId": started["taskId"]!])
        let followUp = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": childID, "message": "One more thing"])
        XCTAssertEqual(followUp["delivery"] as? String, "started")
        let freshTask = try XCTUnwrap(followUp["taskId"] as? String)
        XCTAssertNotEqual(freshTask, started["taskId"] as? String, "A finished child gets a fresh task")
        finish(model, parentID, text: "Waiting.")
        finish(model, childID, text: "Second result.")
        await eventually { transport.prompts(parentID).last?.contains("Second result.") == true }

        // Codex sessions take a running-turn update; restart interrupts first.
        let (codex, codexTransport, _, _) = makeModel()
        let (_, codexCaller) = try await activeParent(codex)
        let codexMade = try await codex.handleDelegationTool(codexCaller, name: "create_sessions", arguments: ["sessions": [["prompt": "Run"]]])
        let runningID = try XCTUnwrap((codexMade["sessions"] as? [[String: Any]])?.first?["sessionId"] as? String)
        let steered = try await codex.handleDelegationTool(codexCaller, name: "notch_session_send", arguments: ["sessionId": runningID, "message": "Mid-turn note"])
        XCTAssertEqual(steered["delivery"] as? String, "steered")
        let restart = Task { try await codex.handleDelegationTool(codexCaller, name: "notch_session_send", arguments: ["sessionId": runningID, "message": "Start over", "mode": "restart"]) }
        await eventually { codexTransport.calls.contains { $0.0 == "session.interrupt" && $0.1["session_id"] as? String == "rt-" + runningID } }
        finish(codex, runningID, text: "", status: "interrupted")
        let restarted = try await restart.value
        XCTAssertEqual(restarted["delivery"] as? String, "restarted")
        XCTAssertEqual(codexTransport.prompts(runningID).last, "Start over")
    }

    func testSendAndInterruptRespectTheModeCeiling() async throws {
        let (model, transport, _, _) = makeModel()
        let (_, caller) = try await activeParent(model, mode: .ask)
        await model.newSession(showPanel: false, runtime: .codex)
        let broader = try XCTUnwrap(model.currentID)
        model.update(broader) { $0.permissionMode = .fullAccess; $0.fullAccessConfirmed = true }
        do {
            _ = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": broader, "message": "Hi"])
            XCTFail("A broader session cannot be driven")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "runtime_mode_escalation_denied") }
        do {
            _ = try await model.handleDelegationTool(caller, name: "notch_session_interrupt", arguments: ["sessionId": broader])
            XCTFail("Or interrupted")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "runtime_mode_escalation_denied") }
        XCTAssertTrue(model.withinModeCeiling(caller: .autoEdit, target: .ask))
        XCTAssertTrue(model.withinModeCeiling(caller: .fullAccess, target: nil))
        XCTAssertFalse(model.withinModeCeiling(caller: nil, target: .autoEdit))
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Child"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        do {
            _ = try await model.handleDelegationTool(caller, name: "notch_session_interrupt", arguments: ["sessionId": childID])
            XCTFail("A delegate stops with task_cancel")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "thread_not_interruptible") }
        let idle = try await model.handleDelegationTool(caller, name: "notch_session_interrupt", arguments: ["sessionId": caller.sessionID])
        XCTAssertEqual(idle["status"] as? String, "interrupt_requested", "The caller may interrupt its own running turn")
        XCTAssertFalse(transport.calls.contains { $0.0 == "session.interrupt" && $0.1["session_id"] as? String == "rt-" + childID }, "A plain interrupt leaves children")
        let waited = try await model.handleDelegationTool(caller, name: "notch_session_wait", arguments: ["sessionId": broader, "timeoutMs": 100])
        XCTAssertEqual(waited["timedOut"] as? Bool, false, "An idle session returns at once")
        let renamed = try await model.handleDelegationTool(caller, name: "notch_session_update", arguments: ["sessionId": broader, "action": "rename", "title": "Renamed"])
        XCTAssertEqual(renamed["title"] as? String, "Renamed")
    }

    func testAChildsQuestionReachesItsParentAsANoticeAndApprovalsStayWithTheUser() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Pick a color"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, parentID, text: "Waiting.")
        model.receive("message.start", payload: ["session_id": "rt-" + childID])
        model.receive("clarify.request", payload: ["session_id": "rt-" + childID, "request_id": "q1", "question": "Which color?", "choices": ["Red", "Blue"]])
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.displayState, .waiting, "The parent needs you while its child asks")
        await eventually { transport.prompts(parentID).count == 2 }
        let notice = try XCTUnwrap(transport.prompts(parentID).last)
        XCTAssertTrue(notice.contains("Which color?") && notice.contains("pending_request_respond") && notice.contains("q1"), notice)
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.messages.last?.agentLabel, "Delegated question")
        let ids = try await model.handleDelegationTool(caller, name: "pending_request_list", arguments: ["sessionId": childID])
        XCTAssertEqual(ids["requestIds"] as? [String], ["q1"])
        let read = try await model.handleDelegationTool(caller, name: "pending_request_read", arguments: ["sessionId": childID, "requestId": "q1"])
        let question = try XCTUnwrap((read["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["question"] as? String, "Which color?")
        XCTAssertEqual((question["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String }, ["Red", "Blue"])
        _ = try await model.handleDelegationTool(caller, name: "pending_request_respond", arguments: ["sessionId": childID, "requestId": "q1", "answers": ["0": "Blue"]])
        let reply = try XCTUnwrap(transport.calls.last { $0.0 == "clarify.respond" }?.1)
        XCTAssertEqual(reply["answer"] as? String, "Blue")
        XCTAssertEqual(reply["session_id"] as? String, "rt-" + childID)
        model.receive("approval.request", payload: ["session_id": "rt-" + childID, "request_id": "a1", "command": "rm -rf build"])
        do {
            _ = try await model.handleDelegationTool(caller, name: "pending_request_respond", arguments: ["sessionId": childID, "requestId": "a1", "answers": ["0": "once"]])
            XCTFail("The parent never grants approvals")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "capability_denied") }
        XCTAssertEqual(model.taskResult(childID)["pendingApproval"].flatMap { $0 as? [String: Any] }?["requestId"] as? String, "a1")
        XCTAssertFalse(transport.calls.contains { $0.0 == "approval.respond" })
    }

    func testANoticeIsSkippedForAWaitAndCancelledOnceAnswered() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        async let waited = model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Ask me", "mode": "wait"])
        await eventually { model.delegationWaits[parentID] == 1 }
        let childID = try XCTUnwrap(model.sessions.first { $0.parentSessionID == parentID }).id
        model.receive("clarify.request", payload: ["session_id": "rt-" + childID, "request_id": "q1", "question": "Name?"])
        let result = try await waited
        XCTAssertEqual(result["hasPendingQuestion"] as? Bool, true, "The wait returns the question")
        XCTAssertTrue(model.sessions.first { $0.id == parentID }!.queuedSends.isEmpty, "So no notice is queued")
        model.receive("clarify.request", payload: ["session_id": "rt-" + childID, "request_id": "q2", "question": "Age?"])
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.queuedSends.count, 1, "A later question is queued while the parent works")
        model.receive("clarify.expire", payload: ["session_id": "rt-" + childID, "request_id": "q2"])
        finish(model, parentID, text: "Done.")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(transport.prompts(parentID).count, 1, "An answered question's notice is dropped")
        XCTAssertTrue(model.sessions.first { $0.id == parentID }!.queuedSends.isEmpty)
    }

    func testWorktreeIsolationChecksOutTheParentsHeadOnANewBranch() async throws {
        let (model, transport, _, _) = makeModel()
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("notch-worktree-\(UUID().uuidString)")
        folders.append(repository)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("app"), withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try git("init", "-q")
        try Data("committed".utf8).write(to: repository.appendingPathComponent("app/README.md"))
        try git("add", "."); try git("commit", "-q", "-m", "Initial")
        try Data("uncommitted".utf8).write(to: repository.appendingPathComponent("app/draft.txt"))
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex, workspace: repository.appendingPathComponent("app").path)
        let parentID = try XCTUnwrap(model.currentID)
        model.draft = "Split the work"
        await model.send()
        let caller = DelegationCaller(sessionID: parentID, runtime: .codex, subagent: false)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Try the risky approach", "isolation": "worktree", "title": "Risky approach"])
        let child = try XCTUnwrap(self.child(model, task: started["taskId"]))
        let folder = try XCTUnwrap(child.workspacePath)
        XCTAssertTrue(folder.hasPrefix(model.worktreesDirectory.path), folder)
        XCTAssertTrue(folder.hasSuffix("/app"), "The parent's subfolder inside the worktree")
        XCTAssertEqual(try String(contentsOfFile: folder + "/README.md", encoding: .utf8), "committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/draft.txt"), "Uncommitted edits stay out")
        let branch = try WorkspaceChanges.run(["rev-parse", "--abbrev-ref", "HEAD"], at: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(branch.hasPrefix("notch/risky-approach-"), branch)
        XCTAssertEqual(transport.calls.last { $0.0 == "session.create" }?.1["cwd"] as? String, folder)
        await model.newSession(showPanel: false, runtime: .codex, workspace: FileManager.default.temporaryDirectory.path)
        let plainID = try XCTUnwrap(model.currentID)
        model.draft = "Outside Git"
        await model.send()
        do {
            _ = try await model.handleDelegationTool(DelegationCaller(sessionID: plainID, runtime: .codex, subagent: false), name: "delegate_task",
                                                     arguments: ["task": "x", "isolation": "worktree"])
            XCTFail("A worktree needs a repository")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "invalid_request") }
    }

    func testAChildsOwnChangesJoinTheTurnThatDelegatedItOnce() async throws {
        let (model, _, _, _) = makeModel()
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("notch-child-changes-\(UUID().uuidString)")
        folders.append(repository)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func write(_ text: String, _ path: String, in folder: String? = nil) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: folder ?? repository.path).appendingPathComponent(path))
        }
        try write("one\n", "app.txt")
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "Initial"]] {
            _ = try WorkspaceChanges.run(arguments, at: repository.path)
        }
        try write("mine\n", "draft.txt") // the user's own uncommitted edit
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex, workspace: repository.path)
        let parentID = try XCTUnwrap(model.currentID)
        model.draft = "Split the work"
        await model.send()
        let caller = DelegationCaller(sessionID: parentID, runtime: .codex, subagent: false)
        func turn() -> TurnChanges? { model.sessions.first { $0.id == parentID }?.changes.first }

        let risky = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Try it", "isolation": "worktree", "title": "Risky approach"])
        let isolated = try XCTUnwrap(child(model, task: risky["taskId"]))
        try write("two\n", "app.txt", in: isolated.workspacePath)
        finish(model, isolated.id, text: "Tried it.")
        await eventually { turn()?.delegated?.count == 1 }
        XCTAssertEqual(turn()?.delegated?.first?.label, "Risky approach · Codex · worktree")
        XCTAssertEqual(turn()?.delegated?.first?.files.map(\.path), ["app.txt"], "From the worktree's own capture")
        XCTAssertTrue(turn()?.isVisible == true, "Shown before the parent's own capture")
        _ = try await model.handleDelegationTool(caller, name: "task_status", arguments: ["taskId": risky["taskId"]!])

        async let waited = model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Add notes", "mode": "wait", "title": "Notes"])
        await eventually { model.delegationWaits[parentID] == 1 }
        let shared = try XCTUnwrap(model.sessions.first { $0.parentSessionID == parentID && $0.title == "Notes" })
        try write("notes\n", "notes.txt")
        finish(model, shared.id, text: "Added notes.")
        _ = try await waited
        await eventually { turn()?.delegated?.count == 2 }
        XCTAssertEqual(turn()?.delegated?.last?.files.map(\.path), ["notes.txt"], "The user's draft is not the child's")

        finish(model, parentID, text: "Both done.")
        await eventually { turn()?.capturedAt != nil }
        let summary = try XCTUnwrap(turn())
        XCTAssertEqual(summary.files.map(\.path), ["draft.txt", "notes.txt"], "The shared folder's capture holds the child's edit too")
        XCTAssertEqual(summary.ownFiles.map(\.path), ["draft.txt"])
        XCTAssertEqual(summary.allFiles.map(\.path), ["draft.txt", "app.txt", "notes.txt"], "Each file once, under its child")
    }

    // MARK: Review regressions

    func testAWakeThatLosesARaceToAQueuedSendIsDeliveredAfterIt() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let queued = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": parentID, "message": "Note to self"])
        XCTAssertEqual(queued["delivery"] as? String, "queued")
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Look"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "Child result.")
        finish(model, parentID, text: "Turn one.")
        await eventually { transport.prompts(parentID).contains("Note to self") }
        finish(model, parentID, text: "Turn two.")
        await eventually { transport.prompts(parentID).contains { $0.contains("Child result.") } }
        XCTAssertEqual(transport.prompts(parentID).count, 3, "The first send, the queued note, then the wake")
    }

    func testAChildThatNeverGotItsTaskDoesNotKeepItsParentWorking() async throws {
        let (model, _, storage, defaults) = makeModel()
        await model.newSession(showPanel: false, runtime: .pi)
        let parentID = try XCTUnwrap(model.currentID)
        var orphan = CompanionSession()
        orphan.runtime = .pi
        orphan.parentSessionID = parentID
        orphan.delegation = DelegationRecord(taskID: "lost")
        model.sessions.append(orphan)
        model.update(parentID) { $0.agents = [ChildAgent(id: "delegation:lost", title: "Lost", state: .working, sessionID: orphan.id, runtime: .pi)] }
        model.save()
        model.shutdown()
        let (restarted, _, _, _) = makeModel(storage: storage, preferences: defaults)
        XCTAssertEqual(restarted.sessions.first { $0.id == parentID }?.agents.first?.state, .interrupted)
        XCTAssertFalse(restarted.sessions.first { $0.id == parentID }!.isBusy)
        XCTAssertFalse(restarted.hasActiveWork)
    }

    func testARefusedQueuedSendIsNotRetriedOnEveryEvent() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        _ = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": parentID, "message": "Later"])
        transport.rejectSubmits = ["rt-" + parentID]
        finish(model, parentID, text: "Done.")
        await eventually { model.failedDeliveries.count == 1 }
        let attempts = transport.count("prompt.submit")
        for _ in 0..<5 { model.receive("session.info", payload: ["session_id": "rt-" + parentID]) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.count("prompt.submit"), attempts, "Kept for a later run instead")
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.queuedSends.count, 1, "Not dropped")
    }

    func testARefusedSteerIsQueuedAfterTheTurnAndNotRetriedPerEvent() async throws {
        let (model, transport, _, _) = makeModel()
        transport.steerFails = true
        let (parentID, caller) = try await activeParent(model)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Side job"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "Side result.")
        await eventually { transport.count("prompt.steer") == 1 && model.steerRefused.contains(parentID) }
        for _ in 0..<5 { model.receive("message.delta", payload: ["session_id": "rt-" + parentID, "text": "."]) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.count("prompt.steer"), 1, "A refused steer is not retried on every delta")
        finish(model, parentID, text: "Done.")
        await eventually { transport.prompts(parentID).last?.contains("Side result.") == true }
    }

    func testAFailedSendToAFinishedChildDoesNotReplayItsOldResult() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Look"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        finish(model, childID, text: "Old result.")
        _ = try await model.handleDelegationTool(caller, name: "task_status", arguments: ["taskId": started["taskId"]!])
        do {
            _ = try await model.handleDelegationTool(caller, name: "notch_session_send", arguments: ["sessionId": childID, "message": "More", "mode": "steer"])
            XCTFail("Pi has no running turn to steer")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "thread_not_sendable") }
        XCTAssertEqual(model.sessions.first { $0.id == childID }?.delegation?.taskID, started["taskId"] as? String, "The task is unchanged")
        finish(model, parentID, text: "Done.")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.prompts(parentID).count, 1, "The read result does not wake again")
    }

    func testAFailedLaunchGivesTheNextLaunchTheTools() async throws {
        let (model, transport, _, _) = makeModel()
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex)
        let id = try XCTUnwrap(model.currentID)
        transport.failNextCreate = true
        model.draft = "First try"
        await model.send()
        XCTAssertFalse(model.delegationServer.hasGrant(sessionID: id), "The failed launch's token is revoked")
        model.draft = "Second try"
        await model.send()
        XCTAssertEqual(transport.calls.filter { $0.0 == "session.create" }.compactMap { $0.1["delegation"] }.count, 2)
    }

    func testAHermesSessionReplacedAfterAMissingUnusedIDStillGetsTheTools() async throws {
        let (model, transport, _, _) = makeModel(preferences: preferences(ready: [.hermes, .codex]))
        await model.connect()
        await model.newSession(showPanel: false, runtime: .hermes)
        let id = try XCTUnwrap(model.currentID)
        model.update(id) { $0.storedID = "vanished-before-first-prompt" }
        transport.nextResumeError = HermesClientError.rpc(4007, "session not found")
        model.draft = "Plan the release"
        await model.send()
        let opens = transport.calls.filter { ["session.resume", "session.create"].contains($0.0) }
        XCTAssertEqual(opens.map(\.0), ["session.resume", "session.create"])
        XCTAssertNotNil(opens.last?.1["delegation"], "The replacement session gets the tools with a fresh token")
        XCTAssertTrue(model.delegationServer.hasGrant(sessionID: id))
    }

    func testStopWhileAChildIsStartingKeepsItFromStarting() async throws {
        let (model, transport, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model)
        transport.createDelay = .milliseconds(300)
        let delegated = Task { try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Slow start"]) }
        await eventually { model.sessions.contains { $0.parentSessionID == parentID } }
        let childID = try XCTUnwrap(model.sessions.first { $0.parentSessionID == parentID }).id
        await model.interrupt(sessionID: parentID)
        _ = try? await delegated.value
        XCTAssertTrue(transport.prompts(childID).isEmpty, "The cancelled task was never sent")
        XCTAssertEqual(model.taskResult(childID)["status"] as? String, "cancelled")
        XCTAssertNotEqual(model.sessions.first { $0.id == parentID }?.displayState, .failed, "Stop is not a failure")
        XCTAssertFalse(model.sessions.first { $0.id == parentID }!.isBusy)
    }

    func testAWorktreeIsNotCreatedForARequestThatFailsValidation() async throws {
        let (model, _, _, _) = makeModel()
        let (_, caller) = try await activeParent(model)
        do {
            _ = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "x", "isolation": "worktree", "target": ["model": "missing"]])
            XCTFail("The model is unavailable")
        } catch let failure as DelegationFailure { XCTAssertEqual(failure.code, "model_unavailable") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.worktreesDirectory.path), "Nothing was checked out")
    }

    func testAnACPReloadKeepsTheBridgeItWasOpenedWith() async throws {
        for runtime in [RuntimeKind.opencode, .cursor] { try await checkACPReloadKeepsTheBridge(runtime) }
    }

    private func checkACPReloadKeepsTheBridge(_ runtime: RuntimeKind) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-acp-delegation-\(UUID().uuidString)")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("acp-peer")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        log = os.path.join(os.path.dirname(sys.argv[0]), "wire.jsonl")
        for line in sys.stdin:
            frame = json.loads(line)
            method, wire = frame.get("method"), frame.get("id")
            with open(log, "a") as f: f.write(json.dumps(frame) + chr(10))
            result = {}
            if method == "initialize": result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}
            if method == "session/new": result = {"sessionId": "acp-session"}
            if wire is not None: print(json.dumps({"jsonrpc": "2.0", "id": wire, "result": result}), flush=True)
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ACPRuntimeClient(runtime: runtime, profileID: folder.path, executableOverride: executable)
        defer { client.disconnect() }
        try await client.connect()
        let delegation: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "tok", "bridge": "/bin/bridge"]
        let sid = try await client.request("session.create", params: ["cwd": folder.path, "delegation": delegation])["session_id"] as! String
        _ = try await client.request("session.resume", params: ["cwd": folder.path, "session_id": sid])
        let rows = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let servers = rows.filter { ["session/new", "session/load"].contains($0["method"] as? String) }
            .map { (($0["params"] as? [String: Any])?["mcpServers"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertEqual(servers, ["/bin/bridge", "/bin/bridge"], "\(runtime.title): Check last send reloads with the same bridge")
    }

    func testAClientThatClosesCancelsItsBlockingToolCall() async throws {
        let server = DelegationServer()
        defer { server.stop() }
        server.tools = { _ in Delegation.tools }
        var cancelled = false
        server.call = { _, _, _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            cancelled = true
            return [:]
        }
        let url = try await server.start()
        var request = URLRequest(url: url, timeoutInterval: 0.5)
        request.httpMethod = "POST"
        request.setValue("Bearer " + server.issueToken(for: DelegationCaller(sessionID: "s", runtime: .codex, subagent: false)), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "task_status", "arguments": [:]]])
        _ = try? await URLSession.shared.data(for: request)
        await eventually { cancelled }
    }

    func testASessionWaitOnAChildStillQueuesItsQuestionNotice() async throws {
        let (model, _, _, _) = makeModel()
        let (parentID, caller) = try await activeParent(model, runtime: .pi)
        let started = try await model.handleDelegationTool(caller, name: "delegate_task", arguments: ["task": "Ask"])
        let childID = try XCTUnwrap(child(model, task: started["taskId"])).id
        let waiting = Task { try await model.handleDelegationTool(caller, name: "notch_session_wait", arguments: ["sessionId": childID, "timeoutMs": 2000]) }
        await eventually { model.delegationWaits[parentID] == 1 }
        model.receive("clarify.request", payload: ["session_id": "rt-" + childID, "request_id": "q1", "question": "Which?"])
        XCTAssertEqual(model.sessions.first { $0.id == parentID }?.queuedSends.count, 1, "This wait does not return the question, so the notice stays")
        waiting.cancel()
        _ = try? await waiting.value
    }

    // MARK: Server

    func testServerRequiresAValidTokenAndAnswersMCP() async throws {
        let server = DelegationServer()
        var calls: [(DelegationCaller, String)] = []
        server.tools = { _ in Delegation.tools }
        server.instructions = "Use the notch tools."
        server.call = { caller, name, _ in calls.append((caller, name)); return ["ok": true] }
        func post(_ body: [String: Any], token: String?) async -> DelegationServer.Response {
            await server.respond(method: "POST", path: "/mcp", headers: token.map { ["Authorization": "Bearer " + $0] } ?? [:],
                                 body: try! JSONSerialization.data(withJSONObject: body))
        }
        let ping: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        let none = await post(ping, token: nil)
        XCTAssertEqual(none.status, 401)
        XCTAssertEqual(none.headers["WWW-Authenticate"], "Bearer")
        let wrong = await post(ping, token: "guess")
        XCTAssertEqual(wrong.status, 401)
        let child = DelegationCaller(sessionID: "child", runtime: .claude, subagent: true)
        let token = server.issueToken(for: child)
        XCTAssertGreaterThanOrEqual(token.count, 43, "32 random bytes")
        let initialized = await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], token: token)
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: initialized.body) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(result["instructions"] as? String, "Use the notch tools.")
        let notified = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token)
        XCTAssertEqual(notified.status, 202)
        let listed = await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: token)
        let tools = ((try JSONSerialization.jsonObject(with: listed.body) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertTrue(tools?.contains { $0["name"] as? String == "delegate_task" } == true, "A child token lists delegate_task")
        let called = await post(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "task_status", "arguments": ["taskId": "x"]]], token: token)
        let content = ((try JSONSerialization.jsonObject(with: called.body) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(content?["isError"] as? Bool, false)
        XCTAssertEqual(calls.first?.0, child)
        let stream = await server.respond(method: "GET", path: "/mcp", headers: ["Authorization": "Bearer " + token], body: Data())
        XCTAssertEqual(stream.status, 405, "No server-initiated stream")
        server.call = { _, _, _ in throw DelegationFailure("task_not_found", "No such task.") }
        let failed = await post(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "task_status", "arguments": [:]]], token: token)
        let failure = (try JSONSerialization.jsonObject(with: failed.body) as? [String: Any])?["result"] as? [String: Any]
        XCTAssertEqual(failure?["isError"] as? Bool, true)
        XCTAssertTrue(((failure?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("task_not_found") == true)
    }

    func testTokensExpireAfterADayIdleUnlessRunningAndAreRevokedOnRelease() {
        let server = DelegationServer()
        var clock = Date()
        server.now = { clock }
        var running = false
        server.isActive = { _ in running }
        let caller = DelegationCaller(sessionID: "s", runtime: .codex, subagent: false)
        let token = server.issueToken(for: caller)
        XCTAssertEqual(server.caller(token: token), caller)
        clock.addTimeInterval(DelegationServer.idleExpiry + 1)
        running = true
        XCTAssertEqual(server.caller(token: token), caller, "A running turn keeps its token")
        clock.addTimeInterval(DelegationServer.idleExpiry + 1)
        running = false
        XCTAssertNil(server.caller(token: token), "Expired after 24 h idle")
        let next = server.issueToken(for: caller)
        let replaced = server.issueToken(for: caller)
        XCTAssertNil(server.caller(token: next), "One token per session")
        server.revoke(sessionID: "s")
        XCTAssertNil(server.caller(token: replaced), "Revoked on release")
    }

    func testServerListensOnLoopbackAndParsesHTTP() async throws {
        let server = DelegationServer()
        defer { server.stop() }
        server.tools = { _ in Delegation.tools }
        let url = try await server.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/mcp")
        let token = server.issueToken(for: DelegationCaller(sessionID: "s", runtime: .codex, subagent: false))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/list"])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int, 7)
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(DelegationServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)), .incomplete)
        XCTAssertEqual(DelegationServer.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .invalid(411))
    }

    // MARK: Injection

    func testClaudeGetsTheServerOverStdinAndKeepsTheUsersOwnMCP() throws {
        let id = UUID().uuidString.lowercased()
        let delegation: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "secret-token", "instructions": "x", "read_only_tools": [String]()]
        let args = try ClaudeClient.arguments(id: id, resume: false, delegation: delegation)
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "mcp__notch__*"])
        XCTAssertFalse(args.contains { $0.contains("secret-token") }, "The token never goes into argv")
        XCTAssertFalse(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--mcp-config"))
        var planned = delegation; planned["read_only_tools"] = Delegation.readOnlyTools
        XCTAssertEqual(try ClaudeClient.arguments(id: id, resume: true, delegation: planned).last,
                       "mcp__notch__orchestrator_capabilities,mcp__notch__notch_session_list,mcp__notch__notch_session_wait,mcp__notch__pending_request_list,mcp__notch__pending_request_read",
                       "Plan pre-allows only T3's read-only tools")
        XCTAssertFalse(try ClaudeClient.arguments(id: id, resume: true).contains("--allowedTools"))
        let server = try XCTUnwrap(ClaudeClient.delegationServers(delegation)["notch"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "http")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer secret-token")
        XCTAssertEqual(server["timeout"] as? Int, 65 * 60 * 1000)
    }

    func testClaudeSessionAppendsInstructionsAndAddsTheServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-delegation-\(UUID().uuidString)")
        folders.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("claude")
        let wire = directory.appendingPathComponent("wire.jsonl")
        try Data(#"""
        #!/usr/bin/env python3
        import json, sys, os
        wire = os.path.join(os.path.dirname(sys.argv[0]), 'wire.jsonl')
        with open(wire, 'a') as f: f.write(json.dumps({'argv': sys.argv[1:]}) + '\n')
        for line in sys.stdin:
            frame = json.loads(line)
            with open(wire, 'a') as f: f.write(json.dumps(frame) + '\n')
            if frame['type'] == 'control_request':
                kind = frame['request']['subtype']
                body = {'models': [{'value': 'default', 'resolvedModel': 'fixture'}], 'session_state': 'idle'} if kind == 'initialize' else {'added': ['notch'], 'removed': [], 'errors': {}}
                print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': body}}), flush=True)
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        _ = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true,
            "delegation": ["url": "http://127.0.0.1:9/mcp", "token": "tok", "instructions": "Delegation rules.", "read_only_tools": [String]()]])
        let frames = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let requests = frames.compactMap { $0["request"] as? [String: Any] }
        XCTAssertEqual(requests.map { $0["subtype"] as? String }, ["initialize", "mcp_set_servers"])
        XCTAssertEqual(requests[0]["appendSystemPrompt"] as? String, "Delegation rules.", "Appended, never replacing the profile's prompt")
        let servers = try XCTUnwrap(requests[1]["servers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["notch"], "Only the companion's server; the user's MCP config stays")
        XCTAssertFalse((frames[0]["argv"] as? [String] ?? []).contains { $0.contains("tok") }, "The token stays out of argv")
    }

    func testACPAndPiGetTheServerThroughTheirOwnLaunchOptions() throws {
        let delegation: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "tok", "bridge": "/Applications/Notch Companion.app/Contents/MacOS/NotchCompanion"]
        let servers = ACPRuntimeClient.mcpServers(delegation)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0]["name"] as? String, "notch")
        XCTAssertEqual(servers[0]["command"] as? String, delegation["bridge"] as? String)
        XCTAssertEqual(servers[0]["args"] as? [String], [DelegationBridge.flag])
        XCTAssertEqual(servers[0]["env"] as? [[String: String]], [["name": DelegationBridge.urlKey, "value": "http://127.0.0.1:9/mcp"],
                                                                   ["name": DelegationBridge.tokenKey, "value": "tok"]])
        XCTAssertTrue(ACPRuntimeClient.mcpServers(nil).isEmpty, "Without delegation the session gets no servers from the companion")
        var environment = ["PATH": "/usr/bin"]
        let arguments = PiClient.delegationArguments(delegation, environment: &environment)
        XCTAssertEqual(arguments.first, "--extension")
        XCTAssertTrue(arguments.last?.hasSuffix("pi_delegation.mjs") == true)
        XCTAssertEqual(environment[DelegationBridge.tokenKey], "tok", "Process-only: nothing is written to the Pi home")
        var untouched = ["PATH": "/usr/bin"]
        XCTAssertTrue(PiClient.delegationArguments(nil, environment: &untouched).isEmpty)
        XCTAssertEqual(untouched, ["PATH": "/usr/bin"])
        XCTAssertEqual(RuntimeKind.allCases.filter(\.hostsDelegation), RuntimeKind.allCases, "Every harness hosts delegation")
    }

    func testTheStdioBridgeRelaysEachLineWithTheSessionToken() async throws {
        let binary = ProcessInfo.processInfo.environment["NOTCH_TEST_APP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/NotchCompanion")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build the app product first.") }
        let server = DelegationServer()
        defer { server.stop() }
        server.tools = { _ in Delegation.tools }
        server.instructions = "Bridge instructions."
        var calls: [DelegationCaller] = []
        server.call = { caller, _, _ in calls.append(caller); return ["bridged": true] }
        let url = try await server.start()
        let caller = DelegationCaller(sessionID: "acp", runtime: .deepseek, subagent: false)
        func relay(_ lines: [String], token: String) async throws -> [[String: Any]] {
            let process = Process()
            process.executableURL = binary
            process.arguments = [DelegationBridge.flag]
            process.environment = [DelegationBridge.urlKey: url.absoluteString, DelegationBridge.tokenKey: token]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try input.fileHandleForWriting.close()
            let data = await reader.value
            await withCheckedContinuation { done in DispatchQueue.global().async { process.waitUntilExit(); done.resume() } }
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let replies = try await relay([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_status","arguments":{"taskId":"t"}}}"#
        ], token: server.issueToken(for: caller))
        XCTAssertEqual(Set(replies.compactMap { $0["id"] as? Int }), [1, 2], "A notification gets no line")
        XCTAssertEqual(((replies.first { $0["id"] as? Int == 1 }?["result"]) as? [String: Any])?["instructions"] as? String, "Bridge instructions.")
        XCTAssertEqual(calls, [caller], "The call carries that session's token")
        let denied = try await relay([#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#], token: "revoked")
        XCTAssertEqual((denied.first?["error"] as? [String: Any])?["code"] as? Int, -32000)
    }

    func testThePiExtensionRegistersTheToolsAndAppendsInstructions() async throws {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Node on PATH is needed to load the Pi extension.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NotchCompanion/Resources/pi_delegation.mjs")
        let server = DelegationServer()
        defer { server.stop() }
        server.tools = { _ in Delegation.tools }
        server.instructions = "Pi instructions."
        server.call = { _, name, arguments in ["tool": name, "taskId": arguments["taskId"] ?? ""] }
        let url = try await server.start()
        let token = server.issueToken(for: DelegationCaller(sessionID: "pi", runtime: .pi, subagent: false))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-pi-extension-\(UUID().uuidString)")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let driver = folder.appendingPathComponent("driver.mjs")
        try Data("""
        const [extensionPath, url, token] = process.argv.slice(2);
        process.env.NOTCH_DELEGATION_URL = url; process.env.NOTCH_DELEGATION_TOKEN = token;
        const registered = []; const handlers = {};
        const { default: load } = await import(extensionPath);
        await load({ registerTool: (tool) => registered.push(tool), on: (name, handler) => { handlers[name] = handler; } });
        const status = await registered.find((tool) => tool.name === "mcp__notch__task_status").execute("1", { taskId: "t1" });
        const prompt = handlers.before_agent_start({ systemPrompt: "BASE" });
        console.log(JSON.stringify({ names: registered.map((tool) => tool.name), status, prompt, token: process.env.NOTCH_DELEGATION_TOKEN ?? null }));
        """.utf8).write(to: driver)
        let process = Process()
        process.executableURL = node
        process.arguments = [driver.path, source.path, url.absoluteString, token]
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        try process.run()
        let data = await reader.value
        await withCheckedContinuation { done in DispatchQueue.global().async { process.waitUntilExit(); done.resume() } }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
        XCTAssertEqual(Set(result["names"] as? [String] ?? []), Set(Delegation.tools.compactMap { ($0["name"] as? String).map { "mcp__notch__" + $0 } }))
        let text = (((result["status"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("t1") && text.contains("task_status"), text)
        XCTAssertEqual((result["prompt"] as? [String: Any])?["systemPrompt"] as? String, "BASE\n\nPi instructions.", "Appended, never replacing Pi's prompt")
        XCTAssertTrue(result["token"] is NSNull, "The token is cleared before the agent runs commands")
    }

    /// The lines SharedHermesClient writes, read by the bundled launcher against
    /// stand-ins for Hermes's registry and session map, calling the real server.
    func testTheHermesLauncherRegistersTheToolsAndCallsAsTheBoundSession() async throws {
        let candidates = ["/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let python = candidates.map({ URL(fileURLWithPath: $0).appendingPathComponent("python3") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("python3 is needed to load the Hermes launcher.") }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NotchCompanion/Resources/hermes_frontend.py")
        let server = DelegationServer()
        defer { server.stop() }
        server.tools = { _ in Delegation.tools }
        var callers: [DelegationCaller] = []
        server.call = { caller, name, arguments in callers.append(caller); return ["tool": name, "taskId": arguments["taskId"] ?? ""] }
        let url = try await server.start()
        let token = server.issueToken(for: DelegationCaller(sessionID: "hermes-parent", runtime: .hermes, subagent: false))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hermes-launcher-\(UUID().uuidString)")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let driver = folder.appendingPathComponent("driver.py")
        try Data("""
        import importlib.util, json, sys, threading
        from types import ModuleType, SimpleNamespace
        spec = importlib.util.spec_from_file_location("frontend", sys.argv[1])
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        class Registry:
            entries = {}
            def register(self, name, toolset, schema, handler, check_fn=None, execution_timeout=None):
                self.entries[name] = SimpleNamespace(toolset=toolset, handler=handler, execution_timeout=execution_timeout)
            def get_entry(self, name): return self.entries.get(name)
        registry = ModuleType("tools.registry"); registry.registry = Registry()
        server = ModuleType("tui_gateway.server")
        server._sessions = {"live-1": {"session_key": "stored-1", "agent": None}}
        server._sessions_lock = threading.RLock()
        server._load_enabled_toolsets = lambda platform=None: ["file"]
        agent = ModuleType("agent"); agent.prompt_builder = ModuleType("agent.prompt_builder"); agent.prompt_builder.PLATFORM_HINTS = {}
        sys.modules.update({"tools.registry": registry, "tui_gateway.server": server, "agent": agent,
                            "agent.prompt_builder": agent.prompt_builder, "tools.interrupt": None})
        reports = []
        delegation = frontend.NotchDelegation(report=reports.append)
        frontend.os.kill = lambda *_: None  # the scripted pipe's EOF must not stop this driver
        frontend.watch_parent(None, delegation.receive)
        entries = registry.registry.entries
        status = entries["mcp__notch__task_status"].handler({"taskId": "t1"}, session_id="stored-1")
        print(json.dumps({"reports": reports, "names": sorted(entries), "toolsets": server._load_enabled_toolsets(),
                          "timeouts": sorted({entry.execution_timeout for entry in entries.values()}),
                          "hint": agent.prompt_builder.PLATFORM_HINTS.get("notch_companion", ""), "status": status}))
        """.utf8).write(to: driver)
        var pipe = Data()
        for message in [SharedHermesClient.toolsMessage,
                        SharedHermesClient.bindMessage(session: "live-1", delegation: ["url": url.absoluteString, "token": token])] {
            pipe += try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-B", driver.path, source.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: pipe)
        try input.fileHandleForWriting.close()
        let data = await reader.value
        await withCheckedContinuation { done in DispatchQueue.global().async { process.waitUntilExit(); done.resume() } }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
        let reports = try XCTUnwrap(result["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(SharedHermesClient.delegationFailure(reports[0]), "The launcher confirms the tools before any session opens")
        XCTAssertEqual(result["names"] as? [String], Delegation.tools.compactMap { ($0["name"] as? String).map { "mcp__notch__" + $0 } }.sorted())
        XCTAssertEqual(result["toolsets"] as? [String], ["file", "notch"], "An explicit toolset selection gains only the notch toolset")
        XCTAssertEqual(result["timeouts"] as? [Int], [3900], "Hour-long waits are not cut by Hermes's tool executor")
        XCTAssertTrue((result["hint"] as? String ?? "").hasSuffix(Delegation.instructions))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((result["status"] as? String ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(status["taskId"] as? String, "t1")
        XCTAssertEqual(status["tool"] as? String, "task_status")
        XCTAssertEqual(callers, [DelegationCaller(sessionID: "hermes-parent", runtime: .hermes, subagent: false)], "The call ran as the bound session")
        XCTAssertNotNil(SharedHermesClient.delegationFailure(["ready": false]), "A refusal becomes the session's notice")
    }

    func testCodexThreadsGetOnlyTheirOwnServerAndInstructionsOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-codex-delegation-\(UUID().uuidString)")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("codex-peer")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            frame = json.loads(line)
            if "id" not in frame: continue
            method, params = frame["method"], frame.get("params", {})
            with open(os.path.join(os.environ["CODEX_HOME"], "wire.jsonl"), "a") as f:
                f.write(json.dumps({"method": method, "params": params}) + "\n")
            result = {}
            if method in ("thread/start", "thread/resume"):
                result = {"thread": {"id": params.get("threadId", "thread")}, "model": "m"}
            if method == "turn/start":
                result = {"turn": {"id": "turn-" + str(frame["id"]), "status": "inProgress"}}
            if method == "turn/steer":
                result = {"turnId": params["expectedTurnId"]}
            print(json.dumps({"id": frame["id"], "result": result}), flush=True)
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexClient(profileID: folder.path, executable: executable)
        defer { client.disconnect() }
        try await client.connect()
        let delegation: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "tok", "instructions": "Delegation rules."]
        let sid = try await client.request("session.create", params: ["delegation": delegation])["session_id"] as! String
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "one"])
        let image = folder.appendingPathComponent("steering.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN2kAAAAASUVORK5CYII=")!.write(to: image)
        _ = try await client.request("prompt.steer", params: ["session_id": sid, "text": "result", "turn_id": "wake", "images": [image.path]])
        let rows = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let start = try XCTUnwrap(rows.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        let config = try XCTUnwrap(start["config"] as? [String: Any])
        XCTAssertEqual(Array(config.keys), ["mcp_servers.notch"], "Overrides only the companion's server, so the user's servers stay")
        let server = try XCTUnwrap(config["mcp_servers.notch"] as? [String: Any])
        XCTAssertEqual((server["http_headers"] as? [String: String])?["Authorization"], "Bearer tok")
        XCTAssertEqual(server["tool_timeout_sec"] as? Int, 3900)
        XCTAssertNil(start["developerInstructions"], "The profile's own instructions are not replaced")
        let turn = try XCTUnwrap(rows.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        let context = (turn["additionalContext"] as? [String: Any])?["notch_delegation"] as? [String: Any]
        XCTAssertEqual(context?["kind"] as? String, "application")
        XCTAssertEqual(context?["value"] as? String, "Delegation rules.")
        let steer = try XCTUnwrap(rows.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any])
        XCTAssertTrue((steer["expectedTurnId"] as? String)?.hasPrefix("turn-") == true, "Steers only the running turn")
        XCTAssertEqual(((steer["input"] as? [[String: Any]])?.first?["text"]) as? String, "result")
        XCTAssertEqual(((steer["input"] as? [[String: Any]])?.last?["type"]) as? String, "localImage")
        XCTAssertEqual(((steer["input"] as? [[String: Any]])?.last?["path"]) as? String, image.path)
    }
}
