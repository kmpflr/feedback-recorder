import AVFAudio

extension AVAudioPCMBuffer {
    /// Real-time callbacks reuse their buffer; copy before handing it to an AsyncStream.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            let bytes = Int(min(source[index].mDataByteSize, target[index].mDataByteSize))
            memcpy(to, from, bytes)
        }
        return copy
    }
}
