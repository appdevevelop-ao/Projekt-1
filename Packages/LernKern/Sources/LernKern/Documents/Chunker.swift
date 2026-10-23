import Foundation

/// Ein Abschnitt der Dokumentstruktur.
public struct DocumentSection: Hashable, Sendable {
    public var path: [String]
    public var level: Int
    public var blocks: [ExtractedBlock]

    public var title: String { path.last ?? "Einleitung" }
    public var text: String { blocks.map(\.text).joined(separator: "\n") }
    public var pageRange: (Int?, Int?) { (blocks.compactMap(\.page).min(), blocks.compactMap(\.page).max()) }
}

/// Gliedert Blöcke in Abschnitte und teilt sie in handliche Textabschnitte (Chunks).
/// Große Dokumente werden so nie unkontrolliert in einem Stück verarbeitet.
public enum Chunker {
    public static let targetCharacters = 1_600
    public static let maxCharacters = 2_600

    public static func sections(from document: ExtractedDocument) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        var path: [String] = []
        var current = DocumentSection(path: [], level: 0, blocks: [])
        for block in document.blocks {
            if let level = block.headingLevel {
                if !current.blocks.isEmpty { sections.append(current) }
                let title = StructureDetector.stripNumbering(block.text)
                path = Array(path.prefix(level - 1))
                while path.count < level - 1 { path.append(path.last ?? title) }
                path.append(title)
                current = DocumentSection(path: path, level: level, blocks: [])
            } else {
                current.blocks.append(block)
            }
        }
        if !current.blocks.isEmpty { sections.append(current) }
        return sections
    }

    public static func chunks(documentID: UUID, sections: [DocumentSection]) -> [SourceChunk] {
        var result: [SourceChunk] = []
        var index = 0
        for section in sections {
            var buffer: [ExtractedBlock] = []
            var length = 0
            func flush() {
                guard !buffer.isEmpty else { return }
                let text = buffer.map { block -> String in
                    switch block.kind {
                    case .listItem: return "• " + block.text
                    case .note: return "Notiz: " + block.text
                    default: return block.text
                    }
                }.joined(separator: "\n")
                let pages = buffer.compactMap(\.page)
                result.append(SourceChunk(id: stableID(documentID, index), documentID: documentID, index: index, sectionPath: section.path,
                                          pageStart: pages.min(), pageEnd: pages.max(), text: text))
                index += 1
                buffer = []
                length = 0
            }
            for block in section.blocks {
                for piece in split(block) {
                    if length + piece.text.count > maxCharacters || (length >= targetCharacters && piece.kind == .paragraph) { flush() }
                    buffer.append(piece)
                    length += piece.text.count + 1
                }
            }
            flush()
        }
        return result
    }

    /// Sehr lange Absätze an Satzgrenzen teilen.
    static func split(_ block: ExtractedBlock) -> [ExtractedBlock] {
        guard block.text.count > maxCharacters else { return [block] }
        var pieces: [ExtractedBlock] = []
        var current = ""
        for sentence in TermExtractor.sentences(in: block.text) {
            if current.count + sentence.count > targetCharacters, !current.isEmpty {
                pieces.append(ExtractedBlock(kind: block.kind, text: current, page: block.page))
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
            while current.count > maxCharacters {
                let cut = current.index(current.startIndex, offsetBy: targetCharacters)
                pieces.append(ExtractedBlock(kind: block.kind, text: String(current[..<cut]), page: block.page))
                current = String(current[cut...])
            }
        }
        if !current.isEmpty { pieces.append(ExtractedBlock(kind: block.kind, text: current, page: block.page)) }
        return pieces
    }

    /// Stabile ID aus Dokument und Position – gleiche Datei ergibt gleiche Abschnitts-IDs.
    public static func stableID(_ documentID: UUID, _ index: Int) -> UUID {
        StableHash.uuid("\(documentID.uuidString)#\(index)")
    }
}

/// Deterministische Hashes (Swift-`hashValue` ist pro Prozess zufällig).
public enum StableHash {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public static func uuid(_ text: String) -> UUID {
        let a = fnv1a(text)
        let b = fnv1a("salt:" + text)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xFF)
            bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // Version 5-ähnlich
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Deterministischer Zufallsgenerator (für reproduzierbares Mischen von Antwortoptionen).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    public init(_ text: String) { self.init(seed: StableHash.fnv1a(text)) }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
