import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let strataProject = UTType(exportedAs: "com.griffio.strata.project", conformingTo: .package)
}

/// On-disk JSON representation. Audio lives next to it as lossless CAF files.
private struct ProjectFile: Codable {
    struct SampleMeta: Codable {
        var id: UUID
        var name: String
        var bufferID: UUID
        var slices: [Int]
        var colorIndex: Int
        var origin: String
        var createdAt: Date
    }

    var formatVersion = 1
    var bpm: Double
    var beatsPerBar: Int
    var beatUnit: Int
    var loop: LoopRegion
    var tracks: [Track]
    var samples: [SampleMeta]
    var masterVolume: Float
    var metronome: Bool
    var countIn: Bool
}

/// The document. Holds the project as a value so undo is a simple snapshot swap.
final class ProjectDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.strataProject] }
    static var writableContentTypes: [UTType] { [.strataProject] }

    @Published var project: Project

    init() {
        project = Project()
    }

    init(configuration: ReadConfiguration) throws {
        guard let root = configuration.file.fileWrappers,
              let json = root["Project.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ProjectFile.self, from: json)
        let audio = root["Audio"]?.fileWrappers ?? [:]

        var samples: [Sample] = []
        for meta in file.samples {
            guard let data = audio["\(meta.bufferID.uuidString).caf"]?.regularFileContents,
                  let buffer = try? AudioFileIO.decode(data, id: meta.bufferID) else { continue }
            samples.append(Sample(id: meta.id, name: meta.name, buffer: buffer, slices: meta.slices,
                                  colorIndex: meta.colorIndex, origin: meta.origin, createdAt: meta.createdAt))
        }
        var p = Project()
        p.bpm = file.bpm
        p.beatsPerBar = file.beatsPerBar
        p.beatUnit = file.beatUnit
        p.loop = file.loop
        p.samples = samples
        p.tracks = file.tracks
        p.masterVolume = file.masterVolume
        p.metronome = file.metronome
        p.countIn = file.countIn
        let known = Set(samples.map(\.id))
        for t in p.tracks.indices { p.tracks[t].clips.removeAll { !known.contains($0.sampleID) } }
        project = p
        DispatchQueue.global(qos: .userInitiated).async {
            samples.forEach { $0.buffer.preparePeaks() }
        }
    }

    func snapshot(contentType: UTType) throws -> Project { project }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        let file = ProjectFile(
            bpm: snapshot.bpm, beatsPerBar: snapshot.beatsPerBar, beatUnit: snapshot.beatUnit,
            loop: snapshot.loop, tracks: snapshot.tracks.map { var t = $0; t.armed = false; return t },
            samples: snapshot.samples.map {
                .init(id: $0.id, name: $0.name, bufferID: $0.buffer.id, slices: $0.slices,
                      colorIndex: $0.colorIndex, origin: $0.origin, createdAt: $0.createdAt)
            },
            masterVolume: snapshot.masterVolume, metronome: snapshot.metronome, countIn: snapshot.countIn)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(file)

        // Reuse unchanged audio files from the existing package; buffers are immutable,
        // so a matching buffer id guarantees identical contents.
        let existing = configuration.existingFile?.fileWrappers?["Audio"]?.fileWrappers ?? [:]
        var audioWrappers: [String: FileWrapper] = [:]
        for sample in snapshot.samples {
            let name = "\(sample.buffer.id.uuidString).caf"
            if audioWrappers[name] != nil { continue }
            if let old = existing[name], let data = old.regularFileContents {
                audioWrappers[name] = FileWrapper(regularFileWithContents: data)
            } else {
                audioWrappers[name] = FileWrapper(regularFileWithContents: try AudioFileIO.encode(sample.buffer))
            }
        }
        for (name, w) in audioWrappers { w.preferredFilename = name }
        let audioDir = FileWrapper(directoryWithFileWrappers: audioWrappers)
        let jsonWrapper = FileWrapper(regularFileWithContents: json)
        return FileWrapper(directoryWithFileWrappers: ["Project.json": jsonWrapper, "Audio": audioDir])
    }
}
