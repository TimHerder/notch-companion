import Foundation

struct RuntimeModelChoice: Codable, Hashable, Identifiable {
    var model: String
    var provider: String? = nil
    var reasoningEffort: String? = nil
    var id: String { (provider ?? "") + ":" + model }

    /// Hermes accepts a slash-command argument string. Catalog values must not
    /// inject flags such as --global into that string.
    var hermesSessionValue: String? {
        let tokens = [model] + [provider].compactMap { $0 }
        guard tokens.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") &&
            $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:@+")).contains($0) }
        }) else { return nil }
        // A bare model lets Hermes auto-detect another provider (including an
        // unauthenticated aggregator). The adapter waits for the live agent
        // before passing this explicit, session-only provider selection.
        guard let provider else { return nil }
        return model + " --provider " + provider + " --session"
    }
}

struct RuntimeModelOption: Identifiable, Equatable {
    var choice: RuntimeModelChoice
    var title: String
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String? = nil
    var id: String { choice.id }

    static func effortTitle(_ effort: String) -> String { effort == "xhigh" ? "Extra high" : effort.capitalized }
}

struct ModelCatalogKey: Hashable {
    var route: RuntimeRoute
    var cwd: String
}

struct RuntimeModelCatalog: Equatable {
    var defaultModel: RuntimeModelChoice?
    var models: [RuntimeModelOption] = []
    var configuredContextWindow: Int? = nil
    var note: String? = nil

    func matchingModels(_ search: String) -> [RuntimeModelOption] {
        models.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.choice.model.localizedCaseInsensitiveContains(search) }
    }

    func option(for choice: RuntimeModelChoice) -> RuntimeModelOption? {
        if let exact = models.first(where: { $0.choice.id == choice.id }) { return exact }
        let matching = models.filter { $0.choice.model == choice.model && ($0.choice.provider == nil || choice.provider == nil) }
        return matching.count == 1 ? matching.first : nil
    }

    func title(for choice: RuntimeModelChoice) -> String { option(for: choice)?.title ?? choice.model }

    func contains(_ choice: RuntimeModelChoice) -> Bool {
        guard option(for: choice) != nil || defaultModel?.id == choice.id else { return false }
        return choice.reasoningEffort.map { option(for: choice)?.reasoningEfforts.contains($0) == true } ?? true
    }

    static func hermes(_ payload: [String: Any]) -> Self {
        let provider = nonempty(payload["provider"])
        let defaultModel = nonempty(payload["model"]).map { RuntimeModelChoice(model: $0, provider: provider) }
        // Stay on the existing provider. Other OAuth providers do not share the
        // validated read-only refresh guard used by this frontend.
        let rows = (payload["providers"] as? [[String: Any]] ?? []).filter {
            $0["slug"] as? String == provider || ($0["aliases"] as? [String] ?? []).contains(provider ?? "")
        }
        var seen = Set<String>()
        let efforts = payload["reasoning_efforts"] as? [String] ?? []
        let models = rows.flatMap { row -> [RuntimeModelOption] in
            let capabilities = row["capabilities"] as? [String: [String: Any]] ?? [:]
            return (row["models"] as? [String] ?? []).compactMap { name in
                let choice = RuntimeModelChoice(model: name, provider: provider)
                guard choice.hermesSessionValue != nil, seen.insert(choice.id).inserted else { return nil }
                let caps = capabilities[name] ?? [:]
                let supported = caps["reasoning"] as? Bool == false ? [] : efforts.filter {
                    $0 != "none" || caps["can_disable_reasoning"] as? Bool != false
                }
                return RuntimeModelOption(choice: choice, title: name, reasoningEfforts: supported)
            }
        }
        return Self(defaultModel: defaultModel, models: models,
                    note: "Models from your configured Hermes provider. Provider sign-in stays in Hermes.")
    }

    static func codex(config: [String: Any], rows: [[String: Any]]) -> Self {
        let provider = nonempty(config["model_provider"])
        // isDefault is a catalog recommendation, not the user's config override.
        let name = nonempty(config["model"]) ?? rows.first { $0["isDefault"] as? Bool == true }.flatMap { nonempty($0["model"]) }
        var seen = Set<String>()
        let models = rows.compactMap { row -> RuntimeModelOption? in
            guard row["hidden"] as? Bool != true, let model = nonempty(row["model"]), seen.insert(model).inserted else { return nil }
            return RuntimeModelOption(choice: RuntimeModelChoice(model: model, provider: provider),
                                      title: nonempty(row["displayName"]) ?? model,
                                      reasoningEfforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { nonempty($0["reasoningEffort"]) },
                                      defaultReasoningEffort: nonempty(row["defaultReasoningEffort"]))
        }
        var defaultChoice = name.map { RuntimeModelChoice(model: $0, provider: provider) }
        if let option = models.first(where: { $0.choice.model == name }),
           let effort = nonempty(config["model_reasoning_effort"]) ?? option.defaultReasoningEffort,
           option.reasoningEfforts.contains(effort) {
            defaultChoice?.reasoningEffort = effort
        }
        return Self(defaultModel: defaultChoice, models: models,
                    configuredContextWindow: positive(config["model_context_window"]))
    }
}

struct RuntimeContextUsage: Codable, Equatable {
    var used: Int?
    var limit: Int?
    var estimated: Bool = false
    var reportedAt = Date()

    var fraction: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(limit)))
    }
    var label: String {
        let prefix = estimated ? "≈" : ""
        if let used, let limit { return "\(prefix)\(Self.tokens(used)) / \(Self.tokens(limit))" }
        if let used { return "\(prefix)\(Self.tokens(used)) used" }
        if let limit { return "\(Self.tokens(limit)) window" }
        return "Not reported yet"
    }
    var detail: String {
        let count = used.map { "\($0.formatted()) tokens used" } ?? "Usage not reported"
        let maximum = limit.map { " of \($0.formatted())" } ?? "; context window not reported"
        return (estimated ? "Runtime estimate: " : "Last runtime report: ") + count + maximum + ". Updated \(reportedAt.formatted(date: .omitted, time: .shortened))."
    }
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000).replacingOccurrences(of: ".0k", with: "k") }
        return String(value)
    }
    static func hermes(_ payload: [String: Any]) -> Self? {
        let used = nonnegative(payload["context_used"]), limit = positive(payload["context_max"])
        guard used != nil || limit != nil else { return nil }
        return Self(used: used, limit: limit, estimated: payload["context_estimated"] as? Bool ?? false)
    }
    static func codex(_ payload: [String: Any]) -> Self? {
        let last = payload["last"] as? [String: Any] ?? [:]
        let used = nonnegative(last["totalTokens"]), limit = positive(payload["modelContextWindow"])
        guard used != nil || limit != nil else { return nil }
        return Self(used: used, limit: limit)
    }
}

struct RuntimeSessionInfo: Codable, Equatable {
    var model: String? = nil
    var provider: String? = nil
    var context: RuntimeContextUsage? = nil
    var capabilities: RuntimeCapabilities? = nil
    var capabilityNote: String? = nil
    var nativeInterface: String? = nil

    mutating func merge(_ payload: [String: Any], runtime: RuntimeKind) {
        if let value = payload["interface"] as? String { nativeInterface = value }
        if let values = payload["capabilities"] as? [String: Any] {
            var supported = capabilities ?? runtime.capabilities
            supported.merge(values)
            capabilities = supported
        }
        if let note = payload["capability_note"] as? String { capabilityNote = note }
        if payload["context_reset"] as? Bool == true { context = nil }
        let usage = payload["usage"] as? [String: Any]
        if let value = nonempty(payload["model"]) ?? nonempty(usage?["model"]), value != model {
            model = value
            context = nil // The previous model's limit must not follow a switch.
        }
        if let value = nonempty(payload["provider"]) { provider = value }
        if let usage {
            // New adapters normalize occupancy themselves. Never parse their
            // cumulative billing totals as Codex's last-turn context snapshot.
            if let sample = runtime == .codex ? RuntimeContextUsage.codex(usage) : RuntimeContextUsage.hermes(usage) { context = sample }
        }
    }
}

private func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}
private func nonnegative(_ value: Any?) -> Int? {
    guard let value = value as? Int, value >= 0 else { return nil }
    return value
}
private func positive(_ value: Any?) -> Int? {
    guard let value = nonnegative(value), value > 0 else { return nil }
    return value
}
