import Foundation
import AVFoundation

enum AudioFileError: LocalizedError {
    case unreadable(String)
    case conversionFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” could not be read as audio."
        case .conversionFailed: return "The audio could not be converted to 48 kHz stereo."
        case .writeFailed(let why): return "The audio file could not be written: \(why)"
        }
    }
}

/// Reading and writing audio files. Everything that enters the app is converted to
/// 48 kHz, 32-bit float, de-interleaved stereo.
enum AudioFileIO {
    static let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: AudioSpec.sampleRate,
                                                channels: 2, interleaved: false)!

    static let importableExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac", "mp4", "alac"]

    static func load(url: URL) throws -> SampleBuffer {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        try file.read(into: inBuf)
        return try convert(inBuf)
    }

    /// Converts any PCM buffer into a project-format SampleBuffer (rate + channel layout).
    static func convert(_ inBuf: AVAudioPCMBuffer) throws -> SampleBuffer {
        let inFormat = inBuf.format
        let srcStereo: AVAudioPCMBuffer
        if inFormat.sampleRate == AudioSpec.sampleRate && inFormat.commonFormat == .pcmFormatFloat32 && !inFormat.isInterleaved {
            srcStereo = inBuf
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: processingFormat) else {
                throw AudioFileError.conversionFailed
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            if inFormat.channelCount == 1 {
                converter.channelMap = [0, 0]
            }
            let ratio = AudioSpec.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 4096)
            guard let out = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
                throw AudioFileError.conversionFailed
            }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .endOfStream; return nil }
                fed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw error ?? AudioFileError.conversionFailed }
            srcStereo = out
        }
        let n = Int(srcStereo.frameLength)
        let buffer = SampleBuffer(frameCount: n)
        guard let ch = srcStereo.floatChannelData else { throw AudioFileError.conversionFailed }
        buffer.left.assign(from: ch[0], count: n)
        buffer.right.assign(from: srcStereo.format.channelCount > 1 ? ch[1] : ch[0], count: n)
        return buffer
    }

    enum FileKind { case wav, aiff, cafLossless, cafFloat }

    static func write(_ buffer: SampleBuffer, range: Range<Int>? = nil, to url: URL, kind: FileKind) throws {
        let r = (range ?? 0..<buffer.frameCount).clamped(to: 0..<buffer.frameCount)
        var settings: [String: Any] = [
            AVSampleRateKey: AudioSpec.sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        switch kind {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .cafLossless:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        case .cafFloat:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 65_536
            var pos = r.lowerBound
            guard let pcm = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
                throw AudioFileError.writeFailed("allocation")
            }
            while pos < r.upperBound {
                let n = min(chunk, r.upperBound - pos)
                pcm.floatChannelData![0].assign(from: buffer.left + pos, count: n)
                pcm.floatChannelData![1].assign(from: buffer.right + pos, count: n)
                pcm.frameLength = AVAudioFrameCount(n)
                try file.write(from: pcm)
                pos += n
            }
        } catch let e as AudioFileError {
            throw e
        } catch {
            throw AudioFileError.writeFailed(error.localizedDescription)
        }
    }

    /// Encodes to in-memory data (used by the document package writer).
    static func encode(_ buffer: SampleBuffer) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 32-bit float CAF: bit-exact, and preserves headroom above 0 dBFS
        // (integer codecs such as ALAC would clip boosted samples).
        try write(buffer, to: tmp, kind: .cafFloat)
        return try Data(contentsOf: tmp)
    }

    static func decode(_ data: Data, id: UUID) throws -> SampleBuffer {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        let loaded = try load(url: tmp)
        let buffer = SampleBuffer(id: id, frameCount: loaded.frameCount)
        buffer.left.assign(from: loaded.left, count: loaded.frameCount)
        buffer.right.assign(from: loaded.right, count: loaded.frameCount)
        return buffer
    }
}
