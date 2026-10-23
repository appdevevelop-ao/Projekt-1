import Foundation

/// Datenverträge zwischen App und eigenem KI-Server (siehe Backend/README.md).
/// Der Server hält den API-Schlüssel; die App sendet nur die nötigen Textabschnitte.
public enum AIContracts {
    public struct ChunkPayload: Codable, Hashable, Sendable {
        public var id: String
        public var section: String
        public var pages: String?
        public var text: String

        public init(chunk: SourceChunk) {
            id = chunk.id.uuidString
            section = chunk.sectionPath.joined(separator: " > ")
            pages = chunk.pageLabel
            text = chunk.text
        }
    }

    public struct ExamPayload: Codable, Hashable, Sendable {
        public var title: String
        public var format: String
        public var additionalRequirements: String

        public init(exam: Exam) {
            title = exam.title
            format = exam.format.rawValue
            additionalRequirements = exam.additionalRequirements
        }
    }

    // MARK: Analyse

    public struct AnalyzeRequest: Codable, Sendable {
        public var exam: ExamPayload
        public var language: String
        public var chunks: [ChunkPayload]
        public var knownTopics: [String]

        public init(exam: ExamPayload, language: String, chunks: [ChunkPayload], knownTopics: [String]) {
            self.exam = exam
            self.language = language
            self.chunks = chunks
            self.knownTopics = knownTopics
        }
    }

    public struct AnalyzedObjective: Codable, Hashable, Sendable {
        public var title: String
        public var description: String
        public var bloom: String
        public var keyTerms: [String]
        public var chunkIds: [String]
        public var evidenceQuote: String
    }

    public struct AnalyzedTopic: Codable, Hashable, Sendable {
        public var title: String
        public var summary: String
        public var importance: String
        public var difficulty: Int
        public var prerequisites: [String]
        public var objectives: [AnalyzedObjective]
    }

    public struct AnalyzedTerm: Codable, Hashable, Sendable {
        public var term: String
        public var definition: String
        public var chunkId: String
        public var quote: String
        public var kind: String
    }

    public struct AnalyzeResponse: Codable, Sendable {
        public var topics: [AnalyzedTopic]
        public var terms: [AnalyzedTerm]
        public var warnings: [String]
    }

    // MARK: Fragen

    public struct ObjectivePayload: Codable, Hashable, Sendable {
        public var title: String
        public var description: String
        public var bloom: String
        public var keyTerms: [String]

        public init(objective: LearningObjective) {
            title = objective.title
            description = objective.detail
            bloom = objective.bloom.rawValue
            keyTerms = objective.keyTerms
        }
    }

    public struct DifficultyMix: Codable, Hashable, Sendable {
        public var easy: Int
        public var medium: Int
        public var hard: Int

        public init(easy: Int, medium: Int, hard: Int) {
            self.easy = easy
            self.medium = medium
            self.hard = hard
        }
    }

    public struct QuestionsRequest: Codable, Sendable {
        public var exam: ExamPayload
        public var objective: ObjectivePayload
        public var language: String
        public var chunks: [ChunkPayload]
        public var difficulties: DifficultyMix
        public var kinds: [String]
        public var avoidPrompts: [String]

        public init(exam: ExamPayload, objective: ObjectivePayload, language: String, chunks: [ChunkPayload], difficulties: DifficultyMix, kinds: [String], avoidPrompts: [String]) {
            self.exam = exam
            self.objective = objective
            self.language = language
            self.chunks = chunks
            self.difficulties = difficulties
            self.kinds = kinds
            self.avoidPrompts = avoidPrompts
        }
    }

    public struct NumericPayload: Codable, Hashable, Sendable {
        public var value: Double
        public var unit: String
        public var relativeTolerance: Double
    }

    public struct PairPayload: Codable, Hashable, Sendable {
        public var left: String
        public var right: String
    }

    public struct GeneratedQuestion: Codable, Hashable, Sendable {
        public var kind: String
        public var prompt: String
        public var options: [String]
        public var correctOptionIndices: [Int]
        public var acceptedAnswers: [String]
        public var numeric: NumericPayload?
        public var pairs: [PairPayload]
        public var referenceAnswer: String
        public var rubric: [String]
        public var explanation: String
        public var simplerExplanation: String
        public var commonMistakes: [String]
        public var difficulty: String
        public var isTransfer: Bool
        public var chunkId: String
        public var sourceQuote: String
    }

    public struct QuestionsResponse: Codable, Sendable {
        public var questions: [GeneratedQuestion]
        public var insufficientMaterial: Bool
    }

    // MARK: Bewertung offener Antworten

    public struct GradeRequest: Codable, Sendable {
        public var language: String
        public var prompt: String
        public var referenceAnswer: String
        public var rubric: [String]
        public var sourceExcerpt: String
        public var answer: String

        public init(language: String, prompt: String, referenceAnswer: String, rubric: [String], sourceExcerpt: String, answer: String) {
            self.language = language
            self.prompt = prompt
            self.referenceAnswer = referenceAnswer
            self.rubric = rubric
            self.sourceExcerpt = sourceExcerpt
            self.answer = answer
        }
    }

    public struct GradeResponse: Codable, Sendable {
        public var score: Double
        public var verdict: String
        public var feedback: String
        public var coveredPoints: [String]
        public var missingPoints: [String]
        public var confidence: String
    }

    // MARK: Erklärungen

    public struct ExplainRequest: Codable, Sendable {
        public var language: String
        public var mode: String
        public var objective: ObjectivePayload
        public var chunks: [ChunkPayload]
        public var questionPrompt: String?
        public var correctAnswer: String?
        public var userAnswer: String?

        public init(language: String, mode: String, objective: ObjectivePayload, chunks: [ChunkPayload], questionPrompt: String?, correctAnswer: String?, userAnswer: String?) {
            self.language = language
            self.mode = mode
            self.objective = objective
            self.chunks = chunks
            self.questionPrompt = questionPrompt
            self.correctAnswer = correctAnswer
            self.userAnswer = userAnswer
        }
    }

    public struct ExplainResponse: Codable, Sendable {
        public var explanation: String
        public var chunkIds: [String]
        public var outsideMaterial: Bool
    }

    public struct ServerError: Codable, Sendable {
        public var error: String
        public var message: String
    }
}
