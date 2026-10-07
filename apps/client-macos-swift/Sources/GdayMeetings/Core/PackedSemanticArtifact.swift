import Foundation

/// Binary plist Data values contain packed coordinates, never numeric JSON arrays.
struct PackedSemanticArtifact: Codable {
    let version: Int
    let dimensions: Int
    let metadata: SemanticMeetingArtifact
    let fp32: Data
    let int8: Data

    init(_ artifact: SemanticMeetingArtifact) throws {
        version = 1
        dimensions = artifact.windows.first?.vector.count ?? 0
        guard artifact.windows.isEmpty || [384, 768].contains(dimensions) else {
            throw SearchProviderError.invalidResponse
        }
        guard Set(artifact.windows.map(\.id)).count == artifact.windows.count else {
            throw SearchProviderError.invalidResponse
        }
        if !artifact.windows.isEmpty, let model = SemanticModelID.allCases.first(where: { $0.space == artifact.space }),
            model.dimensions != dimensions
        {
            throw SearchProviderError.invalidResponse
        }
        var floats = Data()
        var integers = Data()
        for window in artifact.windows {
            let values = window.vector.map(Float.init)
            guard values.count == dimensions, values.allSatisfy(\.isFinite) else {
                throw SearchProviderError.invalidResponse
            }
            let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard norm.isFinite, abs(norm - 1) < 0.0001 else { throw SearchProviderError.invalidResponse }
            let bits = values.map { $0.bitPattern.littleEndian }
            bits.withUnsafeBytes { floats.append(contentsOf: $0) }
            // Match USearch's cast_to_i8: normalize, scale by 127, truncate toward zero.
            integers.append(
                contentsOf: values.map {
                    UInt8(bitPattern: Int8(max(-127, min(127, Double($0) * 127 / norm))))
                })
        }
        fp32 = floats
        int8 = integers
        metadata = .init(
            space: artifact.space, meetingID: artifact.meetingID, revision: artifact.revision,
            windows: artifact.windows.map { window in
                var value = window
                value.vector = []
                return value
            })
    }
    func unpack() throws -> SemanticMeetingArtifact {
        guard version == 1, dimensions == 0 || [384, 768].contains(dimensions),
            metadata.windows.isEmpty || dimensions > 0,
            int8.count == metadata.windows.count * dimensions, fp32.count == int8.count * 4,
            metadata.windows.allSatisfy({ $0.vector.isEmpty })
        else { throw SearchProviderError.invalidResponse }
        var windows = metadata.windows
        for position in windows.indices {
            windows[position].vector = try Self.vector(
                fp32.subdata(in: position * dimensions * 4..<(position + 1) * dimensions * 4), dimensions: dimensions
            ).map(Double.init)
        }
        let result = SemanticMeetingArtifact(
            space: metadata.space, meetingID: metadata.meetingID, revision: metadata.revision, windows: windows)
        guard try PackedSemanticArtifact(result).int8 == int8 else { throw SearchProviderError.invalidResponse }
        return result
    }
    static func vector(_ data: Data, dimensions: Int) throws -> [Float] {
        guard data.count == dimensions * 4 else { throw SearchProviderError.invalidResponse }
        let values = data.withUnsafeBytes { bytes in
            (0..<dimensions).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard values.allSatisfy(\.isFinite), abs(norm - 1) < 0.0001 else { throw SearchProviderError.invalidResponse }
        return values
    }
    static func url(folder: URL, space: String) throws -> URL {
        let url = folder.appendingPathComponent(
            "providers/local-search/" + SemanticSource.hash(Data(space.utf8)) + "/embeddings.packed")
        guard url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/providers/") else {
            throw SearchProviderError.invalidResponse
        }
        return url
    }
    func save(folder: URL) throws {
        let url = try Self.url(folder: folder, space: metadata.space)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    static func read(folder: URL, space: String, meetingID: UUID) throws -> SemanticMeetingArtifact {
        let packed = try PropertyListDecoder().decode(
            Self.self, from: Data(contentsOf: url(folder: folder, space: space)))
        guard packed.metadata.space == space, packed.metadata.meetingID == meetingID else {
            throw SearchProviderError.invalidResponse
        }
        return try packed.unpack()
    }
}
