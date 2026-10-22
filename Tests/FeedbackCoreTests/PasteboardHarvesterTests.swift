import Foundation
import Testing
@testable import FeedbackCore

private final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var changeCount = 0
    var png: Data?
    func pngImageData() -> Data? { png }
}

private final class MemoryStore: ShotStoring, @unchecked Sendable {
    var saved: [(Int, Data)] = []
    func save(png: Data, index: Int) throws -> String { saved.append((index, png)); return String(format: "shots/%03d.png", index) }
}

private final class ThrowingStore: ShotStoring, @unchecked Sendable {
    var callCount = 0
    func save(png: Data, index: Int) throws -> String {
        callCount += 1
        if callCount == 1 {
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }
        return String(format: "shots/%03d.png", index)
    }
}

@Test func ignoresUnchangedAndNonImageChanges() throws {
    let pb = FakePasteboard(); let store = MemoryStore()
    var h = PasteboardHarvester(initialChangeCount: 0)
    #expect(try h.poll(pb, store: store, at: 1) == nil)          // unchanged
    pb.changeCount = 1; pb.png = nil
    #expect(try h.poll(pb, store: store, at: 2) == nil)          // text copied
    #expect(store.saved.isEmpty)
}

@Test func savesNewImagesWithSequentialIndexesAndSkipsDuplicates() throws {
    let pb = FakePasteboard(); let store = MemoryStore()
    var h = PasteboardHarvester(initialChangeCount: 0)
    pb.changeCount = 1; pb.png = Data([1, 2, 3])
    let first = try h.poll(pb, store: store, at: 31.2)
    #expect(first == ScreenshotEvent(index: 1, time: 31.2, relativePath: "shots/001.png"))
    pb.changeCount = 2                                           // same image copied again
    #expect(try h.poll(pb, store: store, at: 40) == nil)
    pb.changeCount = 3; pb.png = Data([9, 9])
    let second = try h.poll(pb, store: store, at: 50)
    #expect(second?.index == 2 && second?.relativePath == "shots/002.png")
    #expect(store.saved.count == 2)
}

@Test func fileShotStoreWritesZeroPaddedPNGs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fr-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = FileShotStore(shotsURL: dir)
    let rel = try store.save(png: Data([0x89, 0x50]), index: 7)
    #expect(rel == "shots/007.png")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("007.png").path))
}

@Test func retriesAfterThrowingStoreWithoutConsumingIndexOrRecordingHash() throws {
    let pb = FakePasteboard(); let store = ThrowingStore()
    var h = PasteboardHarvester(initialChangeCount: 0)
    pb.changeCount = 1; pb.png = Data([1, 2, 3])
    #expect(throws: NSError.self) { try h.poll(pb, store: store, at: 31.2) }
    pb.changeCount = 2                                           // same image copied again
    let result = try h.poll(pb, store: store, at: 40)
    #expect(result?.index == 1 && result?.relativePath == "shots/001.png")
}
