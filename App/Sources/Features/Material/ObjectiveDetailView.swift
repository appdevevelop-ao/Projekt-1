import LernKern
import SwiftUI

/// Ein Lernziel im Detail: Was fehlt noch bis "beherrscht"? Woher stammt es?
struct ObjectiveDetailView: View {
    @Environment(AppModel.self) private var model
    let objectiveID: UUID
    @State private var editingTopic: Topic?

    var body: some View {
        if let objective = model.state.objectives.first(where: { $0.id == objectiveID }) {
            let knowledge = model.snapshot.knowledge[objective.id]
            List {
                Section {
                    if !objective.detail.isEmpty { Text(objective.detail) }
                    HStack {
                        LevelBadge(level: knowledge?.level ?? .notStarted)
                        OriginBadge(origin: objective.origin, status: objective.reviewStatus)
                    }
                    if objective.reviewStatus == .suggested {
                        HStack {
                            Button("Bestätigen") { model.setObjectiveStatus(objective.id, .confirmed) }
                            Spacer()
                            Button("Nicht prüfungsrelevant", role: .destructive) { model.setObjectiveStatus(objective.id, .rejected) }
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Jetzt üben", systemImage: "play.fill") {
                        Task { await model.startPractice(examID: objective.examID, objectiveIDs: [objective.id], kind: knowledge == nil || knowledge?.level == .notStarted ? .learn : .practice) }
                    }
                }
                if let knowledge {
                    Section {
                        ForEach(knowledge.criteria, id: \.id) { criterion in
                            HStack(alignment: .top) {
                                Image(systemName: criterion.isMet ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(criterion.isMet ? Theme.success : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(criterion.title)
                                    if let hint = criterion.remainingHint, !criterion.isMet {
                                        Text(hint).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(Int((criterion.progress * 100).rounded())) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Was bis „stabil beherrscht“ fehlt")
                    } footer: {
                        Text(footer(knowledge))
                    }
                }
                let terms = model.state.terms.filter { $0.objectiveID == objective.id }
                if !terms.isEmpty {
                    Section("Begriffe aus deinen Unterlagen") {
                        ForEach(terms) { term in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(term.term).font(.headline)
                                Text(term.definition).font(.subheadline)
                                if let page = term.source.page { Text("S. \(page)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                let questions = model.state.activeQuestions(for: objective.id)
                Section("Übungsfragen") {
                    LabeledContent("Anzahl", value: "\(questions.count)")
                    LabeledContent("Leicht · Mittel · Schwer", value: "\(questions.filter { $0.difficulty == .easy }.count) · \(questions.filter { $0.difficulty == .medium }.count) · \(questions.filter { $0.difficulty == .hard }.count)")
                    if questions.isEmpty {
                        Text(model.state.settings.isAIUsable ? "Beim Üben werden Fragen erzeugt." : "Ohne KI-Dienst entstehen Fragen nur aus erkannten Definitionen und Sätzen.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let topic = model.state.topics.first(where: { $0.id == objective.topicID }) {
                    Section("Thema") {
                        LabeledContent("Thema", value: topic.title)
                        LabeledContent("Wichtigkeit", value: topic.importance.title)
                        if let weight = topic.examWeight { LabeledContent("Prüfungsanteil", value: "\(Int((weight * 100).rounded())) %") }
                        Button("Thema bearbeiten") { editingTopic = topic }
                    }
                }
            }
            .navigationTitle(objective.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingTopic) { TopicEditorSheet(topic: $0) }
        } else {
            ContentUnavailableView("Lernziel nicht gefunden", systemImage: "questionmark")
        }
    }

    private func footer(_ k: ObjectiveKnowledge) -> String {
        var parts = ["\(k.attemptCount) Antworten bisher."]
        if let due = k.reviewDueAt {
            parts.append(due <= Date() ? "Wiederholung fällig." : "Nächste Wiederholung: \(Formatters.relativeDay(due)).")
        }
        parts.append("Ein Lernziel gilt erst als beherrscht, wenn es mit verschiedenen Fragen, ohne Hilfe, nach zeitlichem Abstand und bei einer schwierigeren Aufgabe gelingt.")
        return parts.joined(separator: " ")
    }
}

struct TopicEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var topic: Topic
    @State private var hasWeight = false
    @State private var weightPercent = 20.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titel", text: $topic.title)
                Picker("Wichtigkeit", selection: $topic.importance) {
                    ForEach(Importance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Schwierigkeit", selection: $topic.difficulty) {
                    Text("Leicht").tag(1)
                    Text("Mittel").tag(2)
                    Text("Schwer").tag(3)
                }
                Section {
                    Toggle("Prüfungsanteil bekannt", isOn: $hasWeight)
                    if hasWeight {
                        Stepper("\(Int(weightPercent)) % der Prüfung", value: $weightPercent, in: 1...100, step: 1)
                    }
                } footer: {
                    Text("Wenn bekannt ist, wie viel ein Thema in der Prüfung zählt, gewichtet LernFokus Fortschritt und Prognose entsprechend.")
                }
            }
            .navigationTitle("Thema bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        topic.examWeight = hasWeight ? weightPercent / 100 : nil
                        topic.reviewStatus = .confirmed
                        model.updateTopic(topic)
                        dismiss()
                    }
                }
            }
            .onAppear {
                hasWeight = topic.examWeight != nil
                weightPercent = (topic.examWeight ?? 0.2) * 100
            }
        }
    }
}
