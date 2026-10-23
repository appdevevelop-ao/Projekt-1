import XCTest
import LernKern
@testable import LernFokus

/// Ende-zu-Ende-Tests des App-Modells mit echtem Dateispeicher in einem temporären Verzeichnis
/// (lokale Analyse, ohne KI-Dienst, ohne Bildschirmzeit-Berechtigung).
@MainActor
final class AppModelTests: XCTestCase {
    static let material = """
    # Zellbiologie

    ## Zellatmung
    Die Zellatmung bezeichnet den Abbau von Glukose unter Energiegewinnung in den Mitochondrien. Dabei entsteht ATP als universeller Energieträger der Zelle.

    ## Photosynthese
    Photosynthese ist ein Prozess, bei dem Pflanzen Lichtenergie in chemische Energie umwandeln. Sie findet in den Chloroplasten der Blattzellen statt.

    ## Mitose
    Die Mitose ist eine Form der Kernteilung, bei der zwei genetisch identische Tochterkerne entstehen. Sie verläuft in Prophase, Metaphase, Anaphase und Telophase.

    ## Meiose
    Die Meiose ist eine Reifeteilung, bei der der Chromosomensatz halbiert wird. Aus einer diploiden Zelle entstehen dabei vier haploide Keimzellen.
    """

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LernFokusTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeExam(in model: AppModel) -> Exam {
        let exam = Exam(title: "Biologie", examDate: Calendar.current.date(byAdding: .day, value: 10, to: Date())!, format: .written, durationMinutes: 45)
        model.addExam(exam)
        model.updateSettings { $0.onboardingCompleted = true }
        return exam
    }

    private func importMaterial(into model: AppModel, examID: UUID) async {
        await model.importData(Data(Self.material.utf8), fileName: "zellbiologie.txt", kind: .text, examID: examID, role: .material)
    }

    static func correctResponse(for question: Question) -> AttemptResponse {
        switch question.kind {
        case .multipleChoice, .trueFalse:
            return AttemptResponse(selectedIndices: question.correctOptionIndices)
        case .cloze, .shortAnswer:
            return AttemptResponse(text: question.acceptedAnswers.first ?? question.referenceAnswer ?? "")
        case .numeric:
            return AttemptResponse(text: question.numeric.map { "\($0.value) \($0.unit ?? "")" } ?? "")
        case .matching:
            return AttemptResponse(matching: Array(question.pairs.indices))
        case .freeText:
            return AttemptResponse(text: question.referenceAnswer ?? "", selfRating: 1)
        }
    }

    /// Beantwortet alle offenen Fragen der Sitzung richtig (mit realistischer Antwortzeit).
    private func answerAll(in model: AppModel) {
        var guardCount = 0
        while let question = model.currentQuestion, guardCount < 50 {
            let response = Self.correctResponse(for: question)
            model.record(question, response: response, evaluation: AnswerEvaluator.evaluate(question, response: response), usedHint: false, seconds: 30, advance: true)
            guardCount += 1
        }
    }

    func testTextImportCreatesSourcedObjectivesAndPlanAndSurvivesRestart() async throws {
        let directory = temporaryDirectory()
        let model = AppModel(storeDirectory: directory)
        let exam = makeExam(in: model)
        await importMaterial(into: model, examID: exam.id)

        let document = try XCTUnwrap(model.state.documents(for: exam.id).first)
        XCTAssertEqual(document.state.stage, .completed)
        let objectives = model.state.objectives(for: exam.id)
        XCTAssertFalse(objectives.isEmpty, "Aus belegten Definitionen entstehen Lernziele")
        XCTAssertTrue(objectives.allSatisfy { !$0.sourceChunkIDs.isEmpty }, "Jedes Lernziel verweist auf seine Quelle")
        let questions = model.state.questions.filter { $0.examID == exam.id && $0.status == .active }
        XCTAssertFalse(questions.isEmpty)
        XCTAssertTrue(questions.allSatisfy { $0.source != nil }, "Jede lokal erzeugte Frage hat eine Quellenangabe")
        XCTAssertFalse(model.chunks(forExam: exam.id).isEmpty)
        XCTAssertFalse(model.state.tasks.filter { $0.examID == exam.id }.isEmpty, "Nach dem Import entsteht ein Lernplan")

        let reloaded = AppModel(storeDirectory: directory)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.state.objectives(for: exam.id).count, objectives.count)
        XCTAssertEqual(reloaded.chunks(forExam: exam.id).count, model.chunks(forExam: exam.id).count)
        XCTAssertEqual(reloaded.state.tasks.count, model.state.tasks.count)
    }

    func testSessionResumesAfterRestartAndRewardIsGrantedExactlyOnce() async throws {
        let directory = temporaryDirectory()
        let model = AppModel(storeDirectory: directory)
        let exam = makeExam(in: model)
        await importMaterial(into: model, examID: exam.id)
        let objectiveIDs = model.state.objectives(for: exam.id).map(\.id)
        await model.startPractice(examID: exam.id, objectiveIDs: objectiveIDs, kind: .practice)
        let session = try XCTUnwrap(model.session)
        XCTAssertGreaterThanOrEqual(session.questionIDs.count, 3)

        // Erste Antwort, dann "Neustart" der App mitten in der Sitzung
        let first = try XCTUnwrap(model.currentQuestion)
        let response = Self.correctResponse(for: first)
        model.record(first, response: response, evaluation: AnswerEvaluator.evaluate(first, response: response), usedHint: false, seconds: 30, advance: true)

        let restarted = AppModel(storeDirectory: directory)
        XCTAssertEqual(restarted.session?.id, session.id, "Die Sitzung wird nach einem Neustart fortgesetzt")
        XCTAssertEqual(restarted.session?.attemptIDs.count, 1)
        XCTAssertEqual(restarted.state.attempts.count, 1, "Bereits gegebene Antworten gehen nicht verloren")

        answerAll(in: restarted)
        let balanceBefore = restarted.state.rewardBalance
        let summary = try XCTUnwrap(restarted.finishSession())
        let grant = try XCTUnwrap(summary.grant)
        XCTAssertTrue(grant.passed)
        XCTAssertGreaterThan(grant.minutes, 0)
        XCTAssertEqual(restarted.state.rewardBalance, balanceBefore + grant.minutes)
        XCTAssertEqual(restarted.state.checks.count, 1)

        // Erneutes Abschließen derselben Überprüfung schreibt nichts doppelt gut
        _ = restarted.finishSession()
        XCTAssertEqual(restarted.state.rewardBalance, balanceBefore + grant.minutes)
        XCTAssertEqual(restarted.state.checks.count, 1)

        restarted.closeSession()
        XCTAssertNil(AppModel(storeDirectory: directory).session)
    }

    func testRedeemWithoutConfiguredLockKeepsMinutes() async throws {
        let model = AppModel(storeDirectory: temporaryDirectory())
        let exam = makeExam(in: model)
        await importMaterial(into: model, examID: exam.id)
        await model.startPractice(examID: exam.id, objectiveIDs: model.state.objectives(for: exam.id).map(\.id), kind: .practice)
        answerAll(in: model)
        _ = model.finishSession()
        model.closeSession()
        let balance = model.state.rewardBalance
        XCTAssertGreaterThan(balance, 0)

        model.banner = nil
        model.redeem(minutes: min(5, balance))
        XCTAssertEqual(model.state.rewardBalance, balance, "Ohne eingerichtete Sperre wird nichts abgebucht")
        XCTAssertNotNil(model.banner, "Der Nutzer erfährt, warum nichts eingelöst wurde")
    }

    func testDeletingDocumentRemovesUnpracticedContentAndStoredChunks() async throws {
        let model = AppModel(storeDirectory: temporaryDirectory())
        let exam = makeExam(in: model)
        await importMaterial(into: model, examID: exam.id)
        let document = try XCTUnwrap(model.state.documents(for: exam.id).first)
        XCTAssertFalse(model.store.loadChunks(documentID: document.id).isEmpty)

        model.deleteDocument(document.id)
        XCTAssertTrue(model.state.documents(for: exam.id).isEmpty)
        XCTAssertTrue(model.state.objectives(for: exam.id).isEmpty, "Ungeübte Lernziele aus dem Dokument werden entfernt")
        XCTAssertTrue(model.state.questions.filter { $0.examID == exam.id && $0.status == .active }.isEmpty)
        XCTAssertTrue(model.store.loadChunks(documentID: document.id).isEmpty, "Gespeicherte Abschnitte werden gelöscht")
    }

    func testCorruptStateIsReportedAndNotOverwritten() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("state.json")
        try Data("{ kaputt".utf8).write(to: file)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("state.previous.json"))

        let model = AppModel(storeDirectory: directory)
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(try Data(contentsOf: file), Data("{ kaputt".utf8), "Beschädigte Daten werden nicht stillschweigend überschrieben")
    }
}
