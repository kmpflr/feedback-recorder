import Foundation
import Testing
@testable import FeedbackCore

@Test func verboseHelperDoesNotBlockOnStderr() async throws {
    let result = try await LocalProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf 'diagnostic line\\n' >&2; i=$((i+1)); done; exit 7"],
        timeout: .seconds(10))
    #expect(result.status == 7 && !result.timedOut)
    #expect(result.stderr.utf8.count <= 4096)
    #expect(result.stderr.hasSuffix("diagnostic line\n"))
}

@Test func helperIgnoringTerminationIsStillBounded() async throws {
    let started = ContinuousClock.now
    let result = try await LocalProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: .milliseconds(200))
    #expect(result.timedOut && result.status != 0)
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test func helperThatExitsImmediatelyIsObserved() async throws {
    let result = try await LocalProcess.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                            arguments: [], timeout: .seconds(2))
    #expect(result.status == 0 && !result.timedOut && result.stderr.isEmpty)
}
