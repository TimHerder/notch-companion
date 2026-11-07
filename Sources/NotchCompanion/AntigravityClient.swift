import Foundation

/// Antigravity specifics for the shared `ACPRuntimeClient`, which runs the installed
/// `agy acp` server on the native profile. Before a session opens, models come from
/// `agy models`, whose IDs are the ones the ACP session `models` state uses.
enum AntigravityClient {
    static let protocolNote = "Uses your installed Antigravity CLI through its native ACP server, with your sign-in, settings, models and saved conversations. Sign in with agy first. Your native permission rules decide which tools ask for approval. Image input is unavailable."

    /// `agy models` and the current `/model`; neither starts a turn or saves a conversation.
    @MainActor static func discoverModels(executable: URL, profileID: String, cwd: URL) async throws -> RuntimeModelCatalog {
        let environment = RuntimeEnvironment.native(runtime: .antigravity, profileID: profileID)
        let models = try await command(executable, ["--output-format", "json", "models"], environment: environment, cwd: cwd)
        let current = try await command(executable, ["--print", "/model", "--output-format", "json"], environment: environment, cwd: cwd)
        return try catalog(models: models, current: current)
    }

    @MainActor private static func command(_ executable: URL, _ arguments: [String], environment: [String: String], cwd: URL) async throws -> [String: Any] {
        let process = NativeJSONProcess()
        var pending: CheckedContinuation<[String: Any], Error>?
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            let reply = pending; pending = nil
            reply?.resume(throwing: AppError("Antigravity's native model query timed out."))
        }
        defer { deadline.cancel(); process.stop() }
        process.onFrame = { value in let reply = pending; pending = nil; reply?.resume(returning: value) }
        process.onFailure = { error in let reply = pending; pending = nil; reply?.resume(throwing: error) }
        try process.start(executable: executable, arguments: arguments, environment: environment, cwd: cwd)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    static func catalog(models: [String: Any], current: [String: Any]) throws -> RuntimeModelCatalog {
        guard models["status"] as? String == "SUCCESS", current["status"] as? String == "SUCCESS",
              let command = models["command"] as? [String: Any], command["name"] as? String == "models",
              let data = command["data"] as? [String: Any], let rows = data["models"] as? [[String: Any]],
              let selected = current["command"] as? [String: Any], selected["name"] as? String == "model",
              let model = (selected["data"] as? [String: Any])?["id"] as? String else {
            throw AppError("Antigravity did not return its native model catalog. Check CLI compatibility.")
        }
        let options = rows.compactMap { row -> RuntimeModelOption? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return RuntimeModelOption(choice: .init(model: id), title: row["label"] as? String ?? id)
        }
        return RuntimeModelCatalog(defaultModel: .init(model: model), models: options)
    }
}
