// Standalone verification executable. Compile alongside the production
// SharedHermesClient, HermesClient and HermesTransport sources.
import Foundation

enum CompanionResources {
    static var bundle: Bundle { Bundle(path: ProcessInfo.processInfo.environment["NOTCH_SMOKE_RESOURCES"]!)! }
}

@main
struct SharedHermesSmoke {
    @MainActor
    static func main() async {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var report: [String: Any] = [:]
        let client = SharedHermesClient()
        var events: [(String, [String: Any])] = []
        client.onEvent = { name, payload in events.append((name, payload)) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hermes-adapter-\(UUID().uuidString)")
        var liveID: String?
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let marker = "notchadapter" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try await client.connect()
            report["authenticated_ws_connected"] = true
            let created = try await client.request("session.create", params: ["title": "Notch Companion implemented Hermes adapter validation", "cwd": temp.path])
            guard let sid = created["session_id"] as? String, let stored = created["stored_session_id"] as? String else { throw SmokeError.failed("session identity") }
            liveID = sid
            report["session_id"] = stored
            let attachment = temp.appendingPathComponent("adapter-fixture.txt")
            try marker.write(to: attachment, atomically: true, encoding: .utf8)
            let attached = try await client.request("file.attach", params: ["session_id": sid, "path": attachment.path])
            report["file_attachment_staged"] = attached["attached"] as? Bool == true
            let image = temp.appendingPathComponent("adapter-pixel.png")
            try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l2kAAAAASUVORK5CYII=")!.write(to: image)
            let imageAttachment = try await client.request("image.attach", params: ["session_id": sid, "path": image.path])
            let imagePath = imageAttachment["path"] as? String ?? image.path
            let detached = try await client.request("image.detach", params: ["session_id": sid, "path": imagePath])
            report["image_detached_without_submit"] = (detached["count"] as? Int) == 0 && !events.contains { $0.0 == "message.start" }
            let start = events.count
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "User-requested integration verification: read only the attached adapter-fixture.txt using a file-reading tool, then reply with its exact contents and nothing else. Do not write files or memory or run other tools.\n\n" + (attached["ref_text"] as? String ?? ""), "surface": "hud"])
            let completion = try await waitFor("message.complete", session: sid, after: start, events: { events })
            report["prompt_completed"] = completion["status"] as? String == "complete"
            report["attachment_contents_read"] = (completion["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == marker
            report["streaming_received"] = events.dropFirst(start).contains { $0.0 == "message.delta" }
            report["tool_start_received"] = events.dropFirst(start).contains { $0.0 == "tool.start" }
            report["tool_complete_received"] = events.dropFirst(start).contains { $0.0 == "tool.complete" }
            _ = try await client.request("session.close", params: ["session_id": sid])
            liveID = nil
            client.disconnect()
            try await Task.sleep(for: .seconds(1))
            try await client.connect()
            let resumed = try await client.request("session.resume", params: ["session_id": stored])
            liveID = resumed["session_id"] as? String
            report["resume_after_frontend_restart"] = liveID != nil
            let messages = resumed["messages"] as? [[String: Any]] ?? []
            report["resumed_history_contains_response"] = messages.contains { ($0["text"] as? String ?? $0["content"] as? String ?? "").contains(marker) }
            if let liveID { _ = try await client.request("session.close", params: ["session_id": liveID]) }
            report["closed_native_session"] = true
        } catch {
            report["error"] = error.localizedDescription
            if let liveID { _ = try? await client.request("session.close", params: ["session_id": liveID]) }
        }
        client.disconnect()
        report["owned_frontend_disconnect_requested"] = true
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { print("Could not write verification result") }
    }

    @MainActor
    static func waitFor(_ name: String, session: String, after start: Int,
                        events: () -> [(String, [String: Any])]) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let event = events().dropFirst(start).first(where: { $0.0 == name && $0.1["session_id"] as? String == session }) { return event.1 }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeError.failed("Timed out waiting for \(name)")
    }
}

enum SmokeError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
