import Foundation
import Testing
@testable import FeedbackCore

@Test func feedbackPromptsUseTheSelectedAgentsInvocation() {
    let folder = SessionFolder(url: URL(fileURLWithPath: "/tmp/example-session"))
    #expect(folder.feedbackCommand(for: .codex) == "$feedback /tmp/example-session")
    #expect(folder.feedbackCommand(for: .claudeCode) == "/feedback /tmp/example-session")
}

@Test func bothAgentsPreserveSpacesAndQuotesInSessionPaths() {
    let folder = SessionFolder(url: URL(fileURLWithPath: "/tmp/Review \"A\"/session"))
    for agent in FeedbackAgent.allCases {
        let command = folder.feedbackCommand(for: agent)
        let argument = String(command.dropFirst(agent.skillInvocation.count + 1))
        let decoded = try? JSONDecoder().decode(String.self, from: Data(argument.utf8))
        #expect(decoded == folder.url.path)
    }
}
