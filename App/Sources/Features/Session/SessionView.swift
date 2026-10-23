import LernKern
import SwiftUI

/// Lernsitzung im Vollbild: Material → Fragen → Auswertung. Jeder Schritt wird sofort gespeichert.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @State private var summary: SessionSummary?
    @State private var showExitDialog = false

    var body: some View {
        NavigationStack {
            Group {
                if let session = model.session {
                    switch session.phase {
                    case .learning:
                        LearningMaterialView(session: session)
                    case .questions:
                        if session.isFinishedAnswering || session.questionIDs.isEmpty {
                            finishingView(session)
                        } else {
                            QuestionFlowView(session: session, onFinish: finish)
                        }
                    case .summary:
                        if let summary {
                            SessionSummaryView(summary: summary, session: session)
                        } else {
                            ProgressView().onAppear { summary = model.finishSession() }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.session?.phase != .summary {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { showExitDialog = true } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Einheit beenden")
                    }
                }
            }
            .confirmationDialog("Einheit beenden?", isPresented: $showExitDialog, titleVisibility: .visible) {
                if !(model.session?.attemptIDs.isEmpty ?? true) {
                    Button("Beenden und auswerten") { finish() }
                }
                Button("Ohne Auswertung verlassen", role: .destructive) { model.abandonSession() }
                Button("Weiterlernen", role: .cancel) {}
            } message: {
                Text("Deine bisherigen Antworten bleiben gespeichert und zählen für deinen Wissensstand. Bildschirmzeit gibt es für abgeschlossene Überprüfungen.")
            }
        }
        .interactiveDismissDisabled()
    }

    private var title: String {
        guard let session = model.session else { return "" }
        switch session.mode {
        case .simulation: return "Prüfungssimulation"
        case .practice: return session.kind.title
        }
    }

    @ViewBuilder
    private func finishingView(_ session: StudySessionState) -> some View {
        if session.questionIDs.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Fragen", systemImage: "questionmark.folder")
            } description: {
                Text("Für dieses Lernziel gibt es noch keine Übungsfragen. Mit dem KI-Dienst können Fragen erzeugt werden, oder lade Material mit Definitionen hoch.")
            } actions: {
                Button("Schließen") { model.abandonSession() }
            }
        } else {
            ProgressView("Auswertung …").onAppear { finish() }
        }
    }

    private func finish() {
        summary = model.finishSession()
    }
}

/// Lernmaterial zum Verstehen (vor den Fragen).
struct LearningMaterialView: View {
    @Environment(AppModel.self) private var model
    let session: StudySessionState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Lies dir die Inhalte in Ruhe durch. Danach beantwortest du Fragen ohne Unterlagen – so verankerst du das Wissen am besten.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(objectives) { objective in
                    ObjectiveMaterialCard(objective: objective)
                }
                Button("Ich bin bereit – Fragen beantworten") { model.beginQuestions() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var objectives: [LearningObjective] {
        session.objectiveIDs.compactMap { id in model.state.objectives.first { $0.id == id } }
    }
}

struct ObjectiveMaterialCard: View {
    @Environment(AppModel.self) private var model
    let objective: LearningObjective
    @State private var expanded = false

    var body: some View {
        Card {
            CardTitle(title: objective.title, symbol: "book")
            if !objective.detail.isEmpty { Text(objective.detail).foregroundStyle(.secondary) }
            let terms = model.state.terms.filter { $0.objectiveID == objective.id }
            if !terms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(terms) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.term).font(.headline)
                            Text(term.definition).font(.body)
                            if let page = term.source.page { Text("S. \(page)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            let chunks = model.chunks(ids: objective.sourceChunkIDs, examID: objective.examID)
            if chunks.isEmpty {
                Text("Zu diesem Lernziel gibt es noch kein Material. Lade passende Unterlagen hoch.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(expanded ? chunks : Array(chunks.prefix(1))) { chunk in
                    VStack(alignment: .leading, spacing: 4) {
                        Text([chunk.sectionPath.joined(separator: " › "), chunk.pageLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(chunk.text).font(.callout).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                if chunks.count > 1 {
                    Button(expanded ? "Weniger anzeigen" : "Alle \(chunks.count) Abschnitte anzeigen") { expanded.toggle() }.font(.footnote)
                }
            }
        }
    }
}
