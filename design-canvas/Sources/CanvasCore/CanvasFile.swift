import Foundation

public enum CanvasFileError: Error, Equatable {
    case notACanvasFile
    case unsupportedVersion(Int)
}

/// What a `.canvas` file holds: the document and its comments, as JSON.
///
/// The encoding is deterministic (sorted keys, ISO 8601 dates), so the same document
/// always writes the same bytes. A file can live in the app's repository, diff cleanly
/// in review, and be read or edited by agents without the editor.
public struct CanvasFile: Codable, Equatable, Sendable {
    public static let format = "design-canvas"
    public static let currentVersion = 1
    public static let fileExtension = "canvas"

    public var format: String
    public var version: Int
    public var document: CanvasDocument
    public var comments: CommentStore

    public init(document: CanvasDocument, comments: CommentStore = CommentStore()) {
        format = Self.format
        version = Self.currentVersion
        self.document = document
        self.comments = comments
    }

    private struct Header: Decodable {
        let format: String?
        let version: Int?
    }

    /// Checks the header before decoding the rest, so a wrong file fails with a clear
    /// error instead of a missing-key one.
    public static func decode(_ data: Data) throws -> CanvasFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format else {
            throw CanvasFileError.notACanvasFile
        }
        guard let version = header.version, version <= currentVersion else {
            throw CanvasFileError.unsupportedVersion(header.version ?? -1)
        }
        return try decoder.decode(CanvasFile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
