import LernKern
import SwiftUI

/// Fortschritt: Wissensstand, Notenprognose, verbleibende Lernzeit, Prüfungstauglichkeit, Schwächen.
struct ProgressOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedExamID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    if model.snapshot.exams.count > 1 {
                        Picker("Prüfung", selection: Binding(get: { selectedExamID ?? model.snapshot.exams.first?.id }, set: { selectedExamID = $0 })) {
                            ForEach(model.snapshot.exams) { Text($0.exam.title).tag(Optional($0.exam.id)) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let exam = current {
                        ExamProgressDetail(snapshot: exam)
                    } else {
                        ContentUnavailableView("Noch keine Daten", systemImage: "chart.line.uptrend.xyaxis",
                                               description: Text("Sobald du eine Prüfung angelegt und die ersten Fragen beantwortet hast, siehst du hier deinen Fortschritt."))
                    }
                }
                .padding()
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fortschritt")
        }
    }

    private var current: ExamSnapshot? {
        if let id = selectedExamID, let s = model.snapshot.exam(id) { return s }
        return model.snapshot.exams.first
    }
}

struct ExamProgressDetail: View {
    @Environment(AppModel.self) private var model
    let snapshot: ExamSnapshot
    @State private var explanation: ExplanationTopic?
    @State private var confirmTarget: GoalScenario?

    enum ExplanationTopic: String, Identifiable {
        case progress, forecast, time, readiness, rewards
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            progressCard
            forecastCard
            timeCard
            readinessCard
            if !snapshot.weaknesses.isEmpty { weaknessCard }
            topicsCard
            Button("Prüfungssimulation starten", systemImage: "timer") { Task { await model.startSimulation(examID: snapshot.exam.id) } }
                .buttonStyle(SecondaryButtonStyle())
            calibrationCard
        }
        .sheet(item: $explanation) { CalculationExplanationSheet(topic: $0) }
        .confirmationDialog("Zielnote ändern?", isPresented: Binding(get: { confirmTarget != nil }, set: { if !$0 { confirmTarget = nil } }), titleVisibility: .visible) {
            if let scenario = confirmTarget, let gradeID = scenario.suggestedGradeID {
                Button("Ziel auf \(snapshot.exam.gradeScale.band(id: gradeID)?.label ?? gradeID) ändern") {
                    var exam = snapshot.exam
                    exam.targetGradeID = gradeID
                    model.updateExam(exam)
                }
            }
        } message: {
            Text("Das ist deine Entscheidung. Du kannst das Ziel jederzeit wieder ändern.")
        }
    }

    private var progressCard: some View {
        let p = snapshot.progress
        return Card {
            HStack(spacing: 16) {
                ProgressRing(fraction: p.fraction, label: "\(p.percent) %", size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lernfortschritt").font(.headline)
                    Text("\(p.completeCount) von \(p.objectiveCount) Lernzielen stabil beherrscht").font(.subheadline).foregroundStyle(.secondary)
                    levelBar(p)
                }
            }
            if !p.missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.isComplete ? "" : "Bis 100 % fehlt noch:").font(.subheadline.weight(.medium))
                    ForEach(p.missing) { item in
                        Label(item.text, systemImage: "circle.dashed").font(.subheadline)
                    }
                }
            }
            explainButton(.progress)
        }
    }

    private func levelBar(_ p: ExamProgress) -> some View {
        let total = max(1, p.objectiveCount)
        let levels: [MasteryLevel] = [.stable, .provisional, .learned, .notStarted]
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(levels, id: \.self) { level in
                        let count = p.levelCounts[level] ?? 0
                        if count > 0 {
                            Rectangle().fill(level.tint.opacity(level == .notStarted ? 0.3 : 1))
                                .frame(width: max(2, geo.size.width * CGFloat(count) / CGFloat(total) - 2))
                        }
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(levels, id: \.self) { level in
                    Text("\(level.title): \(p.levelCounts[level] ?? 0)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var forecastCard: some View {
        let f = snapshot.forecast
        return Card {
            CardTitle(title: "Notenprognose", symbol: "graduationcap", trailing: f.confidence.title)
            Text(f.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if f.confidence != .insufficient {
                HStack(spacing: 10) {
                    MetricTile(title: "Wenn die Prüfung heute wäre", value: "\(Int((f.expectedScore * 100).rounded())) %", detail: "Spanne \(Int((f.scoreLow * 100).rounded()))–\(Int((f.scoreHigh * 100).rounded())) %")
                    MetricTile(title: "Ziel \(f.targetBand.label)", value: f.targetLikelihood == .unknown ? "–" : f.targetLikelihood.text, detail: "Chance auf Zielnote")
                }
            }
            ForEach(f.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            explainButton(.forecast)
        }
    }

    private var timeCard: some View {
        let t = snapshot.time
        return Card {
            CardTitle(title: "Verbleibende Lernzeit", symbol: "clock", trailing: t.feasibility.title)
            Text(t.headline).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Erste ausreichende Beherrschung", value: t.toProvisional.text)
                LabeledContent("Stabile Beherrschung", value: t.toStable.text)
                LabeledContent("Angestrebte Prüfungsleistung", value: t.toTarget?.text ?? "im Modell nicht erreichbar")
                LabeledContent("Verfügbar bis zur Prüfung", value: MinuteRange.approximate(t.availableMinutes))
            }
            .font(.subheadline)
            ForEach(t.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            if !t.scenarios.isEmpty {
                Divider()
                Text("Deine Möglichkeiten").font(.subheadline.weight(.semibold))
                ForEach(t.scenarios) { scenario in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scenario.title).font(.subheadline.weight(.medium))
                        Text(scenario.detail).font(.footnote).foregroundStyle(.secondary)
                        switch scenario.kind {
                        case .moreTime:
                            NavigationLink("Lernzeiten anpassen") { StudyTimesView() }.font(.footnote)
                        case .adjustTarget:
                            Button("Ziel ändern …") { confirmTarget = scenario }.font(.footnote)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            explainButton(.time)
        }
    }

    private var readinessCard: some View {
        let r = snapshot.readiness
        return Card {
            CardTitle(title: "Prüfungstauglichkeit", symbol: "checkmark.shield", trailing: r.score.map { "\($0) / 100" } ?? "–")
            Text(r.headline).font(.subheadline).foregroundStyle(.secondary)
            ForEach(r.components) { component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(component.title).font(.subheadline)
                        Spacer()
                        Text(component.value.map { "\(Int(($0 * 100).rounded())) %" } ?? "noch keine Daten").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    LinearBar(fraction: component.value ?? 0, tint: component.value == nil ? .secondary : .accentColor)
                }
            }
            explainButton(.readiness)
        }
    }

    private var weaknessCard: some View {
        Card {
            CardTitle(title: "Erkannte Schwächen", symbol: "magnifyingglass")
            ForEach(snapshot.weaknesses) { insight in
                VStack(alignment: .leading, spacing: 4) {
                    Text(insight.title).font(.subheadline.weight(.semibold))
                    Text(insight.detail).font(.footnote).foregroundStyle(.secondary)
                    Text(insight.suggestion).font(.footnote)
                    Button(isConfusion(insight) ? "Vergleichsübung starten" : "Gezielt üben") {
                        Task {
                            if isConfusion(insight) {
                                await model.startComparison(for: insight, examID: snapshot.exam.id)
                            } else {
                                await model.startPractice(examID: snapshot.exam.id, objectiveIDs: insight.objectiveIDs, kind: .practice)
                            }
                        }
                    }
                    .font(.footnote.weight(.medium))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func isConfusion(_ insight: WeaknessInsight) -> Bool {
        if case .confusion = insight.kind { return true }
        return false
    }

    private var topicsCard: some View {
        Card {
            CardTitle(title: "Themen", symbol: "square.stack.3d.up")
            ForEach(snapshot.progress.topics) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(topic.topic.title).font(.subheadline)
                        if topic.topic.importance == .core { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(topic.percent) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    LinearBar(fraction: topic.fraction)
                    if let forecast = snapshot.forecast.topics.first(where: { $0.topicID == topic.topic.id }), forecast.hasEvidence {
                        Text("Erwartet in der Prüfung: \(Int((forecast.expectedFraction * 100).rounded())) % der Punkte").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var calibrationCard: some View {
        if let outcome = snapshot.exam.outcome, let forecastID = outcome.forecastGradeID {
            Card {
                CardTitle(title: "Wie genau war die Prognose?", symbol: "scope")
                Text("Prognose: \(forecastID) · Tatsächlich: \(outcome.actualGradeID)").font(.subheadline)
            }
        }
    }

    private func explainButton(_ topic: ExplanationTopic) -> some View {
        Button("Wie wird das berechnet?") { explanation = topic }.font(.footnote)
    }
}

/// Transparenter Lerncoach: Erklärungen der Berechnungen in einfacher Sprache.
struct CalculationExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let topic: ExamProgressDetail.ExplanationTopic

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs, id: \.self) { Text($0) }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    private var title: String {
        switch topic {
        case .progress: return "Lernfortschritt"
        case .forecast: return "Notenprognose"
        case .time: return "Zeitprognose"
        case .readiness: return "Prüfungstauglichkeit"
        case .rewards: return "Belohnungen"
        }
    }

    private var paragraphs: [String] {
        switch topic {
        case .progress:
            return [
                "Der Lernfortschritt zeigt, wie viele Kriterien für „beherrscht“ du je Lernziel schon erfüllst – gewichtet nach Wichtigkeit und, falls bekannt, Prüfungsanteil der Themen.",
                "Vorläufig beherrscht: mindestens 3 richtige Antworten ohne Hilfe, 2 verschiedene Fragen, sichere Lösung mittelschwerer Aufgaben und 2 von 3 zuletzt richtig.",
                "Stabil beherrscht: zusätzlich eine richtige Antwort an einem anderen Tag (mind. 20 Stunden später) und eine richtig gelöste schwierigere oder Transferaufgabe.",
                "100 % gibt es nur, wenn JEDES Lernziel stabil beherrscht und das Wissen aktuell präsent ist. Ein sehr gutes Thema kann Lücken in einem anderen nicht ausgleichen.",
                "Das Öffnen von Material oder das Durchklicken von Fragen erhöht den Fortschritt nicht. Bereits erreichte Stufen gehen nicht verloren; wenn Wissen verblasst, wird eine kurze Wiederholung fällig.",
            ]
        case .forecast:
            return [
                "Die Prognose beantwortet: Welche Note würdest du ungefähr erreichen, wenn die Prüfung heute wäre?",
                "Grundlage: deine geschätzte Lösungswahrscheinlichkeit je Lernziel bei prüfungstypischer Schwierigkeit, abgeschwächt durch Vergessen, deine Leistung bei neuen Fragen und die Ergebnisse aktueller Prüfungssimulationen.",
                "Die Spanne zeigt die Unsicherheit. Sie ist größer, wenn wenige Daten vorliegen, viele Themen noch nicht geübt sind oder die Notengrenzen nur geschätzt sind.",
                "Eine Chance in Prozent wird nur bei hoher Sicherheit angezeigt, sonst eine grobe Einschätzung oder gar keine. Eine Prognose ist nie eine Garantie.",
                "Die Prognose wird nie verändert, um mehr oder weniger Bildschirmzeit zu vergeben.",
            ]
        case .time:
            return [
                "Die Zeitprognose beruht nicht auf Seitenzahlen, sondern auf den noch offenen Lernzielen, deinem Tempo (Sekunden pro Frage), deiner Erfolgsquote und den nötigen Wiederholungen.",
                "Für die Zielnote wählt das Modell die Lernziele mit dem größten Punktgewinn pro Minute zuerst.",
                "Angezeigt wird eine Spanne. Bei wenigen Daten ist sie bewusst breit.",
                "Reicht die verfügbare Zeit nicht, zeigt LernFokus ehrliche Möglichkeiten – das Ziel wird nie heimlich geändert.",
            ]
        case .readiness:
            return [
                "Die Prüfungstauglichkeit misst, wie gut du auf DIESE Prüfung vorbereitet bist – anders als der Lernfortschritt, der erfüllte Lernkriterien zählt.",
                "Sie setzt sich zusammen aus Stoffabdeckung (25 %), Behalten (20 %), Leistung bei neuen Fragen (20 %), letzter Prüfungssimulation (25 %) und Beständigkeit (10 %).",
                "Ohne aktuelle Simulation ist der Wert auf 85 begrenzt, weil Prüfungsbedingungen noch nicht geprüft wurden.",
            ]
        case .rewards:
            return [
                "Bildschirmzeit gibt es nur für geprüfte Lernleistung – nie für das Öffnen der App.",
                "Eine bestandene Wissensüberprüfung bringt 5–10 Minuten, abhängig von Genauigkeit und Umfang. Dazu kommen Boni für neu beherrschte Lernziele, Wiederholungen nach zeitlichem Abstand und messbare Verbesserung.",
                "Zu schnelle Antworten und kürzlich schon richtig beantwortete Fragen zählen nicht. Leichte Fragen zu bereits stabilem Wissen zählen kaum.",
                "Wer noch weit vom Ziel entfernt ist, besteht Überprüfungen schon ab 50 %; nah am Ziel werden anspruchsvolle Aufgaben stärker belohnt. Ist das Ziel sicher erreicht, genügt täglich eine kurze Wiederholung.",
                "Bei 100 % sind deine gesperrten Apps bis Mitternacht frei.",
            ]
        }
    }
}
