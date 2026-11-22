import Foundation

public enum WaveSnapshot {
    /// AVAudioRecorder finalizes its WAV lengths when it stops. Repair the lengths in a copy for preview.
    public static func make(_ source: Data, maxAudioBytes: Int = 480_000) -> Data? {
        let bytes = Array(source)
        guard bytes.count >= 44,
              bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }

        func size(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }

        var chunk = 12
        while chunk + 8 <= bytes.count {
            let start = chunk + 8
            if bytes[chunk..<chunk + 4].elementsEqual("data".utf8) {
                let length = min(bytes.count - start, maxAudioBytes) & ~1
                guard length >= 32_000 else { return nil }
                var snapshot = Data(bytes[..<start])
                let end = bytes.count - (bytes.count - start) % 2
                snapshot.append(contentsOf: bytes[(end - length)..<end])
                func writeSize(_ size: Int, at offset: Int) {
                    var value = UInt32(size).littleEndian
                    withUnsafeBytes(of: &value) { snapshot.replaceSubrange(offset..<offset + 4, with: $0) }
                }
                writeSize(snapshot.count - 8, at: 4)
                writeSize(length, at: chunk + 4)
                return snapshot
            }
            let length = size(at: chunk + 4)
            guard length <= bytes.count - start else { return nil }
            chunk = start + length + length % 2
        }
        return nil
    }
}
