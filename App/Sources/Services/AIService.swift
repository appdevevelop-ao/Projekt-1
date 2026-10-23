import Foundation
import LernKern

/// Client für den eigenen KI-Server. Der Claude-API-Schlüssel liegt ausschließlich auf dem Server.
final class AIService {
    enum AIError: LocalizedError {
        case notConfigured
        case unreachable
        case unauthorized
        case rateLimited(retryAfter: Int?)
        case server(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Der KI-Dienst ist nicht eingerichtet. Ohne ihn arbeitet LernFokus mit der lokalen Analyse."
            case .unreachable: return "Der KI-Dienst ist gerade nicht erreichbar. Prüfe die Internetverbindung oder versuche es später."
            case .unauthorized: return "Der Zugangscode für den KI-Dienst ist ungültig. Bitte unter Profil → KI-Dienst prüfen."
            case .rateLimited(let s): return "Das Nutzungslimit des KI-Dienstes ist erreicht." + (s.map { " Versuche es in \(max(1, $0 / 60)) Min. erneut." } ?? "")
            case .server(let message): return message
            case .invalidResponse: return "Die Antwort des KI-Dienstes war unvollständig. Bitte erneut versuchen."
            }
        }
    }

    static let tokenKey = "ai.accessToken"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var accessToken: String? {
        get { Keychain.get(Self.tokenKey) }
        set { Keychain.set(newValue, for: Self.tokenKey) }
    }

    func isUsable(_ settings: AppSettings) -> Bool { settings.isAIUsable }

    func analyze(_ request: AIContracts.AnalyzeRequest, settings: AppSettings) async throws -> AIContracts.AnalyzeResponse {
        try await post("/v1/analyze", body: request, settings: settings)
    }

    func questions(_ request: AIContracts.QuestionsRequest, settings: AppSettings) async throws -> AIContracts.QuestionsResponse {
        try await post("/v1/questions", body: request, settings: settings)
    }

    func grade(_ request: AIContracts.GradeRequest, settings: AppSettings) async throws -> AIContracts.GradeResponse {
        try await post("/v1/grade", body: request, settings: settings)
    }

    func explain(_ request: AIContracts.ExplainRequest, settings: AppSettings) async throws -> AIContracts.ExplainResponse {
        try await post("/v1/explain", body: request, settings: settings)
    }

    /// Prüft Erreichbarkeit (ohne Inhalte zu senden).
    func checkHealth(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL)?.appendingPathComponent("health") else { return false }
        guard let (_, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Holt ein installationsbezogenes Token, falls der Server die Registrierung erlaubt.
    func register(baseURL: String, installationID: String) async throws -> String {
        struct Body: Encodable { let installationId: String }
        struct Reply: Decodable { let token: String }
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/register") else { throw AIError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(installationId: installationID))
        let (data, response) = try await perform(request)
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw mapStatus(response, data: data) }
        return reply.token
    }

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, body: Body, settings: AppSettings) async throws -> Reply {
        guard settings.isAIUsable, let base = settings.backendURL, let url = URL(string: base)?.appendingPathComponent(String(path.dropFirst())) else {
            throw AIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else { throw mapStatus(response, data: data) }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw AIError.invalidResponse
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            return (data, http)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.unreachable
        }
    }

    private func mapStatus(_ response: HTTPURLResponse, data: Data) -> AIError {
        let message = (try? JSONDecoder().decode(AIContracts.ServerError.self, from: data))?.message
        switch response.statusCode {
        case 401: return .unauthorized
        case 429, 503:
            let retry = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init)
            return response.statusCode == 429 ? .rateLimited(retryAfter: retry) : .server(message ?? "Der KI-Dienst ist ausgelastet.")
        default: return .server(message ?? "Fehler beim KI-Dienst (\(response.statusCode)).")
        }
    }
}
