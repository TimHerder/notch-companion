import Foundation

/// A presentation projection of stored history. It never truncates or mutates
/// the session and never includes private reasoning or raw tool-role messages.
enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ChatMessage)
    case tools(ToolCallGroup)
    case changes(TurnChanges)

    var id: String {
        switch self {
        case .message(let message): return "message:\(message.id)"
        case .tools(let group): return group.id
        case .changes(let changes): return "changes:\(changes.id)"
        }
    }
}

struct ToolCallGroup: Identifiable, Equatable {
    let id: String
    /// Complete chronological history for this user turn, including live rows.
    let tools: [ToolActivity]
    /// At most three most recent calls, only while this is the active user turn.
    /// Keep each ToolActivity.id as the row identity to animate rolling changes.
    let liveTools: [ToolActivity]
    /// The collapsed/inspectable portion. Old turns retain every call here.
    let olderTools: [ToolActivity]
    let isLive: Bool

    fileprivate init(id: String, tools: [ToolActivity], isLive: Bool) {
        self.id = id
        self.tools = tools
        self.isLive = isLive
        self.liveTools = isLive ? Array(tools.suffix(3)) : []
        self.olderTools = isLive ? Array(tools.dropLast(min(3, tools.count))) : tools
    }
}

enum ConversationTimeline {
    private struct Turn {
        let id: String
        let startedAt: Date?
        var messages: [ChatMessage] = []
        var tools: [ToolActivity] = []
        var changes: [TurnChanges] = []
        var hasTrailingAssistantPlaceholder = false
    }

    static func build(session: CompanionSession) -> [ConversationTimelineItem] {
        // Preserve provider/canonical message order, including equal or coarse
        // timestamps. Hidden rows are filtered by SessionHistory on ingestion;
        // this role check also prevents accidental system/tool/reasoning display.
        // Imported/partial histories may contain calls before the first known
        // user message. Keep them inspectable instead of dropping or attaching
        // them to an unrelated later turn.
        var turns = [Turn(id: "tools:\(session.id):unassigned", startedAt: nil)]
        var turnAliases: [String: Int] = [:]
        for original in session.messages {
            guard SessionHistory.isVisibleConversation(original) else {
                if original.role == "assistant", original.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns[turns.count - 1].hasTrailingAssistantPlaceholder = true
                }
                // Older saves may have mistaken a delegation envelope for a
                // user turn. Preserve its identity as an alias to the preceding
                // real turn so already-correlated tools do not become orphans.
                if original.role == "user", turns.count > 1 {
                    turnAliases[original.id] = turns.count - 1
                    if let turnID = original.turnID { turnAliases[turnID] = turns.count - 1 }
                }
                continue
            }
            let message = SessionHistory.projectedMessage(original)
            turns[turns.count - 1].hasTrailingAssistantPlaceholder = false
            if message.role == "user" {
                let anchor = message.turnID ?? message.id
                turns.append(Turn(id: "tools:\(session.id):turn:\(anchor)", startedAt: message.createdAt))
                turnAliases[message.id] = turns.count - 1
                turnAliases[anchor] = turns.count - 1
            }
            turns[turns.count - 1].messages.append(message)
        }

        // Swift's sort stability is not a persistence contract: retain the
        // original sequence as an explicit tie-breaker for simultaneous calls.
        let tools = session.tools.enumerated().sorted {
            if $0.element.startedAt == $1.element.startedAt { return $0.offset < $1.offset }
            return $0.element.startedAt < $1.element.startedAt
        }.map(\.element)
        for tool in tools {
            // A timestamp equal to a user boundary belongs to that new turn.
            // If several boundaries tie, the later canonical user wins.
            let owner: Int
            if let turnID = tool.turnID {
                // Explicit ownership survives restored/coarse timestamps. If its
                // user row is missing, do not guess a different conversation turn.
                owner = turnAliases[turnID] ?? 0
            } else {
                owner = turns.indices.last { index in
                    guard let start = turns[index].startedAt else { return false }
                    return start <= tool.startedAt
                } ?? 0
            }
            turns[owner].tools.append(tool)
        }

        for changes in session.changes where changes.isVisible {
            // Keep orphaned snapshots inspectable, never move them to a new turn.
            turns[turnAliases[changes.id] ?? 0].changes.append(changes)
        }
        let activeTurn = session.isBusy ? turns.indices.last : nil
        var result: [ConversationTimelineItem] = []
        for (index, turn) in turns.enumerated() {
            let group: ToolCallGroup? = turn.tools.isEmpty ? nil : ToolCallGroup(
                id: turn.id, tools: turn.tools, isLive: activeTurn == index)
            // Assistant messages are created when streaming STARTS, before any
            // tools execute. Sorting solely by createdAt would put those tools
            // below the completed answer. Show the turn's group before its last
            // visible assistant message, keeping prior commentary in order.
            let finalAssistant = activeTurn == index && turn.hasTrailingAssistantPlaceholder
                ? nil : turn.messages.lastIndex { $0.role == "assistant" }
            var insertedGroup = false
            for (offset, message) in turn.messages.enumerated() {
                if offset == finalAssistant, let group {
                    result.append(.tools(group))
                    insertedGroup = true
                }
                result.append(.message(message))
            }
            if !insertedGroup, let group { result.append(.tools(group)) }
            result.append(contentsOf: turn.changes.map(ConversationTimelineItem.changes))
        }
        if let staged = session.stagedSubmission, !session.messages.contains(where: { $0.id == staged.message.id }) {
            result.append(.message(staged.message))
        }
        return result
    }
}
