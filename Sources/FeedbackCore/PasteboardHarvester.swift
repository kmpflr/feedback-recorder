import Foundation
import CryptoKit

public protocol PasteboardReading: Sendable {
    var changeCount: Int { get }
    /// PNG bytes of the image on the pasteboard, or nil when there is no image.
    func pngImageData() -> Data?
}

public protocol ShotStoring: Sendable {
    /// Saves the PNG and returns the transcript-relative path, e.g. "shots/001.png".
    func save(png: Data, index: Int) throws -> String
}

public struct PasteboardHarvester: Sendable {
    private var lastChangeCount: Int
    private var seenHashes: Set<String> = []
    private var nextIndex = 1

    public init(initialChangeCount: Int) { lastChangeCount = initialChangeCount }

    public mutating func poll(_ pasteboard: PasteboardReading, store: ShotStoring, at time: TimeInterval) throws -> ScreenshotEvent? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        guard let png = pasteboard.pngImageData() else { return nil }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        guard !seenHashes.contains(hash) else { return nil }
        let index = nextIndex
        let path = try store.save(png: png, index: index)
        seenHashes.insert(hash)
        nextIndex += 1
        return ScreenshotEvent(index: index, time: time, relativePath: path)
    }
}

public struct FileShotStore: ShotStoring {
    public let shotsURL: URL
    public init(shotsURL: URL) { self.shotsURL = shotsURL }
    public func save(png: Data, index: Int) throws -> String {
        let name = String(format: "%03d.png", index)
        try png.write(to: shotsURL.appendingPathComponent(name), options: .atomic)
        return "shots/\(name)"
    }
}
