import Foundation

public enum FileStoreError: Error, Equatable, LocalizedError {
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let detail): return "Gespeicherte Daten konnten nicht gelesen werden (\(detail))."
        }
    }
}

/// Lokale Datenhaltung als JSON-Dateien mit atomaren Schreibvorgängen und Sicherungskopie.
///
/// Gründe für diese Wahl statt SwiftData: vollständig testbar (auch unter Linux), keine
/// Migrationsfallen, transparente Datenstruktur, einfache vollständige Löschung.
/// Auf iOS werden Dateien zusätzlich durch Data Protection verschlüsselt.
public struct FileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var backupURL: URL { directory.appendingPathComponent("state.previous.json") }
    var sessionURL: URL { directory.appendingPathComponent("session.json") }
    var chunksDirectory: URL { directory.appendingPathComponent("chunks", isDirectory: true) }
    public var documentsDirectory: URL { directory.appendingPathComponent("documents", isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    /// Lädt den Zustand. `nil`, wenn noch nichts gespeichert wurde. Fällt bei Beschädigung auf die Sicherung zurück.
    public func loadState() throws -> AppState? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) || fm.fileExists(atPath: backupURL.path) else { return nil }
        if let data = try? Data(contentsOf: stateURL), let state = try? Self.decoder.decode(AppState.self, from: data) {
            return state
        }
        if let data = try? Data(contentsOf: backupURL), let state = try? Self.decoder.decode(AppState.self, from: data) {
            return state
        }
        throw FileStoreError.corrupted("state.json")
    }

    public func saveState(_ state: AppState) throws {
        try prepare()
        let data = try Self.encoder.encode(state)
        let fm = FileManager.default
        if fm.fileExists(atPath: stateURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: stateURL, to: backupURL)
        }
        try write(data, to: stateURL)
    }

    public func saveChunks(_ chunks: [SourceChunk], documentID: UUID) throws {
        try prepare()
        try write(try Self.encoder.encode(chunks), to: chunksDirectory.appendingPathComponent("\(documentID.uuidString).json"))
    }

    public func loadChunks(documentID: UUID) -> [SourceChunk] {
        let url = chunksDirectory.appendingPathComponent("\(documentID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([SourceChunk].self, from: data)) ?? []
    }

    public func loadChunks(documentIDs: [UUID]) -> [SourceChunk] {
        documentIDs.flatMap { loadChunks(documentID: $0) }
    }

    public func deleteChunks(documentID: UUID) {
        try? FileManager.default.removeItem(at: chunksDirectory.appendingPathComponent("\(documentID.uuidString).json"))
    }

    /// Speichert eine Kopie der Originaldatei (für erneute Verarbeitung).
    public func storeDocumentFile(_ data: Data, fileName: String) throws -> String {
        try prepare()
        let safe = UUID().uuidString + "-" + fileName.replacingOccurrences(of: "/", with: "_")
        try write(data, to: documentsDirectory.appendingPathComponent(safe))
        return safe
    }

    public func documentFileURL(_ storedName: String) -> URL { documentsDirectory.appendingPathComponent(storedName) }

    public func deleteDocumentFile(_ storedName: String?) {
        guard let storedName else { return }
        try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(storedName))
    }

    public func saveSession(_ session: StudySessionState?) throws {
        try prepare()
        if let session {
            try write(try Self.encoder.encode(session), to: sessionURL)
        } else {
            try? FileManager.default.removeItem(at: sessionURL)
        }
    }

    public func loadSession() -> StudySessionState? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? Self.decoder.decode(StudySessionState.self, from: data)
    }

    /// Löscht alle lokalen Daten (Konto/Daten löschen).
    public func deleteEverything() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
