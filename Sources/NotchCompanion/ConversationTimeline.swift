import Foundation

/// A presentation projection of stored history. It never truncates or mutates
/// the session and never includes private reasoning or raw tool-role messages.
enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ChatMessage)
    /// Text the agent wrote between tool calls: quieter than its answer.
    case commentary(ChatMessage)
    case tools(ToolCallGroup)
    /// A finished turn's work, folded above its answer.
    case work(TurnWork)
    case changes(TurnChanges)

    var id: String {
        switch self {
        // One identity for a message whether it reads as commentary or as the answer.
        case .message(let message), .commentary(let message): return "message:\(message.id)"
        case .tools(let group): return group.id
        case .work(let work): return work.id
        case .changes(let changes): return "changes:\(changes.id)"
        }
    }
}

struct ToolCallGroup: Identifiable, Equatable {
    let id: String
    /// One run of consecutive calls, in order, including live rows.
    let tools: [ToolActivity]
    /// At most three most recent calls, only for the newest run of the live turn.
    /// Keep each ToolActivity.id as the row identity to animate rolling changes.
    let liveTools: [ToolActivity]
    /// The collapsed/inspectable portion. Finished runs retain every call here.
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

/// The work of one finished block: commentary and tool runs in the order they happened.
struct TurnWork: Identifiable, Equatable {
    let id: String
    /// `.commentary` and `.tools` items, in true order.
    let entries: [ConversationTimelineItem]
    let startedAt: Date
    let endedAt: Date?
    /// `.finished`, or `.failed`/`.interrupted` for a turn that ended that way.
    let outcome: WorkState
    /// The block has an answer below: the work folds away above it. Otherwise it
    /// stays open under its header.
    let folds: Bool

    var duration: TimeInterval? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    var steps: Int {
        entries.reduce(0) { count, entry in
            if case .tools(let group) = entry { return count + group.tools.count }
            return count + 1
        }
    }
    /// "Worked for 2:14", "Failed after 8s", or "Worked · 5 steps" when an older turn's end is unknown.
    var label: String {
        let verb = outcome == .failed ? "Failed" : outcome == .interrupted ? "Stopped" : "Worked"
        if let duration { return verb + (outcome == .finished ? " for " : " after ") + Self.format(duration) }
        if outcome != .finished || entries.isEmpty { return verb }
        return "\(verb) · \(steps) \(steps == 1 ? "step" : "steps")"
    }

    /// "8s" under a minute, then "2:14", then "1:02:10".
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds < 60 ? "\(seconds)s" : SessionDigest.elapsed(TimeInterval(seconds))
    }
}

enum ConversationTimeline {
    private struct Block {
        /// The visible user row that starts the block; nil before the first one.
        let boundary: ChatMessage?
        var messages: [ChatMessage] = []
        var tools: [ToolActivity] = []
        var changes: [TurnChanges] = []
    }

    static func build(session: CompanionSession) -> [ConversationTimelineItem] {
        // Blocks start at visible user rows, in canonical message order. Hidden
        // rows are filtered by SessionHistory on ingestion; this role check also
        // prevents accidental system/tool/reasoning display. Imported/partial
        // histories may contain calls before the first known user message. Keep
        // them inspectable instead of dropping or attaching them to a later turn.
        var blocks = [Block(boundary: nil)]
        // Steering rows and wakes share their turn's ID, so one ID can name several blocks.
        var owners: [String: [Int]] = [:]
        for original in session.messages {
            guard SessionHistory.isVisibleConversation(original) else {
                // Older saves may have mistaken a delegation envelope for a
                // user turn. Preserve its identity as an alias to the preceding
                // real turn so already-correlated tools do not become orphans.
                if original.role == "user", blocks.count > 1 {
                    owners[original.id, default: []].append(blocks.count - 1)
                    if let turnID = original.turnID { owners[turnID, default: []].append(blocks.count - 1) }
                }
                continue
            }
            let message = SessionHistory.projectedMessage(original)
            if message.role == "user" {
                blocks.append(Block(boundary: message))
                owners[message.id, default: []].append(blocks.count - 1)
                if let turnID = message.turnID, turnID != message.id { owners[turnID, default: []].append(blocks.count - 1) }
            } else {
                blocks[blocks.count - 1].messages.append(message)
            }
        }

        let starts = blocks.map { $0.boundary?.createdAt ?? .distantPast }
        for tool in session.tools {
            // Explicit ownership survives restored/coarse timestamps; among the blocks
            // that share its turn, the call belongs to the latest one begun before it.
            // A call without an owner goes by time. A timestamp equal to a boundary
            // belongs to that new block; a missing explicit owner is never guessed.
            let owner: Int
            if let turnID = tool.turnID {
                let candidates = owners[turnID] ?? [0]
                owner = candidates.last { starts[$0] <= tool.startedAt } ?? candidates[0]
            } else {
                owner = starts.indices.dropFirst().last { starts[$0] <= tool.startedAt } ?? 0
            }
            blocks[owner].tools.append(tool)
        }
        for changes in session.changes where changes.isVisible {
            // A turn's changes follow its last block; orphaned snapshots stay inspectable.
            blocks[owners[changes.id]?.last ?? 0].changes.append(changes)
        }

        let liveBlock = session.isBusy ? blocks.indices.last : nil
        // A running turn keeps open the blocks a steer split from it; they fold together when it ends.
        var openFrom = liveBlock ?? blocks.count
        while let turnID = blocks.last?.boundary?.turnID, liveBlock != nil, openFrom > 1,
              let boundary = blocks[openFrom - 1].boundary, boundary.turnID == turnID, session.turnEndedAt[boundary.id] == nil {
            openFrom -= 1
        }
        var usedIDs = Set<String>()
        var result: [ConversationTimelineItem] = []
        for (index, block) in blocks.enumerated() {
            if let boundary = block.boundary { result.append(.message(boundary)) }
            let entries = interleave(block, live: index == liveBlock, session: session.id, usedIDs: &usedIDs)
            if index >= openFrom || block.boundary == nil {
                result += entries
            } else {
                let next = blocks.indices.contains(index + 1) ? blocks[index + 1].boundary : nil
                result += finished(block, entries: entries, next: next, session: session)
            }
            result += block.changes.map(ConversationTimelineItem.changes)
        }
        if let staged = session.stagedSubmission, !session.messages.contains(where: { $0.id == staged.message.id }) {
            result.append(.message(staged.message))
        }
        return result
    }

    /// A message's questions stay answerable until a visible row of the user's own
    /// follows it, however much the agent writes or runs after them in the same turn.
    /// Rows the companion sent for an agent (wakes, relayed questions) do not answer them.
    static func questionsOpen(_ messageID: String, in session: CompanionSession) -> Bool {
        guard let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return false }
        return !session.messages[(index + 1)...].contains { $0.role == "user" && $0.kind == nil && SessionHistory.isVisibleConversation($0) }
    }

    /// Text and consecutive tool runs in the order they began. Text followed by a
    /// run is commentary; the newest run of a live block shows its latest calls.
    private static func interleave(_ block: Block, live: Bool, session: String, usedIDs: inout Set<String>) -> [ConversationTimelineItem] {
        enum Entry { case text(ChatMessage), tool(ToolActivity) }
        // Swift's sort stability is not a persistence contract: ties keep text
        // first, then each array's original order.
        let ordered = (block.messages.enumerated().map { ($0.element.createdAt, 0, $0.offset, Entry.text($0.element)) }
            + block.tools.enumerated().map { ($0.element.startedAt, 1, $0.offset, Entry.tool($0.element)) })
            .sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
            .map(\.3)
        var runs: [[ToolActivity]] = []
        var shape: [Int?] = [] // a run's index, or nil for text
        var texts: [ChatMessage] = []
        for entry in ordered {
            switch entry {
            case .text(let message): texts.append(message); shape.append(nil)
            case .tool(let tool):
                if let last = shape.last, last != nil { runs[runs.count - 1].append(tool) }
                else { runs.append([tool]); shape.append(runs.count - 1) }
            }
        }
        var textIndex = 0
        let lastRun = shape.lastIndex { $0 != nil } ?? -1
        return shape.enumerated().map { offset, run in
            guard let run else {
                defer { textIndex += 1 }
                return offset < lastRun ? .commentary(texts[textIndex]) : .message(texts[textIndex])
            }
            // Derived from the run's first call, so a growing run keeps its identity.
            var id = "tools:\(session):run:\(runs[run][0].id)"
            while !usedIDs.insert(id).inserted { id += "+" }
            return .tools(ToolCallGroup(id: id, tools: runs[run], isLive: live && run == runs.count - 1))
        }
    }

    /// A finished block: its work folds above the answer, the last text written. A
    /// block that ended before writing any, or whose questions above it are still
    /// open, keeps its work open under its outcome.
    private static func finished(_ block: Block, entries: [ConversationTimelineItem], next: ChatMessage?,
                                 session: CompanionSession) -> [ConversationTimelineItem] {
        guard let boundary = block.boundary else { return entries }
        // Every way a turn ends records its outcome (AppModel), so the session's later
        // state, such as a send that failed before it became a turn, never relabels it.
        let outcome = session.turnOutcome[boundary.id] ?? .finished
        let answerID = block.messages.last(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.questions != nil
        })?.id
        // Questions still open above the answer keep the work unfolded, so their card stays in view.
        let asking = block.messages.contains { $0.id != answerID && $0.questions != nil && questionsOpen($0.id, in: session) }
        var answer: ChatMessage?
        let work: [ConversationTimelineItem] = entries.compactMap { entry in
            switch entry {
            case .message(let message) where message.id == answerID, .commentary(let message) where message.id == answerID:
                answer = message
                return nil
            case .message(let message): return .commentary(message)
            default: return entry
            }
        }
        // A block that a steer or wake split from its turn ended when the next one began.
        let endedAt = session.turnEndedAt[boundary.id]
            ?? (next?.turnID != nil && next?.turnID == boundary.turnID ? next?.createdAt : nil)
        var result: [ConversationTimelineItem] = []
        if !work.isEmpty || endedAt != nil {
            result.append(.work(TurnWork(id: "work:\(session.id):\(boundary.id)", entries: work, startedAt: boundary.createdAt,
                                         endedAt: endedAt, outcome: outcome, folds: answer != nil && !work.isEmpty && !asking)))
        }
        if let answer { result.append(.message(answer)) }
        return result
    }
}
