// Account-backed regression for the user's explicitly reported read-only capture.
import Foundation

enum CompanionResources {
    static var bundle: Bundle { Bundle(path: ProcessInfo.processInfo.environment["NOTCH_SMOKE_RESOURCES"]!)! }
}

@main struct ComputerUseSmoke {
    @MainActor static func main() async {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var evidence: [String: Any] = [:]
        let client = SharedHermesClient()
        var events: [(String, [String: Any])] = []
        var liveID: String?
        client.onEvent = { events.append(($0, $1)) }
        do {
            try await client.connect()
            let created = try await client.request("session.create", params: ["title": "Notch Companion computer-use capture verification"])
            guard let sid = created["session_id"] as? String else { throw HermesClientError.unavailable("No verification session") }
            liveID = sid
            evidence["native_session_id"] = created["stored_session_id"]
            let env = ProcessInfo.processInfo.environment
            let target = (env["NOTCH_CUA_TEST_PID"].flatMap(Int.init)).flatMap { pid in
                env["NOTCH_CUA_TEST_WINDOW_ID"].flatMap(Int.init).map { " Include the explicit target pid=\(pid), window_id=\($0); keep app=Google Chrome and mode=ax." }
            } ?? ""
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "surface": "hud", "text": "This is a user-requested regression check for Notch Companion computer-use. Call computer_use exactly once with action=capture, app=Google Chrome, mode=ax. Read-only inspection only: do not click, type, focus, navigate, change settings, edit files, or update memory. You may read the computer-use tool description or its required skill; do not invoke unrelated tools. Reply CUA_CAPTURE_OK if it returns usable accessibility state; otherwise reply CUA_CAPTURE_FAILED. Do not repeat any window or page content." + target])
            let deadline = Date().addingTimeInterval(150)
            while !events.contains(where: { $0.0 == "message.complete" }) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let result = events.last(where: { $0.0 == "message.complete" })?.1
            evidence["turn_completed"] = result?["status"] as? String == "complete"
            evidence["capture_reported_success"] = (result?["text"] as? String)?.contains("CUA_CAPTURE_OK") == true
            let tools = events.filter { $0.0 == "tool.start" }
            evidence["computer_use_called"] = tools.contains { $0.1["name"] as? String == "computer_use" }
            evidence["tool_names"] = tools.compactMap { $0.1["name"] as? String }
            evidence["only_requested_tool_called"] = !tools.isEmpty && tools.allSatisfy { ["computer_use", "tool_describe", "tool_call", "skill_view"].contains($0.1["name"] as? String ?? "") }
            evidence["tool_completed"] = events.contains { $0.0 == "tool.complete" && $0.1["name"] as? String == "computer_use" }
            let toolResults = events.filter { $0.0 == "tool.complete" }.map { String(describing: $0.1["result"] ?? "") }.joined()
            evidence["no_daemon_startup_timeout"] = !toolResults.contains("daemon did not become ready") && !toolResults.contains("embedded cua-driver startup timed out")
            evidence["capture_scope"] = "Actual production Hermes adapter; user-requested Chrome AX capture; no clicks or separate screenshot commands; no production app relaunch"
            if result == nil { _ = try? await client.request("session.interrupt", params: ["session_id": sid]) }
            _ = try await client.request("session.close", params: ["session_id": sid])
            liveID = nil
        } catch {
            evidence["verification_failed"] = true
            if let liveID { _ = try? await client.request("session.close", params: ["session_id": liveID]) }
        }
        client.disconnect()
        try? await Task.sleep(for: .seconds(3))
        try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
