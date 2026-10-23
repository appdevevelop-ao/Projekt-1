import XCTest
@testable import LernKern

final class CalendarSyncTests: XCTestCase {
    let cal = TestCalendar.make()

    func task(_ hour: Int, day: Int = 24, title: String = "Verstehen: Mitose") -> StudyTask {
        StudyTask(examID: UUID(), kind: .learn, title: title, detail: "Lesen", start: cal.at(2026, 10, day, hour), durationMinutes: 25)
    }

    func content(_ t: StudyTask) -> CalendarEventContent {
        CalendarEventContent.make(task: t, exam: Exam(title: "Biologie", examDate: cal.at(2026, 11, 10)), objectives: [], topics: [], alarmMinutes: 10)
    }

    func link(_ t: StudyTask, id: String) -> CalendarLink {
        let c = content(t)
        return CalendarLink(taskID: t.id, eventIdentifier: id, calendarIdentifier: "cal", syncedStart: t.start, syncedEnd: t.end,
                            syncedTitle: c.title, syncedNotesFingerprint: c.fingerprint, lastSyncedAt: cal.at(2026, 10, 23))
    }

    func testFirstExportCreatesAndSecondExportIsNoOp() {
        let t = task(16)
        let first = CalendarSyncPlanner.plan(tasks: [t], allTasks: [t], links: [], snapshots: [:], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertEqual(first.creates, 1)
        XCTAssertEqual(content(t).title, "Biologie – Verstehen: Mitose")
        let l = link(t, id: "E1")
        let snapshot = CalendarEventSnapshot(identifier: "E1", start: t.start, end: t.end, title: content(t).title, url: content(t).url)
        let second = CalendarSyncPlanner.plan(tasks: [t], allTasks: [t], links: [l], snapshots: ["E1": snapshot], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertTrue(second.actions.isEmpty, "Kein Duplikat bei erneutem Export")
        XCTAssertEqual(second.summary, "Kalender ist aktuell.")
    }

    func testPlanChangeUpdatesOnlyLinkedEvent() {
        var t = task(16)
        let l = link(t, id: "E1")
        let snapshot = CalendarEventSnapshot(identifier: "E1", start: t.start, end: t.end, title: content(t).title, url: nil)
        t.start = cal.at(2026, 10, 24, 18)
        let plan = CalendarSyncPlanner.plan(tasks: [t], allTasks: [t], links: [l], snapshots: ["E1": snapshot], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertEqual(plan.actions, [.update(taskID: t.id, eventIdentifier: "E1", content: content(t))])
    }

    func testUserMovedEventIsAdoptedIntoPlan() {
        let t = task(16)
        let l = link(t, id: "E1")
        let moved = CalendarEventSnapshot(identifier: "E1", start: cal.at(2026, 10, 24, 19), end: cal.at(2026, 10, 24, 19, 25), title: content(t).title, url: nil)
        let plan = CalendarSyncPlanner.plan(tasks: [t], allTasks: [t], links: [l], snapshots: ["E1": moved], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertEqual(plan.actions, [.adoptCalendarTime(taskID: t.id, eventIdentifier: "E1", start: moved.start, end: moved.end)])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testChangesOnBothSidesAndDeletionsBecomeConflicts() {
        var t = task(16)
        let u = task(17, title: "Üben: Meiose")
        let lt = link(t, id: "E1")
        let lu = link(u, id: "E2")
        t.start = cal.at(2026, 10, 25, 16)
        let moved = CalendarEventSnapshot(identifier: "E1", start: cal.at(2026, 10, 24, 20), end: cal.at(2026, 10, 24, 20, 25), title: content(t).title, url: nil)
        let plan = CalendarSyncPlanner.plan(tasks: [t, u], allTasks: [t, u], links: [lt, lu], snapshots: ["E1": moved], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertEqual(Set(plan.conflicts.map(\.kind)), [.changedOnBothSides, .deletedInCalendar])
        XCTAssertTrue(plan.actions.isEmpty, "Bei Konflikten wird nichts ungefragt überschrieben")
    }

    func testRemovedTasksDeleteOnlyUnmodifiedAppEvents() {
        let a = task(16)
        let b = task(17)
        let la = link(a, id: "E1")
        let lb = link(b, id: "E2")
        let sa = CalendarEventSnapshot(identifier: "E1", start: a.start, end: a.end, title: content(a).title, url: nil)
        let sb = CalendarEventSnapshot(identifier: "E2", start: cal.at(2026, 10, 24, 9), end: cal.at(2026, 10, 24, 10), title: "Von mir geändert", url: nil)
        let plan = CalendarSyncPlanner.plan(tasks: [], allTasks: [], links: [la, lb], snapshots: ["E1": sa, "E2": sb], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertTrue(plan.actions.contains(.delete(eventIdentifier: "E1")))
        XCTAssertFalse(plan.actions.contains(.delete(eventIdentifier: "E2")), "Vom Nutzer veränderte Termine bleiben")
        XCTAssertTrue(plan.actions.contains(.unlink(taskID: b.id)))
    }

    func testPastAndCompletedEventsStay() {
        var a = task(16, day: 20)
        a.status = .completed
        let plan = CalendarSyncPlanner.plan(tasks: [], allTasks: [a], links: [link(a, id: "E1")], snapshots: ["E1": CalendarEventSnapshot(identifier: "E1", start: a.start, end: a.end, title: "x", url: nil)],
                                            contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testLinksCanBeRecoveredFromEventURL() {
        let t = task(16)
        let event = CalendarEventSnapshot(identifier: "E9", start: t.start, end: t.end, title: "x", url: content(t).url)
        let links = CalendarSyncPlanner.recoverLinks(events: [event], tasks: [t], calendarIdentifier: "cal", existing: [], contentFor: content, now: cal.at(2026, 10, 23))
        XCTAssertEqual(links.map(\.eventIdentifier), ["E9"])
        XCTAssertEqual(CalendarEventContent.taskID(fromURL: content(t).url), t.id)
    }

    func testICSExportIsValidAndStable() {
        let t = task(16, title: "Verstehen: Zellteilung; Phasen, Ablauf")
        let ics = ICSExporter.export([(t.id, content(t))], now: cal.at(2026, 10, 23, 12))
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("UID:\(t.id.uuidString.lowercased())@lernfokus.app"))
        XCTAssertTrue(ics.contains("DTSTART:20261024T140000Z"), "16:00 Wiener Sommerzeit = 14:00 UTC")
        XCTAssertTrue(ics.contains(#"Zellteilung\; Phasen\, Ablauf"#))
        XCTAssertTrue(ics.contains("TRIGGER:-PT10M"))
        for line in ics.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75) }
        XCTAssertEqual(ics, ICSExporter.export([(t.id, content(t))], now: cal.at(2026, 10, 23, 12)))
    }
}

final class AIValidationTests: XCTestCase {
    let examID = UUID()
    let documentID = UUID()
    lazy var chunk = SourceChunk(documentID: documentID, index: 0, sectionPath: ["Zellteilung"], pageStart: 3, pageEnd: 3,
                                 text: "Die Mitose ist die Teilung des Zellkerns, bei der zwei genetisch identische Tochterkerne entstehen. In der Metaphase ordnen sich die Chromosomen in der Äquatorialebene an.")

    func testQuoteVerifier() {
        XCTAssertTrue(QuoteVerifier.isSupported(quote: "zwei genetisch identische Tochterkerne entstehen", by: chunk.text))
        XCTAssertTrue(QuoteVerifier.isSupported(quote: "Die Mitose ist die Teilung des Zellkerns, bei der zwei genetisch identische Tochterkerne entstehen", by: chunk.text.replacingOccurrences(of: "Zellkerns", with: "Zellkems")), "Kleine OCR-Fehler werden toleriert")
        XCTAssertFalse(QuoteVerifier.isSupported(quote: "Die Mitose dauert genau 24 Stunden", by: chunk.text))
        XCTAssertFalse(QuoteVerifier.isSupported(quote: "Meiose", by: chunk.text))
    }

    func question(_ kind: String, prompt: String = "Welche Phase folgt? Wähle die richtige Antwort aus.", options: [String] = ["Metaphase", "Anaphase"], correct: [Int] = [0],
                  accepted: [String] = [], quote: String = "ordnen sich die Chromosomen in der Äquatorialebene an", chunkId: String? = nil) -> AIContracts.GeneratedQuestion {
        AIContracts.GeneratedQuestion(kind: kind, prompt: prompt, options: options, correctOptionIndices: correct, acceptedAnswers: accepted, numeric: nil, pairs: [],
                                      referenceAnswer: "", rubric: [], explanation: "Erklärung", simplerExplanation: "", commonMistakes: [],
                                      difficulty: "medium", isTransfer: false, chunkId: chunkId ?? chunk.id.uuidString, sourceQuote: quote)
    }

    func testQuestionValidationRejectsHallucinationsAndBrokenFormats() {
        let objective = LearningObjective(examID: examID, topicID: UUID(), title: "Mitose", origin: .ai)
        let response = AIContracts.QuestionsResponse(questions: [
            question("multipleChoice"),
            question("multipleChoice", prompt: "In welcher Phase ordnen sich Chromosomen an?", quote: "Die Meiose halbiert den Chromosomensatz vollständig"),
            question("multipleChoice", prompt: "Frage mit zwei richtigen Optionen?", correct: [0, 1]),
            question("multipleChoice", prompt: "Frage mit fremdem Abschnitt?", chunkId: UUID().uuidString),
            question("cloze", prompt: "In der ___ ordnen sich die Chromosomen an.", accepted: ["Metaphase"]),
            question("cloze", prompt: "Die Metaphase ist eine Phase der ___.", accepted: ["Metaphase"]),
            question("multipleChoice", prompt: "Welche Phase folgt? Wähle die richtige Antwort aus!"),
            question("essay"),
        ], insufficientMaterial: false)
        let result = AIResponseValidator.questions(response, objective: objective, chunks: [chunk], existing: [])
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertTrue(result.questions.allSatisfy { $0.origin == .ai && $0.source?.chunkID == chunk.id && $0.source?.page == 3 })
        let reasons = result.rejections.map(\.reason)
        XCTAssertTrue(reasons.contains("Beleg steht nicht im Material"))
        XCTAssertTrue(reasons.contains("Genau eine richtige Option nötig"))
        XCTAssertTrue(reasons.contains("Kein gültiger Quellabschnitt"))
        XCTAssertTrue(reasons.contains("Lösung steht im Fragetext"))
        XCTAssertTrue(reasons.contains("Doppelte Frage"))
        XCTAssertTrue(reasons.contains("Unbekanntes Aufgabenformat"))
    }

    func testCurriculumValidationRequiresEvidenceAndMarksSuggestions() {
        let response = AIContracts.AnalyzeResponse(topics: [
            AIContracts.AnalyzedTopic(title: "Zellteilung", summary: "Mitose", importance: "core", difficulty: 2, prerequisites: [], objectives: [
                AIContracts.AnalyzedObjective(title: "Mitose erklären", description: "", bloom: "understand", keyTerms: ["Mitose"], chunkIds: [chunk.id.uuidString],
                                              evidenceQuote: "Die Mitose ist die Teilung des Zellkerns"),
                AIContracts.AnalyzedObjective(title: "Apoptose erklären", description: "", bloom: "understand", keyTerms: [], chunkIds: [chunk.id.uuidString],
                                              evidenceQuote: "Apoptose ist der programmierte Zelltod"),
            ]),
            AIContracts.AnalyzedTopic(title: "Erfunden", summary: "", importance: "standard", difficulty: 1, prerequisites: ["Zellteilung"], objectives: [
                AIContracts.AnalyzedObjective(title: "X", description: "", bloom: "remember", keyTerms: [], chunkIds: ["nicht-vorhanden"], evidenceQuote: "x"),
            ]),
        ], terms: [
            AIContracts.AnalyzedTerm(term: "Mitose", definition: "Teilung des Zellkerns", chunkId: chunk.id.uuidString, quote: "Die Mitose ist die Teilung des Zellkerns", kind: "definition"),
            AIContracts.AnalyzedTerm(term: "Zytokinese", definition: "Teilung des Zytoplasmas", chunkId: chunk.id.uuidString, quote: "Zytokinese ist die Teilung des Zytoplasmas", kind: "definition"),
        ], warnings: [])
        let result = AIResponseValidator.curriculum(response, examID: examID, chunks: [chunk], existingTopics: [], orderOffset: 0)
        XCTAssertEqual(result.topics.map(\.title), ["Zellteilung"])
        XCTAssertEqual(result.topics.first?.importance, .core)
        XCTAssertEqual(result.objectives.map(\.title), ["Mitose erklären"])
        XCTAssertTrue(result.objectives.allSatisfy { $0.origin == .ai && $0.reviewStatus == .suggested })
        XCTAssertEqual(result.terms.map(\.term), ["Mitose"])
        XCTAssertEqual(result.rejections.count, 4)
    }

    func testGradeValidationIsConservative() {
        let overconfident = AIContracts.GradeResponse(score: 0.5, verdict: "correct", feedback: "Gut", coveredPoints: [], missingPoints: ["Phasen"], confidence: "low")
        let evaluation = AIResponseValidator.grade(overconfident)!
        XCTAssertEqual(evaluation.verdict, .partial)
        XCTAssertEqual(evaluation.grading.kind, .ai)
        XCTAssertEqual(evaluation.grading.evidenceWeight, 0.5)
        XCTAssertTrue(evaluation.feedback.contains("unsicher"))
        XCTAssertNil(AIResponseValidator.grade(AIContracts.GradeResponse(score: .nan, verdict: "correct", feedback: "x", coveredPoints: [], missingPoints: [], confidence: "high")))
    }

    func testBatcherRespectsLimitsAndSkipsDuplicates() {
        var chunks = (0..<25).map { i in SourceChunk(documentID: documentID, index: i, sectionPath: [], pageStart: i, pageEnd: i, text: String(repeating: "a", count: 1_500)) }
        chunks[3].duplicateOf = chunks[2].id
        let batches = AIBatcher.batches(chunks)
        XCTAssertEqual(batches.flatMap { $0 }.count, 24)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 10 && $0.reduce(0) { $0 + $1.text.count } <= 14_000 })
    }

    func testContractsRoundTripAsJSON() throws {
        let json = """
        {"questions":[{"kind":"numeric","prompt":"Berechne die Kraft für m = 2 kg und a = 3 m/s².","options":[],"correctOptionIndices":[],"acceptedAnswers":[],"numeric":{"value":6,"unit":"N","relativeTolerance":0.01},"pairs":[],"referenceAnswer":"","rubric":[],"explanation":"F = m · a","simplerExplanation":"","commonMistakes":["Einheit vergessen"],"difficulty":"medium","isTransfer":true,"chunkId":"x","sourceQuote":"q"}],"insufficientMaterial":false}
        """
        let decoded = try JSONDecoder().decode(AIContracts.QuestionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.questions.first?.numeric?.unit, "N")
    }
}
