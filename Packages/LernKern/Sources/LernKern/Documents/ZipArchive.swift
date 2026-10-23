import Foundation

/// Minimaler ZIP-Leser (Stored + Deflate) für Office-Dokumente.
public struct ZipArchive: Sendable {
    public enum ZipError: Error, Equatable {
        case notAZipFile
        case corrupted(String)
        case unsupportedCompression(Int)
        case encrypted
        case entryTooLarge
    }

    public struct Entry: Sendable {
        public var path: String
        public var compressionMethod: Int
        public var compressedSize: Int
        public var uncompressedSize: Int
        public var localHeaderOffset: Int
        public var isEncrypted: Bool
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    /// Begrenzung gegen "ZIP-Bomben".
    public static let maxEntrySize = 100_000_000

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, bytes[0] == 0x50, bytes[1] == 0x4B else { throw ZipError.notAZipFile }
        // End of central directory suchen (max. 64 KB Kommentar)
        var eocd = -1
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        var i = bytes.count - 22
        while i >= lowerBound {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.corrupted("Kein Inhaltsverzeichnis") }
        let count = Int(Self.u16(bytes, eocd + 10))
        var offset = Int(Self.u32(bytes, eocd + 16))
        var list: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Self.u32(bytes, offset) == 0x0201_4B50 else { throw ZipError.corrupted("Ungültiger Verzeichniseintrag") }
            let flags = Int(Self.u16(bytes, offset + 8))
            let method = Int(Self.u16(bytes, offset + 10))
            let compressed = Int(Self.u32(bytes, offset + 20))
            let uncompressed = Int(Self.u32(bytes, offset + 24))
            let nameLength = Int(Self.u16(bytes, offset + 28))
            let extraLength = Int(Self.u16(bytes, offset + 30))
            let commentLength = Int(Self.u16(bytes, offset + 32))
            let localOffset = Int(Self.u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.corrupted("Name außerhalb der Datei") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            list.append(Entry(path: name, compressionMethod: method, compressedSize: compressed, uncompressedSize: uncompressed,
                              localHeaderOffset: localOffset, isEncrypted: flags & 1 == 1))
            offset += 46 + nameLength + extraLength + commentLength
        }
        entries = list
    }

    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    public func data(for path: String) throws -> Data? {
        guard let entry = entry(path) else { return nil }
        return try data(for: entry)
    }

    public func data(for entry: Entry) throws -> Data {
        if entry.isEncrypted { throw ZipError.encrypted }
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.entryTooLarge }
        let h = entry.localHeaderOffset
        guard h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4B50 else { throw ZipError.corrupted("Ungültiger lokaler Kopf") }
        let nameLength = Int(Self.u16(bytes, h + 26))
        let extraLength = Int(Self.u16(bytes, h + 28))
        let start = h + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= end, end <= bytes.count else { throw ZipError.corrupted("Daten außerhalb der Datei") }
        let slice = Array(bytes[start..<end])
        switch entry.compressionMethod {
        case 0:
            return Data(slice)
        case 8:
            return Data(try Inflate.decompress(slice, expectedSize: entry.uncompressedSize, maxSize: Self.maxEntrySize))
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
