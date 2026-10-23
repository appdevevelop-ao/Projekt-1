import Foundation
import LernKern
import UIKit

extension AppModel {
    // MARK: - Abschnitte

    func chunks(for documentID: UUID) -> [SourceChunk] {
        if let cached = chunkCache[documentID] { return cached }
        let loaded = store.loadChunks(documentID: documentID)
        chunkCache[documentID] = loaded
        return loaded
    }

    func chunks(forExam examID: UUID) -> [SourceChunk] {
        state.documents(for: examID).flatMap { chunks(for: $0.id) }
    }

    func chunks(ids: [UUID], examID: UUID) -> [SourceChunk] {
        let set = Set(ids)
        return chunks(forExam: examID).filter { set.contains($0.id) }
    }

    func chunk(for reference: SourceReference) -> SourceChunk? {
        chunks(for: reference.documentID).first { $0.id == reference.chunkID }
    }

    // MARK: - Import

    /// Importiert eine Datei (vom Dateiauswahldialog) in eine Prüfung.
    func importFile(at url: URL, examID: UUID, role: DocumentRole = .material) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let kind = DocumentImportService.kind(for: url)
        guard kind != .other else {
            banner = Banner(kind: .warning, title: "Format nicht unterstützt", message: "Unterstützt werden PDF, Word (.docx), PowerPoint (.pptx), Text (.txt, .md) und Bilder.")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            await importData(data, fileName: url.lastPathComponent, kind: kind, examID: examID, role: role)
        } catch {
            banner = Banner(kind: .warning, title: "Datei nicht lesbar", message: "„\(url.lastPathComponent)“ konnte nicht geöffnet werden.")
        }
    }

    /// Importiert gescannte Seiten (Dokumentenkamera) oder Fotos.
    func importImages(_ images: [UIImage], name: String, examID: UUID) async {
        var document = SourceDocument(examID: examID, fileName: name, kind: .scan, role: .material, state: ProcessingState(stage: .recognizingText))
        let documentID = document.id
        mutate { $0.documents.append(document) }
        do {
            let extracted = try await importer.recognize(images: images) { [weak self] p in
                Task { @MainActor in self?.importProgress[documentID] = p }
            }
            document.pageCount = images.count
            await finishImport(document: document, extracted: extracted, data: nil)
        } catch {
            fail(document: document, message: error.localizedDescription)
        }
    }

    func importData(_ data: Data, fileName: String, kind: DocumentKind, examID: UUID, role: DocumentRole) async {
        let document = SourceDocument(examID: examID, fileName: fileName, kind: kind, role: role, state: ProcessingState(stage: .reading))
        let documentID = document.id
        mutate { $0.documents.append(document) }
        importProgress[documentID] = ProcessingState(stage: .reading)
        do {
            let extracted = try await importer.extract(data: data, kind: kind) { [weak self] p in
                Task { @MainActor in self?.importProgress[documentID] = p }
            }
            await finishImport(document: document, extracted: extracted, data: data)
        } catch {
            fail(document: document, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func finishImport(document original: SourceDocument, extracted: ExtractedDocument, data: Data?) async {
        var document = original
        importProgress[document.id] = ProcessingState(stage: .structuring)
        let existing = state.documents(for: document.examID).filter { $0.id != document.id }.flatMap { chunks(for: $0.id) }
        let documentID = document.id
        let kind = document.kind
        let analysis: DocumentAnalysis
        do {
            analysis = try await Task.detached(priority: .userInitiated) {
                try DocumentPipeline.analyze(extracted, documentID: documentID, kind: kind, existingChunks: existing)
            }.value
        } catch {
            fail(document: document, message: (error as? LocalizedError)?.errorDescription ?? "Die Datei enthält keinen auswertbaren Text.")
            return
        }
        do {
            try store.saveChunks(analysis.chunks, documentID: document.id)
            chunkCache[document.id] = analysis.chunks
            if let data { document.storedFileName = try? store.storeDocumentFile(data, fileName: document.fileName) }
        } catch {
            fail(document: document, message: "Speichern fehlgeschlagen: \(error.localizedDescription)")
            return
        }

        document.pageCount = analysis.pageCount
        document.characterCount = analysis.characterCount
        document.warnings = analysis.warnings
        var notes: [String] = []

        if document.role == .syllabus {
            let entries = SyllabusParser.entries(from: extracted)
            var summary: IntegrationSummary?
            document.state = ProcessingState(stage: .completed)
            mutate { state in
                if let i = state.documents.firstIndex(where: { $0.id == document.id }) { state.documents[i] = document }
                summary = MaterialIntegrator.integrateSyllabus(&state, examID: document.examID, entries: entries)
            }
            importProgress[document.id] = nil
            banner = Banner(kind: .success, title: "Lehrplan übernommen", message: "\(entries.count) Einträge erkannt. " + (summary?.notes.joined(separator: " ") ?? ""))
            replan(trigger: .newMaterial(examTitle: state.exam(document.examID)?.title ?? "", newObjectives: summary?.newObjectives ?? 0), announce: false)
            return
        }

        // KI-Analyse in Teilstücken (falls eingerichtet), sonst lokale Analyse
        var aiResult: AIResponseValidator.CurriculumResult?
        if state.settings.isAIUsable, let exam = state.exam(document.examID) {
            let batches = AIBatcher.batches(analysis.chunks)
            var topics: [Topic] = []
            var objectives: [LearningObjective] = []
            var terms: [KeyTerm] = []
            var rejections: [AIRejection] = []
            var failures = 0
            for (index, batch) in batches.enumerated() {
                importProgress[document.id] = ProcessingState(stage: .analyzing, fraction: Double(index) / Double(max(batches.count, 1)), detail: "Abschnitt \(index + 1) von \(batches.count)")
                let request = AIContracts.AnalyzeRequest(
                    exam: .init(exam: exam), language: "de", chunks: batch.map { AIContracts.ChunkPayload(chunk: $0) },
                    knownTopics: (state.topics(for: exam.id) + topics).map(\.title))
                do {
                    let response = try await ai.analyze(request, settings: state.settings)
                    let result = AIResponseValidator.curriculum(response, examID: exam.id, chunks: batch, existingTopics: state.topics(for: exam.id) + topics,
                                                                orderOffset: (state.topics(for: exam.id).map(\.order).max() ?? -1) + 1 + topics.count)
                    topics += result.topics
                    objectives += result.objectives
                    terms += result.terms
                    rejections += result.rejections
                } catch {
                    failures += 1
                    if failures == 1 { notes.append((error as? LocalizedError)?.errorDescription ?? "KI-Analyse teilweise fehlgeschlagen.") }
                    var stop = false
                    if let aiError = error as? AIService.AIError {
                        switch aiError {
                        case .unauthorized, .notConfigured: stop = true
                        default: break
                        }
                    }
                    if stop {
                        failures = batches.count - index
                        break
                    }
                }
            }
            if !objectives.isEmpty {
                aiResult = AIResponseValidator.CurriculumResult(topics: topics, objectives: objectives, terms: terms, rejections: rejections, warnings: [])
            }
            if failures > 0 {
                document.warnings.append(ExtractionWarning(kind: .analysisIncomplete, message: "\(failures) von \(batches.count) Teilen konnten nicht mit KI analysiert werden und wurden lokal ausgewertet."))
            }
        }

        importProgress[document.id] = ProcessingState(stage: .checkingQuality)
        var summary: IntegrationSummary?
        document.state = ProcessingState(stage: .completed)
        mutate { state in
            if let i = state.documents.firstIndex(where: { $0.id == document.id }) { state.documents[i] = document }
            summary = MaterialIntegrator.integrate(&state, document: document, analysis: analysis, aiResult: aiResult)
        }
        importProgress[document.id] = nil
        if let summary {
            let source = summary.source == .ai ? "mit KI" : "lokal auf dem Gerät"
            let warn = document.warnings.isEmpty ? "" : " \(document.warnings.count) Hinweis(e) zur Lesbarkeit – siehe Dokument."
            banner = Banner(kind: document.warnings.isEmpty ? .success : .info, title: "„\(document.fileName)“ verarbeitet",
                            message: "\(summary.newObjectives) Lernziele und \(summary.newQuestions) Übungsfragen erstellt (\(source)).\(warn) " + (notes + summary.notes).joined(separator: " "))
            replan(trigger: .newMaterial(examTitle: state.exam(document.examID)?.title ?? "", newObjectives: summary.newObjectives), announce: false)
        }
    }

    private func fail(document: SourceDocument, message: String) {
        importProgress[document.id] = nil
        mutate { state in
            if let i = state.documents.firstIndex(where: { $0.id == document.id }) {
                state.documents[i].state = ProcessingState(stage: .failed, errorMessage: message)
            }
        }
        banner = Banner(kind: .warning, title: "Import fehlgeschlagen", message: message)
    }

    // MARK: - Verwaltung

    func deleteDocument(_ documentID: UUID) {
        let chunkIDs = Set(chunks(for: documentID).map(\.id))
        let stored = state.documents.first { $0.id == documentID }?.storedFileName
        mutate { MaterialIntegrator.removeDocument(&$0, documentID: documentID, chunkIDs: chunkIDs) }
        store.deleteChunks(documentID: documentID)
        store.deleteDocumentFile(stored)
        chunkCache[documentID] = nil
        replan(trigger: .routine, announce: false)
    }

    /// Erneute Verarbeitung der gespeicherten Originaldatei (z. B. nachdem der KI-Dienst eingerichtet wurde).
    func reprocessDocument(_ documentID: UUID) async {
        guard let document = state.documents.first(where: { $0.id == documentID }), let stored = document.storedFileName,
              let data = try? Data(contentsOf: store.documentFileURL(stored)) else {
            banner = Banner(kind: .warning, title: "Nicht möglich", message: "Die Originaldatei ist nicht mehr vorhanden. Bitte erneut importieren.")
            return
        }
        let examID = document.examID
        let fileName = document.fileName
        let kind = document.kind
        let role = document.role
        deleteDocument(documentID)
        await importData(data, fileName: fileName, kind: kind, examID: examID, role: role)
    }

    func setObjectiveStatus(_ objectiveID: UUID, _ status: ReviewStatus) {
        mutate { state in
            if let i = state.objectives.firstIndex(where: { $0.id == objectiveID }) { state.objectives[i].reviewStatus = status }
        }
        replan(trigger: .routine, announce: false)
    }

    func updateTopic(_ topic: Topic) {
        mutate { state in
            if let i = state.topics.firstIndex(where: { $0.id == topic.id }) { state.topics[i] = topic }
        }
        replan(trigger: .routine, announce: false)
    }

    /// Eigenes Thema mit Lernzielen (z. B. aus einer Themenliste der Lehrkraft) anlegen.
    func addManualTopic(examID: UUID, title: String, objectives: [String]) {
        let topic = Topic(examID: examID, title: title, order: (state.topics(for: examID).map(\.order).max() ?? -1) + 1, origin: .user, reviewStatus: .confirmed, hasMaterial: false)
        let objs = objectives.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated().map { i, t in
            LearningObjective(examID: examID, topicID: topic.id, title: t, origin: .user, reviewStatus: .confirmed, order: i)
        }
        mutate { state in
            state.topics.append(topic)
            state.objectives.append(contentsOf: objs.isEmpty ? [LearningObjective(examID: examID, topicID: topic.id, title: "„\(title)“ beherrschen", origin: .user, reviewStatus: .confirmed)] : objs)
        }
        replan(trigger: .newMaterial(examTitle: state.exam(examID)?.title ?? "", newObjectives: max(1, objs.count)))
    }
}
