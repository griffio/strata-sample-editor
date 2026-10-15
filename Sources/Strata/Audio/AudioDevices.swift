import Foundation
import CoreAudio
import Combine

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let transport: UInt32

    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate }
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbol: String {
        if isBluetooth { return "headphones" }
        if isVirtual { return "point.3.connected.trianglepath.dotted" }
        if isBuiltIn { return inputChannels > 0 ? "mic" : "speaker.wave.2" }
        switch transport {
        case kAudioDeviceTransportTypeUSB: return inputChannels > 2 ? "rectangle.connected.to.line.below" : "cable.connector"
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI: return "rectangle.connected.to.line.below"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        default: return inputChannels > 0 ? "waveform" : "hifispeaker"
        }
    }

    var detail: String {
        let rate = sampleRate >= 1000 ? String(format: "%g kHz", sampleRate / 1000) : ""
        let ch = inputChannels > 0 ? "\(inputChannels) in" : "\(outputChannels) out"
        return [ch, rate].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Core Audio hardware enumeration with change notifications.
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    @Published private(set) var inputs: [AudioDeviceInfo] = []
    @Published private(set) var outputs: [AudioDeviceInfo] = []
    @Published private(set) var defaultInputID: AudioDeviceID = 0
    @Published private(set) var defaultOutputID: AudioDeviceID = 0

    private init() {
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let all = Self.allDeviceIDs().compactMap(Self.info)
            .filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") && !$0.name.hasPrefix("CADefaultDevice") }
        inputs = all.filter { $0.inputChannels > 0 }.sorted { rank($0) < rank($1) }
        outputs = all.filter { $0.outputChannels > 0 }
        defaultInputID = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        defaultOutputID = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func rank(_ d: AudioDeviceInfo) -> Int {
        if d.isBuiltIn { return 0 }
        if d.isVirtual { return 3 }
        if d.isBluetooth { return 2 }
        return 1
    }

    func device(uid: String) -> AudioDeviceInfo? {
        (inputs + outputs).first { $0.uid == uid }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    // MARK: Core Audio helpers

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    private static func sampleRate(_ id: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    private static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? "Audio Device"
        return AudioDeviceInfo(id: id, uid: uid, name: name,
                               manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
                               inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                               sampleRate: sampleRate(id),
                               transport: uint32(id, kAudioDevicePropertyTransportType))
    }
}
