import Foundation

/// Equality drives republishing: no wall-clock-derived fields here (elapsed
/// time is rendered from `statusSince` by the row's TimelineView), so a scan
/// only republishes when the underlying data changed.
struct Session: Identifiable, Equatable, Sendable {
    let id: String
    let projectPath: String
    let projectName: String
    let model: String
    let modelTier: ModelTier
    /// Loaded right now (last response). See JSONLParser.ParsedTranscript.
    let contextTokens: Int
    /// Spent by the session so far (main transcript; subagents not included).
    let usedTokens: Int
    let toolCallCount: Int
    let lastToolName: String?
    let lastActivity: Date
    let subagents: [Subagent]
    let transcriptURL: URL

    // v1 state-file fields (fork)
    let status: Status
    let waitingReason: String?
    let lastPrompt: String?
    let lastActivityText: String?
    let statusSince: Date
    let windowDir: String?
    let claudePid: Int?
    /// Tab title from the transcript (custom-title / ai-title); tells apart sessions in the same folder.
    var title: String? = nil
    /// Finished and already attended (its window was in front or its row clicked),
    /// or finished long ago: "Inactiva" (gray) instead of "Terminó" (blue). Set by
    /// AppState after each scan — see `FinishedState`.
    var inactive: Bool = false

    /// Context window assumed for every model family except Haiku. The transcript
    /// doesn't record which window a session runs with, so this assumes the
    /// 1M-token variants of the larger models; with a 200k variant the "ctx / 1M"
    /// figure overstates the room left. The single place to change that assumption.
    static let assumedLargeContextWindow = 1_000_000
    /// Haiku's context window.
    static let haikuContextWindow = 200_000

    /// Context window by model family (see `assumedLargeContextWindow`).
    var contextWindow: Int { modelTier == .haiku ? Self.haikuContextWindow : Self.assumedLargeContextWindow }

    /// Derived for compatibility with upstream views.
    var isWorking: Bool { status == .working }
    var isWaiting: Bool { status == .waiting }

    enum Status: String, Equatable, Sendable {
        case waiting, working, done
    }

    enum ModelTier: String, Equatable, Sendable {
        case opus, sonnet, haiku, fable, unknown
    }
}

struct Subagent: Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let description: String
    let isActive: Bool
}
