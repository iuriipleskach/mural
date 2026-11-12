import Foundation
import MuralCore
import UIKit

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct APIUsage: Sendable {
    public var input = 0
    public var output = 0
    public var searches = 0
    public init(input: Int = 0, output: Int = 0, searches: Int = 0) {
        self.input = input
        self.output = output
        self.searches = searches
    }
}

public struct APIResult: Sendable {
    public var text: String
    public var sources: [SourceLink]
    public var usage: APIUsage
    public init(text: String, sources: [SourceLink] = [], usage: APIUsage = APIUsage()) {
        self.text = text
        self.sources = sources
        self.usage = usage
    }
}

/// Unary Google Gemini REST client for Ukrainian Meaning subtitles and word lookups.
@MainActor
public final class APIClient {
    public var canProcessAI: () -> Bool = { true }
    private var responseTasks: [UUID: Task<APIResult, Error>] = [:]
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    public func cancelAIRequests() {
        responseTasks.values.forEach { $0.cancel() }
        responseTasks.removeAll()
    }

    private func personalKey() -> String? {
        CredentialStore.read()
    }

    public func respond(
        instructions: String,
        input: String,
        schema: [String: Any]? = nil,
        search: Bool = false,
        purpose: String = "meaning",
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws -> APIResult {
        guard canProcessAI() else { throw APIError.missingKey }
        try Task.checkCancellation()

        let id = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            let result = try await self.geminiResponse(
                instructions: instructions,
                input: input,
                schema: schema,
                search: search,
                onText: onText
            )
            try Task.checkCancellation()
            return result
        }

        responseTasks[id] = task
        defer { responseTasks.removeValue(forKey: id) }

        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private func geminiResponse(
        instructions: String,
        input: String,
        schema: [String: Any]?,
        search: Bool,
        onText: (@MainActor (String) -> Void)?
    ) async throws -> APIResult {
        guard let key = personalKey() else { throw APIError.missingKey }

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generation: [String: Any] = [
            "maxOutputTokens": schema == nil ? 1400 : 2200,
            "thinkingConfig": ["thinkingBudget": 0]
        ]
        if let schema {
            generation["responseMimeType"] = "application/json"
            generation["responseJsonSchema"] = schema
        }

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": input]]]],
            "generationConfig": generation
        ]
        if search {
            body["tools"] = [["google_search": [String: Any]()]]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderFailure(status: http.statusCode, body: data, reference: http.value(forHTTPHeaderField: "x-request-id"))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }

        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw APIError.refused
        }

        guard let candidates = json["candidates"] as? [[String: Any]], let firstCandidate = candidates.first else {
            throw APIError.incomplete
        }

        if let finishReason = firstCandidate["finishReason"] as? String,
           ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(finishReason) {
            throw APIError.refused
        }

        var text = ""
        if let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if (part["thought"] as? Bool) != true, let partText = part["text"] as? String {
                    text += partText
                }
            }
        }

        var usage = APIUsage()
        if let usageMeta = json["usageMetadata"] as? [String: Any] {
            usage.input = usageMeta["promptTokenCount"] as? Int ?? 0
            usage.output = usageMeta["candidatesTokenCount"] as? Int ?? 0
        }

        guard !text.isEmpty else { throw APIError.incomplete }

        onText?(text)
        return APIResult(text: text, sources: [], usage: usage)
    }

    public enum APIError: LocalizedError {
        case missingKey, invalidResponse, incomplete, refused, http(Int)

        public var errorDescription: String? {
            switch self {
            case .missingKey: "Add your Gemini API key in Settings to use Ukrainian translations and word lookups."
            case .invalidResponse, .incomplete: "Gemini returned an incomplete response. Please try again."
            case .refused: "Mural couldn’t complete that request."
            case .http(401): "Your Gemini API key wasn’t accepted. Check it in Settings."
            case .http(403), .http(404): "This API key may not have access to gemini-2.5-flash."
            case .http(429): "Gemini quota or rate limit reached. Please wait briefly and try again."
            case .http(let status): "Gemini request failed (HTTP \(status))."
            }
        }
    }
}
