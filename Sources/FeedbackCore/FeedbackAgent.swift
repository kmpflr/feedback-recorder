import Foundation

/// The coding agent that receives a session. Recording itself does not depend on either agent.
public enum FeedbackAgent: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var skillInvocation: String {
        switch self {
        case .claudeCode: "/feedback"
        case .codex: "$feedback"
        }
    }
}
