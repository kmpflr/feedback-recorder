import Foundation

/// Waits for `condition` to hold, polling until `timeout`.
///
/// Tests that drive an actor or a background task cannot know how long its work will take; a fixed
/// sleep long enough to be reliable on a loaded machine is wasted on an idle one, and the ones
/// picked here were short enough to fail under a parallel test run. Waiting on the condition itself
/// finishes as soon as the work does and only takes the full timeout when something is genuinely
/// wrong. Returns whether the condition held, so a caller may assert on it or ignore it and let the
/// assertion that follows give the better message.
@discardableResult
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
