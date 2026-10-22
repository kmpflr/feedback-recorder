import AppKit
import FeedbackCore

struct GeneralPasteboard: PasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }
    /// Any image type on the pasteboard, normalised to PNG.
    func pngImageData() -> Data? {
        let pb = NSPasteboard.general
        guard let type = pb.availableType(from: [.png, .tiff]) else { return nil }
        guard let data = pb.data(forType: type) else { return nil }
        if type == .png { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Polls the general pasteboard four times a second and files new images into the session.
final class PasteboardShotSource: ShotSource, @unchecked Sendable {
    private let interval: TimeInterval
    private let onError: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<ScreenshotEvent>.Continuation?
    private let queue = DispatchQueue(label: "feedback-recorder.pasteboard")

    init(interval: TimeInterval = 0.25, onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.interval = interval
        self.onError = onError
    }

    func start(folder: SessionFolder, sessionTime: @escaping @Sendable () -> TimeInterval) -> AsyncStream<ScreenshotEvent> {
        let (stream, cont) = AsyncStream<ScreenshotEvent>.makeStream()
        continuation = cont
        var harvester = PasteboardHarvester(initialChangeCount: NSPasteboard.general.changeCount)
        let store = FileShotStore(shotsURL: folder.shotsURL)
        let pasteboard = GeneralPasteboard()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                if let event = try harvester.poll(pasteboard, store: store, at: sessionTime()) {
                    self.continuation?.yield(event)
                }
            } catch {
                // A screenshot the reviewer copied and believes is in the session would otherwise
                // vanish without a word — the disk is full, the folder is gone — and the transcript
                // would read as if they never took it. The harvester leaves the hash unrecorded on
                // a throw, so copying the same image again retries the save.
                self.onError("screenshot not saved: \(error.localizedDescription)")
            }
        }
        // `continuation` and `timer` are both written here, on the caller's thread, before
        // `timer.resume()` starts dispatching ticks onto `queue` — resume() establishes a
        // happens-before edge, so the timer handler's first (and every) read of `continuation`
        // is guaranteed to see these assignments without needing queue.sync here.
        self.timer = timer
        timer.resume()
        return stream
    }

    func stop() {
        // Runs on the caller's thread, while the timer's event handler runs on `queue`.
        // Without synchronisation, a tick in flight during stop() could race these writes.
        // queue.sync serialises stop()'s teardown with any in-flight tick; this cannot
        // deadlock because stop() is never called from `queue` itself — only the timer
        // handler runs there, and it never calls stop().
        queue.sync {
            timer?.cancel(); timer = nil
            continuation?.finish(); continuation = nil
        }
    }
}
