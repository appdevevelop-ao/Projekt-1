import XCTest
@testable import LernKern

final class DocumentTests: XCTestCase {
    func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        return try Data(contentsOf: url)
    }

    func testDocxExtractionFindsHeadingsListsTablesAndPages() throws {
        let doc = try DocumentPipeline.extract(data: try resource("sample.docx"), kind: .docx)
        let headings = doc.blocks.compactMap { b in b.headingLevel.map { ($0, b.text) } }
        XCTAssertEqual(headings.map(\.1), ["1 Zellteilung", "1.1 Phasen der Mitose", "2 Genetik"])
        XCTAssertEqual(headings.map(\.0), [1, 2, 1])
        XCTAssertTrue(doc.blocks.contains { $0.kind == .listItem && $0.text.hasPrefix("Prophase") })
        XCTAssertTrue(doc.blocks.contains { $0.kind == .tableRow && $0.text == "Anaphase | Chromatiden wandern zu den Polen" })
        XCTAssertEqual(doc.blocks.first { $0.text == "2 Genetik" }?.page, 2, "Seitenumbruch wird gezählt")
        XCTAssertTrue(doc.blocks.contains { $0.text.contains("Äquatorialebene") }, "Umlaute bleiben erhalten")
    }

    func testPptxUsesPresentationOrderAndNotesAndSkipsSlideNumbers() throws {
        let doc = try DocumentPipeline.extract(data: try resource("sample.pptx"), kind: .pptx)
        let titles = doc.blocks.filter { $0.headingLevel != nil }.map(\.text)
        XCTAssertEqual(titles, ["Einführung Zellbiologie", "Osmose"])
        XCTAssertTrue(doc.blocks.contains { $0.kind == .note && $0.text.contains("Diffusion verwechselt") })
        XCTAssertFalse(doc.blocks.contains { $0.text == "7" })
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.blocks.first { $0.text.hasPrefix("Osmose ist") }?.page, 2)
    }

    func testLargeCompressedDocumentInflatesCorrectly() throws {
        let doc = try DocumentPipeline.extract(data: try resource("large.docx"), kind: .docx)
        XCTAssertEqual(doc.blocks.filter { $0.kind == .paragraph }.count, 400)
        XCTAssertEqual(doc.blocks.last?.text, "Absatz 399: Die Zellmembran besteht aus einer Lipiddoppelschicht mit eingelagerten Proteinen.")
        let analysis = try DocumentPipeline.analyze(doc, documentID: UUID(), kind: .docx, existingChunks: [])
        XCTAssertGreaterThan(analysis.chunks.count, 5, "Große Dokumente werden in mehrere Abschnitte geteilt")
        XCTAssertTrue(analysis.chunks.allSatisfy { $0.text.count <= Chunker.maxCharacters + 200 })
    }

    func testCorruptFilesFailWithClearMessage() {
        XCTAssertThrowsError(try DocumentPipeline.extract(data: Data("kein zip".utf8), kind: .docx)) { error in
            XCTAssertNotNil((error as? DocumentPipelineError)?.errorDescription)
        }
        XCTAssertThrowsError(try DocumentPipeline.analyze(ExtractedDocument(blocks: [], pageCount: 1), documentID: UUID(), kind: .pdf, existingChunks: []))
    }

    func testTermExtractionFindsDefinitionsWithEvidence() throws {
        let doc = try DocumentPipeline.extract(data: try resource("sample.docx"), kind: .docx)
        let analysis = try DocumentPipeline.analyze(doc, documentID: UUID(), kind: .docx, existingChunks: [])
        let terms = Dictionary(uniqueKeysWithValues: analysis.terms.map { ($0.term, $0) })
        XCTAssertNotNil(terms["Mitose"])
        XCTAssertNotNil(terms["Meiose"])
        XCTAssertNotNil(terms["Gen"])
        XCTAssertNotNil(terms["Allel"])
        XCTAssertEqual(terms["Prophase"]?.definition, "Die Chromosomen kondensieren und werden im Lichtmikroskop sichtbar.")
        for t in analysis.terms {
            let chunk = analysis.chunks.first { $0.id == t.chunkID }!
            XCTAssertTrue(chunk.text.contains(t.sentence.replacingOccurrences(of: "• ", with: "")) || chunk.text.contains(t.definition), "Beleg für \(t.term) muss im Text stehen")
        }
    }

    func testDefinitionPatterns() {
        let id = UUID()
        func term(_ s: String) -> String? { TermExtractor.definition(in: s, chunkID: id)?.term }
        XCTAssertEqual(term("Photosynthese ist ein Prozess, bei dem Pflanzen Lichtenergie in chemische Energie umwandeln."), "Photosynthese")
        XCTAssertEqual(term("Die Zellatmung bezeichnet den Abbau von Glukose unter Energiegewinnung in den Mitochondrien."), "Zellatmung")
        XCTAssertEqual(term("Den Übergang eines Stoffes vom festen in den gasförmigen Zustand nennt man Sublimation."), "Sublimation")
        XCTAssertEqual(term("Inflation is defined as a general increase in prices over a period of time."), "Inflation")
        XCTAssertNil(term("Es ist ein schöner Tag, an dem wir viel über Zellen lernen werden."))
        XCTAssertNil(term("Das ist ein Beispiel."))
        XCTAssertEqual(TermExtractor.formula("F = m · a", chunkID: id)?.term, "F")
        XCTAssertNil(TermExtractor.formula("Seite = 3", chunkID: id))
    }

    func testStructureDetectionFromPlainText() {
        let pages = ["KAPITEL 1: GRUNDLAGEN\nDas ist der erste Absatz über Grundlagen\nder Biologie.\n\n2.1 Aufbau der Zelle\nZellen bestehen aus Zytoplasma.\n- Zellkern\n- Membran\n1",
                     "Seite 2 von 2\n# Zusammenfassung\nAlles klar."]
        let doc = ExtractedDocument.fromPages(pages)
        let headings = doc.blocks.compactMap { b in b.headingLevel.map { _ in b.text } }
        XCTAssertEqual(headings, ["Kapitel 1: Grundlagen", "2.1 Aufbau der Zelle", "Zusammenfassung"])
        XCTAssertEqual(doc.blocks.filter { $0.kind == .listItem }.map(\.text), ["Zellkern", "Membran"])
        XCTAssertFalse(doc.blocks.contains { $0.text == "1" || $0.text.contains("Seite 2 von 2") })
        XCTAssertTrue(doc.blocks.contains { $0.text == "Das ist der erste Absatz über Grundlagen der Biologie." })
        XCTAssertEqual(StructureDetector.stripNumbering("2.1 Aufbau der Zelle"), "Aufbau der Zelle")
        XCTAssertEqual(StructureDetector.stripNumbering("Kapitel 3: Genetik"), "Genetik")
        XCTAssertNil(StructureDetector.headingLevel(of: "3. Die Chromosomen werden kondensiert."))
    }

    func testDuplicatesAcrossDocumentsAreMarked() throws {
        let doc = try DocumentPipeline.extract(data: try resource("sample.docx"), kind: .docx)
        let first = try DocumentPipeline.analyze(doc, documentID: UUID(), kind: .docx, existingChunks: [])
        let second = try DocumentPipeline.analyze(doc, documentID: UUID(), kind: .docx, existingChunks: first.chunks)
        XCTAssertTrue(second.chunks.allSatisfy { $0.duplicateOf != nil })
        XCTAssertTrue(second.warnings.contains { $0.kind == .duplicateContent })
    }

    func testQualityWarningsForEmptyAndGarbledPages() {
        let doc = ExtractedDocument.fromPages(["Ein normaler Text mit genügend Inhalt für die Prüfung der Qualität.", "", "§$%&/()=?§$%&/()=?§$%&/()=?§$%&/()=?§$%&/()=?ab"], confidence: [1: 0.3])
        let warnings = ExtractionQualityChecker.check(doc, kind: .pdf)
        XCTAssertTrue(warnings.contains { $0.kind == .emptyPage && $0.page == 2 })
        XCTAssertTrue(warnings.contains { $0.kind == .lowRecognitionConfidence && $0.page == 1 })
        XCTAssertTrue(warnings.contains { $0.kind == .garbledText && $0.page == 3 })
    }

    func testTextDecodingAndPagination() throws {
        let latin1 = "Größe und Maß".data(using: .isoLatin1)!
        let doc = try DocumentPipeline.extract(data: latin1, kind: .text)
        XCTAssertEqual(doc.blocks.first?.text, "Größe und Maß")
    }

    func testLocalCurriculumAndQuestionsAreGroundedInMaterial() throws {
        let examID = UUID()
        let documentID = UUID()
        let doc = try DocumentPipeline.extract(data: try resource("sample.docx"), kind: .docx)
        let analysis = try DocumentPipeline.analyze(doc, documentID: documentID, kind: .docx, existingChunks: [])
        let curriculum = LocalCurriculumBuilder.build(examID: examID, documentID: documentID, sections: analysis.sections, chunks: analysis.chunks,
                                                      extractedTerms: analysis.terms, existingTopics: [], orderOffset: 0)
        XCTAssertEqual(curriculum.topics.map(\.title), ["Zellteilung", "Genetik"])
        XCTAssertTrue(curriculum.topics.allSatisfy { $0.origin == .local && $0.reviewStatus == .suggested })
        XCTAssertFalse(curriculum.objectives.isEmpty)
        XCTAssertTrue(curriculum.terms.allSatisfy { $0.objectiveID != nil })

        var all: [Question] = []
        for o in curriculum.objectives {
            let qs = LocalQuestionGenerator.questions(for: o, terms: curriculum.terms, allTerms: curriculum.terms, chunks: analysis.chunks, existing: all)
            all += qs
            for q in qs {
                XCTAssertNotNil(q.source, "Jede lokale Frage hat eine Quelle")
                if q.kind == .multipleChoice {
                    XCTAssertEqual(q.correctOptionIndices.count, 1)
                    XCTAssertTrue(q.options.indices.contains(q.correctOptionIndices[0]))
                    XCTAssertEqual(Set(q.options).count, q.options.count, "Keine doppelten Optionen")
                }
                if q.kind == .cloze { XCTAssertTrue(q.prompt.contains("___")); XCTAssertFalse(q.acceptedAnswers.isEmpty) }
            }
        }
        XCTAssertGreaterThan(all.count, 6)
        // Je Begriff mehrere Formulierungen und mindestens eine schwere Aufgabe
        let mitoseObjective = curriculum.objectives.first { $0.keyTerms.contains("Mitose") }!
        let mitoseQuestions = all.filter { $0.objectiveID == mitoseObjective.id }
        XCTAssertGreaterThanOrEqual(Set(mitoseQuestions.map(\.prompt)).count, 3)
        XCTAssertTrue(mitoseQuestions.contains { $0.difficulty == .hard })
        // Lösung nicht im Fragetext verraten
        for q in all where q.kind == .cloze || q.prompt.hasPrefix("Welcher Begriff") {
            for answer in q.acceptedAnswers { XCTAssertFalse(q.prompt.lowercased().contains(answer.lowercased()), q.prompt) }
        }
        // Generierung ist deterministisch
        let again = LocalQuestionGenerator.questions(for: mitoseObjective, terms: curriculum.terms, allTerms: curriculum.terms, chunks: analysis.chunks, existing: [])
        XCTAssertEqual(again.map(\.prompt), LocalQuestionGenerator.questions(for: mitoseObjective, terms: curriculum.terms, allTerms: curriculum.terms, chunks: analysis.chunks, existing: []).map(\.prompt))
    }

    func testSyllabusEntriesWithWeights() {
        let doc = ExtractedDocument.fromPages(["Themenliste Biologie\n- Zellteilung (30 %)\n- Genetik (50 %)\n- Ökologie"])
        let entries = SyllabusParser.entries(from: doc)
        XCTAssertTrue(entries.contains { $0.title == "Zellteilung" && $0.weight == 0.3 })
        XCTAssertTrue(entries.contains { $0.title == "Genetik" && $0.weight == 0.5 })
        XCTAssertTrue(entries.contains { $0.title == "Ökologie" && $0.weight == nil })
        let topic = Topic(examID: UUID(), title: "Genetik und Vererbung", order: 0, origin: .local)
        XCTAssertEqual(SyllabusParser.matchingTopic(for: entries.first { $0.title == "Genetik" }!, in: [topic])?.id, topic.id)
    }

    func testStableHashAndSeededGeneratorAreDeterministic() {
        XCTAssertEqual(StableHash.uuid("abc"), StableHash.uuid("abc"))
        XCTAssertNotEqual(StableHash.uuid("abc"), StableHash.uuid("abd"))
        var a = SeededGenerator("x")
        var b = SeededGenerator("x")
        XCTAssertEqual((0..<5).map { _ in a.next() }, (0..<5).map { _ in b.next() })
    }
}
