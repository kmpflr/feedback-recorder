import Foundation
import AVFAudio

public enum AudioLevel {
    public static let floor: Double = -120

    public static func rmsDBFS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return floor }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return floor }
        return max(floor, 20 * log10(rms))
    }

    /// Channel 0 of any format buffer (Float32, Int16, Int32), normalised to −1…1; interleaved samples acceptable.
    public static func rmsDBFS(_ buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else { return floor }
        let frameCount = Int(buffer.frameLength)

        if let data = buffer.floatChannelData {
            return rmsDBFS(Array(UnsafeBufferPointer(start: data[0], count: frameCount)))
        }

        if let data = buffer.int16ChannelData {
            let samples = (0..<frameCount).map { Float(data[0][$0]) / 32768.0 }
            return rmsDBFS(samples)
        }

        if let data = buffer.int32ChannelData {
            let samples = (0..<frameCount).map { Float(Double(data[0][$0]) / 2147483648.0) }
            return rmsDBFS(samples)
        }

        return floor
    }
}
