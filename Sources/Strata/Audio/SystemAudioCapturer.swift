import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation

struct ShareableApp: Identifiable, Hashable {
    let id: String     // bundle identifier
    let name: String
}

/// Captures what the Mac is playing (all apps or a single app) via ScreenCaptureKit.
/// Delivers 48 kHz float stereo with host-time stamps.
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int, _ hostTime: UInt64) -> Void

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "strata.system-audio", qos: .userInteractive)
    private let handler: Handler
    var onStop: ((Error?) -> Void)?
    private var scratchL = [Float](repeating: 0, count: 16_384)
    private var scratchR = [Float](repeating: 0, count: 16_384)

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static func availableApps() async -> [ShareableApp] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [] }
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return content.applications
            .filter { !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier != me && !$0.applicationName.isEmpty }
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .map { ShareableApp(id: $0.bundleIdentifier, name: $0.applicationName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(appBundleID: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Strata", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available for system audio capture."])
        }
        let filter: SCContentFilter
        if let bundle = appBundleID, let app = content.applications.first(where: { $0.bundleIdentifier == bundle }) {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(AudioSpec.sampleRate)
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Video is required by the API; keep it as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.async { self.onStop?(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return }

        let list = UnsafeMutableAudioBufferListPointer(ablPtr)
        let n = min(frames, scratchL.count)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = HostClock.ticks(pts.seconds)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        scratchL.withUnsafeMutableBufferPointer { l in
            scratchR.withUnsafeMutableBufferPointer { r in
                if nonInterleaved {
                    guard let p0 = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                    let p1 = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) ?? p0 : p0
                    l.baseAddress!.assign(from: p0, count: n)
                    r.baseAddress!.assign(from: p1, count: n)
                } else {
                    guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                    let ch = Int(max(1, asbd.mChannelsPerFrame))
                    for i in 0..<n {
                        l[i] = p[i * ch]
                        r[i] = p[i * ch + (ch > 1 ? 1 : 0)]
                    }
                }
                handler(l.baseAddress!, r.baseAddress!, n, host)
            }
        }
    }
}
