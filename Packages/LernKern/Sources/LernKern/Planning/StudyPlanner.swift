import Foundation

/// Warum neu geplant wird (vom Aufrufer bekannt). Weitere Gründe erkennt der Planer selbst.
public enum ReplanTrigger: Hashable, Sendable {
    case initial
    case routine
    case newMaterial(examTitle: String, newObjectives: Int)
    case examDateChanged(examTitle: String)
    case targetChanged(examTitle: String)
    case preferencesChanged
    case taskMovedByUser

    var reason: String? {
        switch self {
        case .initial: return "Lernplan erstellt."
        case .routine: return nil
        case .newMaterial(let title, let n): return n > 0 ? "Neue Unterlagen für \(title): \(n) neue Lernziele eingeplant." : "Neue Unterlagen für \(title) berücksichtigt."
        case .examDateChanged(let title): return "Prüfungstermin von \(title) geändert – Plan angepasst."
        case .targetChanged(let title): return "Zielnote für \(title) geändert – Schwerpunkte angepasst."
        case .preferencesChanged: return "Deine verfügbaren Lernzeiten haben sich geändert."
        case .taskMovedByUser: return "Du hast eine Einheit verschoben – der restliche Plan wurde darauf abgestimmt."
        }
    }
}

public struct PlanWarning: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case insufficientTime, overlappingExams, noObjectives, examToday }
    public var id: String { "\(kind.rawValue)-\(examID?.uuidString ?? "")" }
    public var kind: Kind
    public var examID: UUID?
    public var text: String
}

public struct PlanResult: Sendable {
    /// Vollständige neue Aufgabenliste (Vergangenheit + Zukunft).
    public var tasks: [StudyTask]
    public var change: PlanChangeEntry
    public var warnings: [PlanWarning]
    /// Pro Prüfung: Minuten, die bis zur Prüfung nicht mehr unterzubringen waren.
    public var unplacedMinutes: [UUID: Int]
}

/// Erstellt und aktualisiert den Lernplan.
///
/// Grundsätze:
/// - Schwerpunkt auf noch nicht beherrschte, wichtige und schwierige Lernziele (nicht gleichmäßig nach Kapiteln).
/// - Active Recall: jede Einheit endet mit einer Wissensüberprüfung.
/// - Verteiltes Wiederholen: nach dem Lernen Wiederholungen am Folgetag und nach einigen Tagen;
///   fällige Wiederholungen aus dem Gedächtnismodell haben Vorrang.
/// - Prüfungssimulationen und Fehleranalyse vor der Prüfung, Prüfungsmodus in den letzten Tagen.
/// - Puffer bleibt frei; verpasste Einheiten werden ohne Überladung neu verteilt.
/// - Vom Nutzer verschobene (angeheftete), erledigte und laufende Einheiten bleiben unverändert.
public struct StudyPlanner: Sendable {
    public init() {}

    public static let examModeDays = 3

    // MARK: - Arbeitspakete

    struct WorkItem {
        var key: String
        var examID: UUID
        var kind: StudyTaskKind
        var objectiveIDs: [UUID]
        var topicIDs: [UUID]
        var minutes: Int
        var earliestDay: DayKey
        var dependsOn: String?
        var reason: String
        var title: String
        var detail: String
        var isPeripheral: Bool
        var mergeable: Bool
        /// Nach dem Platzieren automatisch Wiederholungen einplanen (Tage nach dem Lerntag).
        var followUpReviewOffsets: [Int]
    }

    public func plan(
        state: AppState,
        knowledge: [UUID: ObjectiveKnowledge],
        triggers: [ReplanTrigger],
        now: Date,
        calendar: Calendar
    ) -> PlanResult {
        let prefs = state.preferences
        let exams = state.activeExams(now: now, calendar: calendar)
        let today = DayKey(now, calendar: calendar)
        let planningStart = roundUp(now, minutes: 5, calendar: calendar)

        // 1. Bestehende Aufgaben aufteilen
        var kept: [StudyTask] = []
        var replaceable: [StudyTask] = []
        var newlyMissed = 0
        for var task in state.tasks {
            if !exams.contains(where: { $0.id == task.examID }) {
                // Prüfung vorbei/archiviert: offene Zukunftsaufgaben entfallen, Vergangenheit bleibt.
                if task.start < now || !task.isOpen { kept.append(task) }
                continue
            }
            switch task.status {
            case .completed, .skipped, .missed, .inProgress:
                kept.append(task)
            case .planned:
                if task.end <= now {
                    task.status = .missed
                    newlyMissed += 1
                    kept.append(task)
                } else if task.isPinned || task.start < now {
                    kept.append(task)
                } else {
                    replaceable.append(task)
                }
            }
        }

        // 2. Arbeitspakete je Prüfung
        var queues: [UUID: [WorkItem]] = [:]
        var warnings: [PlanWarning] = []
        var extraPracticeFor: [String] = []
        for exam in exams {
            let days = exam.daysUntilExam(from: now, calendar: calendar)
            let objectives = state.objectives(for: exam.id)
            if objectives.isEmpty {
                warnings.append(PlanWarning(kind: .noObjectives, examID: exam.id, text: "\(exam.title): noch keine Lernziele – lade Unterlagen hoch, damit ein Plan entstehen kann."))
                continue
            }
            if days <= 0 {
                warnings.append(PlanWarning(kind: .examToday, examID: exam.id, text: "\(exam.title) ist heute. Viel Erfolg! Eine kurze Wiederholung der wichtigsten Begriffe genügt."))
                continue
            }
            let (items, struggling) = workItems(exam: exam, state: state, objectives: objectives, knowledge: knowledge, keptTasks: kept, today: today, days: days, now: now, calendar: calendar)
            queues[exam.id] = items
            extraPracticeFor.append(contentsOf: struggling)
        }

        // Nahe beieinander liegende Prüfungen
        let sortedExams = exams.sorted { $0.examDate < $1.examDate }
        for (a, b) in zip(sortedExams, sortedExams.dropFirst()) where abs(b.examDate.timeIntervalSince(a.examDate)) < 3 * 86_400 {
            warnings.append(PlanWarning(kind: .overlappingExams, examID: b.id, text: "\(a.title) und \(b.title) liegen nah beieinander. Die Lernzeit wird nach Dringlichkeit verteilt – fang früh mit beiden an."))
        }

        // Wenn die Zeit insgesamt knapp ist: Randthemen ans Ende (sie fallen zuerst weg).
        for exam in exams {
            guard var items = queues[exam.id] else { continue }
            let days = exam.daysUntilExam(from: now, calendar: calendar)
            let available = TimeEstimator().availableMinutes(preferences: prefs, from: now, days: days, completedTasks: kept, calendar: calendar)
            let demand = items.reduce(0) { $0 + $1.minutes }
            if demand > available {
                let core = items.filter { !$0.isPeripheral }
                let peripheral = items.filter { $0.isPeripheral }
                items = core + peripheral
                queues[exam.id] = items
            }
        }

        // 3. Tage füllen
        var placedByDay: [DayKey: [WorkItem]] = [:]
        var placedKeys: [String: DayKey] = [:]
        let lastExamDay = exams.map { DayKey($0.examDate, calendar: calendar) }.max() ?? today
        var day = today
        var guardDays = 0
        while day < lastExamDay && guardDays < 400 {
            guardDays += 1
            defer { day = day.adding(days: 1, calendar: calendar) }
            guard let dayStart = day.startDate(calendar: calendar) else { continue }
            let bufferMinutes = Double(prefs.minutes(on: dayStart, calendar: calendar)) * prefs.bufferShare
            var capacity = Double(prefs.minutes(on: dayStart, calendar: calendar)) * (1 - prefs.bufferShare)
            let keptMinutes = kept.filter { DayKey($0.start, calendar: calendar) == day && $0.status != .missed && $0.status != .skipped }
                .reduce(0) { $0 + $1.durationMinutes }
            capacity -= Double(keptMinutes)
            if day == today {
                let nowMinute = minuteOfDay(planningStart, calendar: calendar)
                let startMinute = max(prefs.startMinute(on: dayStart, calendar: calendar), nowMinute)
                capacity = min(capacity, Double(max(0, prefs.latestEndMinute - startMinute)) * 0.8)
            }
            guard capacity >= 10 else { continue }

            // Prüfungen, die an diesem Tag noch bevorstehen
            let open = exams.filter { DayKey($0.examDate, calendar: calendar) > day && !(queues[$0.id]?.isEmpty ?? true) }
            guard !open.isEmpty else { continue }
            var urgency: [UUID: Double] = [:]
            for exam in open {
                let left = max(1, dayCount(from: day, to: DayKey(exam.examDate, calendar: calendar), calendar: calendar))
                let work = Double(queues[exam.id]?.reduce(0) { $0 + $1.minutes } ?? 0)
                urgency[exam.id] = max(1, work) / Double(left)
            }
            let totalUrgency = urgency.values.reduce(0, +)

            var dayItems: [WorkItem] = []
            var leftover = 0.0
            for exam in open.sorted(by: { (urgency[$0.id] ?? 0) > (urgency[$1.id] ?? 0) }) {
                var budget = capacity * (urgency[exam.id] ?? 0) / totalUrgency + leftover
                leftover = 0
                let daysLeft = dayCount(from: day, to: DayKey(exam.examDate, calendar: calendar), calendar: calendar)
                let examMode = daysLeft <= Self.examModeDays
                var queue = queues[exam.id] ?? []
                if examMode { queue = prioritizeForExamMode(queue) }
                var remaining: [WorkItem] = []
                for var item in queue {
                    let dependencyOK = item.dependsOn.map { dep in placedKeys[dep].map { $0 <= day } ?? !queue.contains { $0.key == dep } } ?? true
                    guard item.earliestDay <= day, dependencyOK, budget >= 10 else { remaining.append(item); continue }
                    if examMode && item.kind == .learn && item.isPeripheral { remaining.append(item); continue }
                    if item.kind == .simulation {
                        // Simulationen dürfen den Puffer nutzen; passt die volle Dauer nicht, wird verkürzt.
                        let allowed = budget + bufferMinutes
                        if allowed >= 20 {
                            let minutes = min(item.minutes, Int(allowed / 5) * 5)
                            if minutes < item.minutes {
                                item.detail = "Verkürzte Simulation (\(minutes) statt \(item.minutes) Minuten), weil heute nicht mehr Lernzeit eingeplant ist. Gemischte Aufgaben, Lösungen erst am Ende."
                            }
                            item.minutes = minutes
                            budget = max(0, budget - Double(minutes))
                            dayItems.append(item)
                            placedKeys[item.key] = day
                        } else {
                            remaining.append(item)
                        }
                        continue
                    }
                    if Double(item.minutes) <= budget {
                        budget -= Double(item.minutes)
                        dayItems.append(item)
                        placedKeys[item.key] = day
                        // Wiederholungen nach dem Lernen
                        for offset in item.followUpReviewOffsets {
                            let reviewDay = day.adding(days: offset, calendar: calendar)
                            if reviewDay < DayKey(exam.examDate, calendar: calendar) {
                                remaining.append(reviewItem(exam: exam, objectiveIDs: item.objectiveIDs, topicIDs: item.topicIDs, earliest: reviewDay,
                                                            key: "rev:\(item.objectiveIDs.map(\.uuidString).joined()):\(offset)", projected: true, state: state))
                            }
                        }
                    } else if (item.kind == .learn || item.kind == .practice) && budget >= 10 && item.minutes > 15 {
                        // Großes Paket teilen
                        let part = Int(budget / 5) * 5
                        var first = item
                        first.minutes = part
                        first.key = item.key + ":a"
                        first.followUpReviewOffsets = []
                        item.minutes -= part
                        item.dependsOn = first.key
                        dayItems.append(first)
                        placedKeys[first.key] = day
                        budget -= Double(part)
                        remaining.append(item)
                    } else {
                        remaining.append(item)
                    }
                }
                leftover = max(0, budget)
                queues[exam.id] = stableOrder(remaining)
            }
            placedByDay[day] = mergeItems(dayItems, sessionMinutes: prefs.sessionMinutes)
        }

        // 4. Zeitfenster vergeben
        var newTasks: [StudyTask] = []
        var spill: [WorkItem] = []
        for (day, items) in placedByDay.sorted(by: { $0.key < $1.key }) {
            guard let dayStart = day.startDate(calendar: calendar) else { continue }
            let blocking = kept.filter { DayKey($0.start, calendar: calendar) == day && $0.status != .missed && $0.status != .skipped }
            let (tasks, overflow) = layout(items: items, day: day, dayStart: dayStart, blocking: blocking, earliest: day == today ? planningStart : nil, prefs: prefs, state: state, calendar: calendar)
            newTasks.append(contentsOf: tasks)
            spill.append(contentsOf: overflow)
        }

        // 5. IDs wiederverwenden (Kalendertermine bleiben verknüpft)
        var pool = replaceable
        var moved = 0
        for i in newTasks.indices {
            let t = newTasks[i]
            if let j = pool.firstIndex(where: { old in
                old.examID == t.examID && old.kind == t.kind && Set(old.objectiveIDs) == Set(t.objectiveIDs)
                    && DayKey(old.start, calendar: calendar) == DayKey(t.start, calendar: calendar) && old.part == t.part
            }) ?? pool.firstIndex(where: { old in
                old.examID == t.examID && old.kind == t.kind && Set(old.objectiveIDs) == Set(t.objectiveIDs) && old.part == t.part
            }) {
                newTasks[i].id = pool[j].id
                if pool[j].start != t.start || pool[j].durationMinutes != t.durationMinutes { moved += 1 }
                pool.remove(at: j)
            }
        }
        let added = newTasks.count - (replaceable.count - pool.count)
        let removed = pool.count

        // 6. Nicht untergebrachte Arbeit
        var unplaced: [UUID: Int] = [:]
        for (examID, items) in queues { unplaced[examID, default: 0] += items.filter { $0.kind != .review || !$0.key.hasPrefix("rev:") }.reduce(0) { $0 + $1.minutes } }
        for item in spill { unplaced[item.examID, default: 0] += item.minutes }
        for exam in exams {
            if let minutes = unplaced[exam.id], minutes >= 15 {
                warnings.append(PlanWarning(kind: .insufficientTime, examID: exam.id,
                                            text: "\(exam.title): Etwa \(MinuteRange.approximate(minutes)) Lernstoff passen nicht mehr bis zur Prüfung. Sieh dir die Möglichkeiten unter „Fortschritt“ an."))
            }
        }

        // 7. Begründungen
        var reasons = triggers.compactMap(\.reason)
        if newlyMissed > 0 {
            reasons.append("\(newlyMissed) verpasste Einheit\(newlyMissed == 1 ? "" : "en") wurde\(newlyMissed == 1 ? "" : "n") neu eingeplant, ohne die nächsten Tage zu überladen.")
        }
        for title in extraPracticeFor.prefix(3) {
            reasons.append("Zusätzliche Übung für „\(title)“, weil die letzten Antworten noch unsicher waren.")
        }
        let completedTitles = completedSinceLastPlan(replaceable: replaceable, knowledge: knowledge, state: state)
        for title in completedTitles.prefix(3) {
            reasons.append("„\(title)“ beherrschst du bereits sicher – geplante Übungen dazu entfallen.")
        }
        for w in warnings where w.kind == .insufficientTime { reasons.append(w.text) }

        let allTasks = (kept + newTasks).sorted { $0.start < $1.start }
        let change = PlanChangeEntry(date: now, reasons: reasons, added: max(0, added), removed: removed, moved: moved)
        return PlanResult(tasks: allTasks, change: change, warnings: warnings, unplacedMinutes: unplaced.filter { $0.value > 0 })
    }

    // MARK: - Arbeitspakete einer Prüfung

    func workItems(exam: Exam, state: AppState, objectives: [LearningObjective], knowledge: [UUID: ObjectiveKnowledge],
                   keptTasks: [StudyTask], today: DayKey, days: Int, now: Date, calendar: Calendar) -> ([WorkItem], [String]) {
        let topics = state.topics(for: exam.id)
        let topicByID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        let orderedTopics = topologicalOrder(topics)
        let topicRank = Dictionary(uniqueKeysWithValues: orderedTopics.enumerated().map { ($1.id, $0) })
        let ordered = objectives.sorted { (topicRank[$0.topicID] ?? 0, $0.order) < (topicRank[$1.topicID] ?? 0, $1.order) }
        let examDay = DayKey(exam.examDate, calendar: calendar)
        let speed = TimeEstimator().speedFactor(state.tasks.filter { $0.examID == exam.id })
        let keptCompletedToday = Set(keptTasks.filter { $0.examID == exam.id && $0.status == .completed && DayKey($0.start, calendar: calendar) == today }.flatMap(\.objectiveIDs))

        var items: [WorkItem] = []
        var struggling: [String] = []
        var dueReviews: [DayKey: [LearningObjective]] = [:]

        for o in ordered {
            let k = knowledge[o.id]
            let topic = topicByID[o.topicID]
            let difficultyBonus = (topic?.difficulty ?? 2) >= 3 ? 5 : 0
            let importanceBonus = o.importance == .core || topic?.importance == .core ? 5 : 0
            let peripheral = o.importance == .peripheral || topic?.importance == .peripheral
            let level = k?.level ?? .notStarted

            if k?.isComplete == true {
                if let due = k?.reviewDueAt, DayKey(due, calendar: calendar) < examDay {
                    dueReviews[max(today, DayKey(due, calendar: calendar)), default: []].append(o)
                }
                continue
            }
            switch level {
            case .notStarted:
                let learnKey = "learn:\(o.id)"
                let learnMinutes = max(10, round5(Double(o.estimatedMinutes) * speed))
                items.append(WorkItem(key: learnKey, examID: exam.id, kind: .learn, objectiveIDs: [o.id], topicIDs: [o.topicID],
                                      minutes: learnMinutes, earliestDay: today, dependsOn: nil,
                                      reason: "Neues Lernziel – zuerst verstehen, dann aktiv abrufen.",
                                      title: "Verstehen: \(o.title)", detail: learnDetail(o, state: state),
                                      isPeripheral: peripheral, mergeable: true, followUpReviewOffsets: []))
                items.append(WorkItem(key: "practice:\(o.id)", examID: exam.id, kind: .practice, objectiveIDs: [o.id], topicIDs: [o.topicID],
                                      minutes: 10 + difficultyBonus, earliestDay: today, dependsOn: learnKey,
                                      reason: "Aktives Abrufen direkt nach dem Lernen festigt das Verständnis.",
                                      title: "Üben: \(o.title)", detail: "Fragen ohne Unterlagen beantworten, Fehler direkt klären.",
                                      isPeripheral: peripheral, mergeable: true, followUpReviewOffsets: [1, 4]))
            case .learned:
                let isStruggling = k?.isStruggling == true
                if isStruggling { struggling.append(o.title) }
                let minutes = 15 + difficultyBonus + importanceBonus + (isStruggling ? 10 : 0)
                items.append(WorkItem(key: "practice:\(o.id)", examID: exam.id, kind: .practice, objectiveIDs: [o.id], topicIDs: [o.topicID],
                                      minutes: minutes, earliestDay: today, dependsOn: nil,
                                      reason: isStruggling ? "Zusätzliche Übung, weil die letzten Antworten noch unsicher waren – mit einfacheren Schritten."
                                                           : "Noch nicht sicher beherrscht – gezielt üben.",
                                      title: "Üben: \(o.title)", detail: isStruggling ? "Kleinere Schritte, zuerst leichtere Aufgaben, dann steigern." : "Aufgaben in unterschiedlichen Formulierungen beantworten.",
                                      isPeripheral: peripheral, mergeable: true, followUpReviewOffsets: [1, 4]))
            case .provisional, .stable:
                // Wiederholung nach zeitlichem Abstand bzw. schwierigere Aufgabe fehlt
                var earliest = today
                if k?.criterion(.spacedRecall)?.isMet == false, let last = k?.lastReviewAt {
                    earliest = max(today, DayKey(last.addingTimeInterval(20 * 3600), calendar: calendar))
                    if earliest == DayKey(last, calendar: calendar) { earliest = earliest.adding(days: 1, calendar: calendar) }
                } else if let due = k?.reviewDueAt {
                    earliest = max(today, DayKey(due, calendar: calendar))
                }
                if keptCompletedToday.contains(o.id) && earliest == today { earliest = today.adding(days: 1, calendar: calendar) }
                if earliest < examDay {
                    dueReviews[earliest, default: []].append(o)
                }
            }
        }

        // Fällige Wiederholungen bündeln
        for (day, objs) in dueReviews.sorted(by: { $0.key < $1.key }) {
            for chunk in stride(from: 0, to: objs.count, by: 5) {
                let group = Array(objs[chunk..<min(chunk + 5, objs.count)])
                items.append(reviewItem(exam: exam, objectiveIDs: group.map(\.id), topicIDs: Array(Set(group.map(\.topicID))), earliest: day,
                                        key: "due:\(day):\(chunk)", projected: false, state: state))
            }
        }

        // Gemischte Übungen und Simulationen
        let objectiveCount = objectives.count
        if objectiveCount >= 3 && days >= 4 {
            var d = 3
            while d < days - 1 {
                items.append(WorkItem(key: "mixed:\(d)", examID: exam.id, kind: .mixedPractice, objectiveIDs: [], topicIDs: [],
                                      minutes: 15, earliestDay: today.adding(days: d, calendar: calendar), dependsOn: nil,
                                      reason: "Gemischte Aufgaben aus mehreren Themen trainieren das Erkennen des richtigen Lösungswegs.",
                                      title: "Gemischte Übung", detail: "Aufgaben aus bereits gelernten Themen in zufälliger Reihenfolge.",
                                      isPeripheral: false, mergeable: false, followUpReviewOffsets: []))
                d += 4
            }
        }
        let recentSim = state.simulations.contains { $0.examID == exam.id && now.timeIntervalSince($0.finishedAt) < 3 * 86_400 }
        var simDays: [Int] = []
        if days >= 10 { simDays = [Int(Double(days) * 0.6), days - 2] }
        else if days >= 4 { simDays = [days - 2] }
        else if days >= 2 { simDays = [days - 1] }
        if recentSim, let first = simDays.first, first <= 2 { simDays.removeFirst() }
        let simMinutes = min(max(exam.durationMinutes ?? 45, 20), 120)
        for (i, d) in simDays.enumerated() {
            let simKey = "sim:\(i)"
            let simDay = today.adding(days: max(0, d), calendar: calendar)
            items.append(WorkItem(key: simKey, examID: exam.id, kind: .simulation, objectiveIDs: [], topicIDs: [],
                                  minutes: simMinutes, earliestDay: simDay, dependsOn: nil,
                                  reason: "Prüfungsbedingungen üben und die Notenprognose mit neuen, unbekannten Fragen absichern.",
                                  title: "Prüfungssimulation", detail: "Wie in der echten Prüfung: \(simMinutes) Minuten, gemischte Aufgaben, Lösungen erst am Ende.",
                                  isPeripheral: false, mergeable: false, followUpReviewOffsets: []))
            items.append(WorkItem(key: "err:\(i)", examID: exam.id, kind: .errorAnalysis, objectiveIDs: [], topicIDs: [],
                                  minutes: 15, earliestDay: simDay, dependsOn: simKey,
                                  reason: "Fehler aus der Simulation verstehen, bevor sie sich festsetzen.",
                                  title: "Fehler analysieren", detail: "Falsch beantwortete Aufgaben der Simulation durchgehen und die Erklärung lesen.",
                                  isPeripheral: false, mergeable: false, followUpReviewOffsets: []))
        }
        return (stableOrder(items), struggling)
    }

    func reviewItem(exam: Exam, objectiveIDs: [UUID], topicIDs: [UUID], earliest: DayKey, key: String, projected: Bool, state: AppState) -> WorkItem {
        let titles = objectiveIDs.compactMap { id in state.objectives.first { $0.id == id }?.title }
        return WorkItem(key: key, examID: exam.id, kind: .review, objectiveIDs: objectiveIDs, topicIDs: topicIDs,
                        minutes: max(10, min(20, objectiveIDs.count * 4)), earliestDay: earliest, dependsOn: nil,
                        reason: projected ? "Wiederholung nach zeitlichem Abstand – so bleibt das Gelernte im Langzeitgedächtnis."
                                          : "Laut Vergessenskurve ist jetzt eine Wiederholung fällig.",
                        title: "Wiederholen: " + (titles.count <= 2 ? titles.joined(separator: ", ") : "\(titles[0]) und \(titles.count - 1) weitere"),
                        detail: "Kurze Abfrage ohne Unterlagen. Lernziele: " + titles.joined(separator: ", ") + ".",
                        isPeripheral: false, mergeable: true, followUpReviewOffsets: [])
    }

    func learnDetail(_ o: LearningObjective, state: AppState) -> String {
        var parts: [String] = []
        if !o.detail.isEmpty { parts.append(o.detail) }
        if !o.keyTerms.isEmpty { parts.append("Begriffe: " + o.keyTerms.prefix(5).joined(separator: ", ") + ".") }
        parts.append("Anschließend kurze Wissensüberprüfung.")
        return parts.joined(separator: " ")
    }

    /// Prüfungsmodus: Simulationen, Wiederholungen und Fehleranalyse zuerst.
    func prioritizeForExamMode(_ queue: [WorkItem]) -> [WorkItem] {
        func rank(_ k: StudyTaskKind) -> Int {
            switch k {
            case .simulation: return 0
            case .review: return 1
            case .errorAnalysis: return 2
            case .practice: return 3
            case .mixedPractice: return 4
            case .learn: return 5
            }
        }
        return queue.enumerated().sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
    }

    /// Fällige Wiederholungen und Simulationen vor neuem Stoff, sonst Reihenfolge beibehalten.
    func stableOrder(_ items: [WorkItem]) -> [WorkItem] {
        func rank(_ k: StudyTaskKind) -> Int { k == .review || k == .simulation || k == .errorAnalysis ? 0 : 1 }
        return items.enumerated().sorted { a, b in
            let ra = rank(a.element.kind)
            let rb = rank(b.element.kind)
            if ra != rb { return ra < rb }
            if ra == 0 && a.element.earliestDay != b.element.earliestDay { return a.element.earliestDay < b.element.earliestDay }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Kleine Pakete desselben Typs und Themas zu einer Einheit zusammenfassen.
    func mergeItems(_ items: [WorkItem], sessionMinutes: Int) -> [WorkItem] {
        var result: [WorkItem] = []
        for item in items {
            // Verstehen + direkt anschließendes Üben desselben Lernziels = eine Einheit mit Überprüfung am Ende.
            if var last = result.last, last.kind == .learn, item.kind == .practice, last.examID == item.examID,
               Set(item.objectiveIDs).isSubset(of: Set(last.objectiveIDs)), last.minutes + item.minutes <= sessionMinutes {
                last.minutes += item.minutes
                last.key += "+" + item.key
                last.title = last.title.replacingOccurrences(of: "Verstehen: ", with: "Verstehen & üben: ")
                last.detail += " Danach Fragen ohne Unterlagen beantworten."
                last.followUpReviewOffsets = item.followUpReviewOffsets
                last.mergeable = false
                result[result.count - 1] = last
                continue
            }
            if var last = result.last, last.mergeable, item.mergeable, last.kind == item.kind, last.examID == item.examID,
               (last.kind == .review || Set(last.topicIDs) == Set(item.topicIDs)),
               last.minutes + item.minutes <= sessionMinutes, last.objectiveIDs.count < 4 {
                last.objectiveIDs += item.objectiveIDs
                last.topicIDs = Array(Set(last.topicIDs + item.topicIDs))
                last.minutes += item.minutes
                last.key += "+" + item.key
                last.title = mergedTitle(last.kind, count: last.objectiveIDs.count, first: last.title)
                last.detail += " " + item.detail
                result[result.count - 1] = last
            } else {
                result.append(item)
            }
        }
        return result
    }

    func mergedTitle(_ kind: StudyTaskKind, count: Int, first: String) -> String {
        let base = first.components(separatedBy: " (+").first ?? first
        return count > 1 ? "\(base) (+\(count - 1))" : base
    }

    // MARK: - Uhrzeiten

    func layout(items: [WorkItem], day: DayKey, dayStart: Date, blocking: [StudyTask], earliest: Date?, prefs: StudyPreferences,
                state: AppState, calendar: Calendar) -> ([StudyTask], [WorkItem]) {
        var cursorMinute = prefs.startMinute(on: dayStart, calendar: calendar)
        if let earliest {
            cursorMinute = max(cursorMinute, minuteOfDay(earliest, calendar: calendar))
        }
        let busy = blocking.map { (minuteOfDay($0.start, calendar: calendar), minuteOfDay($0.start, calendar: calendar) + $0.durationMinutes) }.sorted { $0.0 < $1.0 }
        var tasks: [StudyTask] = []
        var overflow: [WorkItem] = []
        var blocksSinceLongBreak = 0

        for item in items {
            // Längere Pakete (außer Simulationen) in Einheiten der Sitzungslänge aufteilen
            let chunks: [Int]
            if item.kind == .simulation || item.minutes <= prefs.sessionMinutes {
                chunks = [item.minutes]
            } else {
                var rest = item.minutes
                var list: [Int] = []
                while rest > 0 {
                    let c = min(prefs.sessionMinutes, rest)
                    list.append(c)
                    rest -= c
                }
                if list.count > 1, let last = list.last, last < 10 { list.removeLast(); list[list.count - 1] += last }
                chunks = list
            }
            for (index, minutes) in chunks.enumerated() {
                // Belegte Zeiten überspringen
                var moved = true
                while moved {
                    moved = false
                    for (s, e) in busy where cursorMinute < e && cursorMinute + minutes > s {
                        cursorMinute = e + prefs.shortBreakMinutes
                        moved = true
                    }
                }
                if cursorMinute + minutes > prefs.latestEndMinute {
                    var rest = item
                    rest.minutes = chunks[index...].reduce(0, +)
                    overflow.append(rest)
                    break
                }
                guard let start = calendar.date(byAdding: .minute, value: cursorMinute, to: dayStart) else { continue }
                let multi = chunks.count > 1
                tasks.append(StudyTask(
                    examID: item.examID, kind: item.kind,
                    title: multi ? "\(item.title) (Teil \(index + 1)/\(chunks.count))" : item.title,
                    detail: item.detail, objectiveIDs: item.objectiveIDs, topicIDs: item.topicIDs,
                    start: start, durationMinutes: minutes, reason: item.reason,
                    part: multi ? index + 1 : nil, partsTotal: multi ? chunks.count : nil
                ))
                cursorMinute += minutes
                blocksSinceLongBreak += 1
                if blocksSinceLongBreak >= prefs.blocksBeforeLongBreak {
                    cursorMinute += prefs.longBreakMinutes
                    blocksSinceLongBreak = 0
                } else {
                    cursorMinute += prefs.shortBreakMinutes
                }
            }
        }
        return (tasks, overflow)
    }

    // MARK: - Hilfsfunktionen

    func completedSinceLastPlan(replaceable: [StudyTask], knowledge: [UUID: ObjectiveKnowledge], state: AppState) -> [String] {
        let ids = Set(replaceable.filter { $0.kind == .learn || $0.kind == .practice }.flatMap(\.objectiveIDs))
        return ids.compactMap { id in
            guard knowledge[id]?.level ?? .notStarted >= .provisional else { return nil }
            return state.objectives.first { $0.id == id }?.title
        }.sorted()
    }

    func topologicalOrder(_ topics: [Topic]) -> [Topic] {
        var remaining = topics.sorted { $0.order < $1.order }
        var result: [Topic] = []
        var placed: Set<UUID> = []
        let ids = Set(topics.map(\.id))
        while !remaining.isEmpty {
            if let index = remaining.firstIndex(where: { t in t.prerequisiteTopicIDs.filter { ids.contains($0) }.allSatisfy { placed.contains($0) } }) {
                let t = remaining.remove(at: index)
                result.append(t)
                placed.insert(t.id)
            } else {
                // Zyklus: in Dokumentreihenfolge fortfahren
                let t = remaining.removeFirst()
                result.append(t)
                placed.insert(t.id)
            }
        }
        return result
    }

    func dayCount(from: DayKey, to: DayKey, calendar: Calendar) -> Int {
        guard let a = from.startDate(calendar: calendar), let b = to.startDate(calendar: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    func roundUp(_ date: Date, minutes: Int, calendar: Calendar) -> Date {
        let m = calendar.component(.minute, from: date)
        let s = calendar.component(.second, from: date)
        let add = (minutes - m % minutes) % minutes
        let base = calendar.date(byAdding: .second, value: -s, to: date) ?? date
        return add == 0 && s == 0 ? date : calendar.date(byAdding: .minute, value: add == 0 ? minutes : add, to: base) ?? date
    }

    func round5(_ v: Double) -> Int { max(5, Int((v / 5).rounded()) * 5) }
}
