import LernKern
import SwiftUI
import UniformTypeIdentifiers

/// Lernstoff: Prüfungen, Unterlagen, Themen und Lernziele.
struct MaterialView: View {
    @Environment(AppModel.self) private var model
    @State private var creatingExam = false

    var body: some View {
        NavigationStack {
            List {
                if model.state.exams.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Prüfung", systemImage: "graduationcap")
                    } description: {
                        Text("Lege eine Prüfung an und lade deine Unterlagen hoch.")
                    } actions: {
                        Button("Prüfung anlegen") { creatingExam = true }.buttonStyle(.borderedProminent)
                    }
                }
                let active = model.state.exams.filter { !$0.isArchived }.sorted { $0.examDate < $1.examDate }
                if !active.isEmpty {
                    Section("Prüfungen") {
                        ForEach(active) { exam in
                            NavigationLink(value: exam.id) { ExamRow(exam: exam) }
                        }
                    }
                }
                let archived = model.state.exams.filter(\.isArchived)
                if !archived.isEmpty {
                    Section("Archiv") {
                        ForEach(archived) { exam in
                            NavigationLink(value: exam.id) { ExamRow(exam: exam) }
                        }
                    }
                }
            }
            .navigationTitle("Lernstoff")
            .navigationDestination(for: UUID.self) { id in ExamMaterialView(examID: id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creatingExam = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Prüfung hinzufügen")
                }
            }
            .sheet(isPresented: $creatingExam) { ExamEditorSheet(exam: nil) }
        }
    }
}

struct ExamRow: View {
    @Environment(AppModel.self) private var model
    let exam: Exam

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exam.title).font(.headline)
                Text("\(Formatters.date.string(from: exam.examDate)) · Ziel: \(exam.targetBand.label)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = model.snapshot.exam(exam.id) {
                ProgressRing(fraction: snapshot.progress.fraction, label: "\(snapshot.progress.percent)", lineWidth: 5, size: 40)
            }
        }
    }
}

struct ExamMaterialView: View {
    @Environment(AppModel.self) private var model
    let examID: UUID
    @State private var importingRole: DocumentRole?
    @State private var scanning = false
    @State private var addingTopic = false
    @State private var editingExam = false

    var body: some View {
        if let exam = model.state.exam(examID) {
            List {
                documentsSection(exam)
                topicsSection(exam)
                Section {
                    Button("Prüfung bearbeiten", systemImage: "slider.horizontal.3") { editingExam = true }
                    Button("Prüfungssimulation starten", systemImage: "timer") { Task { await model.startSimulation(examID: exam.id) } }
                }
            }
            .navigationTitle(exam.title)
            .fileImporter(isPresented: Binding(get: { importingRole != nil }, set: { if !$0 { importingRole = nil } }),
                          allowedContentTypes: SupportedTypes.all, allowsMultipleSelection: true) { result in
                let role = importingRole ?? .material
                importingRole = nil
                if case .success(let urls) = result {
                    Task {
                        for url in urls { await model.importFile(at: url, examID: exam.id, role: role) }
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                DocumentScannerView { images in
                    scanning = false
                    guard !images.isEmpty else { return }
                    Task { await model.importImages(images, name: "Scan \(Formatters.dayShort.string(from: Date()))", examID: exam.id) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $addingTopic) { ManualTopicSheet(examID: exam.id) }
            .sheet(isPresented: $editingExam) { ExamEditorSheet(exam: exam) }
        } else {
            ContentUnavailableView("Prüfung nicht gefunden", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func documentsSection(_ exam: Exam) -> some View {
        Section {
            ForEach(model.state.documents(for: exam.id)) { document in
                NavigationLink { DocumentDetailView(documentID: document.id) } label: { DocumentRow(document: document) }
            }
            Menu {
                Button("Datei auswählen", systemImage: "doc") { importingRole = .material }
                if DocumentScannerView.isSupported {
                    Button("Seiten scannen", systemImage: "doc.viewfinder") { scanning = true }
                }
                Button("Lehrplan oder Themenliste", systemImage: "list.bullet.clipboard") { importingRole = .syllabus }
                Button("Thema selbst anlegen", systemImage: "square.and.pencil") { addingTopic = true }
            } label: {
                Label("Unterlagen hinzufügen", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Unterlagen")
        } footer: {
            Text("Unterstützt: PDF (auch gescannt), Word (.docx), PowerPoint (.pptx), Text (.txt, .md) und Fotos von Mitschriften. Texterkennung läuft auf deinem Gerät. Ein Lehrplan legt verbindlich fest, welche Themen geprüft werden.")
        }
    }

    @ViewBuilder
    private func topicsSection(_ exam: Exam) -> some View {
        let progress = model.snapshot.exam(exam.id)?.progress
        ForEach(model.state.topics(for: exam.id)) { topic in
            Section {
                ForEach(model.state.objectives(inTopic: topic.id)) { objective in
                    NavigationLink { ObjectiveDetailView(objectiveID: objective.id) } label: {
                        ObjectiveRow(objective: objective)
                    }
                }
            } header: {
                TopicHeader(topic: topic, progress: progress?.topics.first { $0.topic.id == topic.id })
            }
        }
    }
}

enum SupportedTypes {
    static var all: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .image, .jpeg, .png, .heic]
        for identifier in ["org.openxmlformats.wordprocessingml.document", "org.openxmlformats.presentationml.presentation", "net.daringfireball.markdown"] {
            if let t = UTType(identifier) { types.append(t) }
        }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }
}

struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    let document: SourceDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: document.role == .syllabus ? "list.bullet.clipboard" : "doc.text").foregroundStyle(.tint)
                Text(document.fileName).lineLimit(1)
            }
            if let progress = model.importProgress[document.id] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.stage.title + (progress.detail.map { " – \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
            } else {
                switch document.state.stage {
                case .failed:
                    Label(document.state.errorMessage ?? "Fehlgeschlagen", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                case .completed:
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                default:
                    Text("Verarbeitung unterbrochen – bitte erneut importieren.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        var parts = ["\(document.kind.title)", "\(document.pageCount) \(document.kind == .pptx ? "Folien" : "Seiten")"]
        switch document.analysisSource {
        case .ai: parts.append("mit KI analysiert")
        case .local: parts.append("lokal analysiert")
        case .none: break
        }
        if !document.warnings.isEmpty { parts.append("\(document.warnings.count) Hinweis(e)") }
        return parts.joined(separator: " · ")
    }
}

struct TopicHeader: View {
    let topic: Topic
    let progress: TopicProgress?

    var body: some View {
        HStack {
            Text(topic.title)
            if topic.importance == .core { Image(systemName: "star.fill").font(.caption2).accessibilityLabel("Kernthema") }
            if !topic.hasMaterial { Image(systemName: "exclamationmark.circle").font(.caption2).accessibilityLabel("Kein Material") }
            Spacer()
            if let progress { Text("\(progress.percent) %").monospacedDigit() }
        }
    }
}

struct ObjectiveRow: View {
    @Environment(AppModel.self) private var model
    let objective: LearningObjective

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(objective.title)
            HStack {
                LevelBadge(level: model.snapshot.knowledge[objective.id]?.level ?? .notStarted)
                OriginBadge(origin: objective.origin, status: objective.reviewStatus)
            }
        }
    }
}

struct DocumentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let document = model.state.documents.first(where: { $0.id == documentID }) {
            List {
                Section {
                    LabeledContent("Format", value: document.kind.title)
                    LabeledContent(document.kind == .pptx ? "Folien" : "Seiten", value: "\(document.pageCount)")
                    LabeledContent("Zeichen", value: "\(document.characterCount)")
                    LabeledContent("Hinzugefügt", value: Formatters.date.string(from: document.importedAt))
                    LabeledContent("Analyse", value: document.analysisSource == .ai ? "KI (geprüft gegen das Material)" : "Lokal auf dem Gerät")
                }
                if !document.warnings.isEmpty {
                    Section("Hinweise zur Lesbarkeit") {
                        ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle").font(.subheadline)
                        }
                    }
                }
                Section {
                    if document.storedFileName != nil {
                        Button("Erneut verarbeiten", systemImage: "arrow.clockwise") { Task { await model.reprocessDocument(document.id) } }
                    }
                    Button("Dokument löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Beim Löschen bleiben Lernziele erhalten, zu denen du schon geübt hast. Fragen aus diesem Dokument werden entfernt.")
                }
            }
            .navigationTitle(document.fileName)
            .confirmationDialog("„\(document.fileName)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    model.deleteDocument(document.id)
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView("Dokument gelöscht", systemImage: "doc")
        }
    }
}

struct ManualTopicSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let examID: UUID
    @State private var title = ""
    @State private var objectives = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Thema, z. B. Zellteilung", text: $title)
                Section {
                    TextField("Ein Lernziel pro Zeile", text: $objectives, axis: .vertical).lineLimit(4...10)
                } header: {
                    Text("Lernziele (optional)")
                } footer: {
                    Text("Ohne Material kann LernFokus zu diesem Thema keine Fragen erzeugen. Es zählt aber zur Stoffabdeckung.")
                }
            }
            .navigationTitle("Thema anlegen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") {
                        model.addManualTopic(examID: examID, title: title, objectives: objectives.components(separatedBy: .newlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
