import Foundation
import Security

/// An optional AI step for the Professional and Custom modes (ADR-010).
/// Dictation never depends on it: any failure falls back to the local result.
public protocol TextProcessor: Sendable {
    var name: String { get }
    func process(_ text: String, instruction: String, vocabulary: [String]) async throws -> String
}

public enum TextProcessorError: Error, Equatable {
    case notConfigured(String)
    case unreachable(String)
    case rejected(status: Int, detail: String)
    case badResponse(String)
    case timedOut

    public var userMessage: String {
        switch self {
        case .notConfigured(let what): "The AI processor isn't set up (\(what)), so the cleaned-up text was used."
        case .unreachable(let who): "\(who) isn't reachable, so the cleaned-up text was used."
        case .rejected(let status, _):
            status == 401 || status == 403
                ? "The AI provider rejected the API key, so the cleaned-up text was used. Check it in Settings → Processing."
                : "The AI provider returned an error (\(status)), so the cleaned-up text was used."
        case .badResponse: "The AI provider's reply couldn't be read, so the cleaned-up text was used."
        case .timedOut: "The AI processor took too long, so the cleaned-up text was used."
        }
    }
}

/// Which processor Professional/Custom use (Settings → Processing). Cloud is off
/// unless the user picks it and stores a key.
public struct ProcessorSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case none, appleIntelligence, ollama, anthropic

        public var title: String {
            switch self {
            case .none: "None (local clean-up only)"
            case .appleIntelligence: "Apple Intelligence (on this Mac)"
            case .ollama: "Ollama (on this Mac)"
            case .anthropic: "Anthropic (cloud)"
            }
        }
    }

    public var provider: Provider = .none
    public var ollamaURL = "http://localhost:11434"
    public var ollamaModel = "llama3.2"
    public var anthropicModel = "claude-haiku-4-5-20251001"
    public var timeoutSeconds: Double = 10

    public init() {}

    public static let defaultsKey = "processing.settings"

    public static func load(from defaults: UserDefaults = .standard) -> ProcessorSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(ProcessorSettings.self, from: data) else { return ProcessorSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// True if the processor runs on this Mac: Ollama on a loopback address.
    /// Local-only mode allows nothing else.
    public var isLocal: Bool {
        switch provider {
        case .none, .appleIntelligence: return true
        case .anthropic: return false
        case .ollama:
            guard let host = URL(string: ollamaURL)?.host?.lowercased() else { return false }
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }

    /// The configured processor, or nil (none chosen, or no key for the cloud).
    public func makeProcessor(keychain: KeychainStore = .anthropic, session: URLSession = .shared) -> (any TextProcessor)? {
        switch provider {
        case .none:
            return nil
        case .appleIntelligence:
            return AppleIntelligenceProcessor(timeout: timeoutSeconds)
        case .ollama:
            guard let url = URL(string: ollamaURL) else { return nil }
            return OllamaProcessor(baseURL: url, model: ollamaModel, timeout: timeoutSeconds, session: session)
        case .anthropic:
            guard let key = keychain.read(), !key.isEmpty else { return nil }
            return AnthropicProcessor(apiKey: key, model: anthropicModel, timeout: timeoutSeconds, session: session)
        }
    }
}

func systemPrompt(instruction: String, vocabulary: [String]) -> String {
    var prompt = """
    You edit dictated text. \(instruction)
    Reply with the edited text only: no preamble, no quotes, no explanations.
    """
    if !vocabulary.isEmpty {
        prompt += "\nKeep these terms spelled exactly: \(vocabulary.joined(separator: ", "))."
    }
    return prompt
}

private func send(_ request: URLRequest, session: URLSession, who: String) async throws -> (Data, Int) {
    do {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    } catch let error as URLError where error.code == .timedOut {
        throw TextProcessorError.timedOut
    } catch {
        throw TextProcessorError.unreachable(who)
    }
}

/// Local LLM through Ollama's HTTP API (`POST /api/chat`, non-streaming).
public struct OllamaProcessor: TextProcessor {
    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval
    let session: URLSession
    public var name: String { "Ollama (\(model))" }

    public init(baseURL: URL, model: String, timeout: TimeInterval = 10, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func request(_ text: String, instruction: String, vocabulary: [String]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": systemPrompt(instruction: instruction, vocabulary: vocabulary)],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func process(_ text: String, instruction: String, vocabulary: [String]) async throws -> String {
        let (data, status) = try await send(try request(text, instruction: instruction, vocabulary: vocabulary),
                                            session: session, who: "Ollama")
        guard status == 200 else {
            throw TextProcessorError.rejected(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TextProcessorError.badResponse("no message.content")
        }
        return content
    }
}

/// Anthropic Messages API (`POST /v1/messages`). Opt-in; the key lives in the Keychain.
public struct AnthropicProcessor: TextProcessor {
    public let apiKey: String
    public let model: String
    public let timeout: TimeInterval
    let session: URLSession
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public var name: String { "Anthropic (\(model))" }

    public init(apiKey: String, model: String, timeout: TimeInterval = 10, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func request(_ text: String, instruction: String, vocabulary: [String]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "temperature": 0,
            "system": systemPrompt(instruction: instruction, vocabulary: vocabulary),
            "messages": [["role": "user", "content": text]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func process(_ text: String, instruction: String, vocabulary: [String]) async throws -> String {
        let (data, status) = try await send(try request(text, instruction: instruction, vocabulary: vocabulary),
                                            session: session, who: "Anthropic")
        guard status == 200 else {
            throw TextProcessorError.rejected(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw TextProcessorError.badResponse("no content blocks")
        }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw TextProcessorError.badResponse("empty text") }
        return text
    }
}

/// The models a provider offers (PARITY D9), for the picker in Settings.
/// User-initiated only (the Refresh button), never during dictation.
public enum ProcessorModels {
    /// Ollama `GET /api/tags`: the models pulled on that machine.
    public static func ollama(baseURL: URL, session: URLSession = .shared) async throws -> [String] {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 5)
        let (data, status) = try await send(request, session: session, who: "Ollama")
        guard status == 200 else { throw TextProcessorError.rejected(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw TextProcessorError.badResponse("no models") }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    public static let anthropicModelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=100")!

    /// Anthropic `GET /v1/models`, newest first as the API returns them.
    public static func anthropic(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: anthropicModelsEndpoint, timeoutInterval: 10)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, status) = try await send(request, session: session, who: "Anthropic")
        guard status == 200 else { throw TextProcessorError.rejected(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { throw TextProcessorError.badResponse("no data") }
        return models.compactMap { $0["id"] as? String }
    }
}

/// A generic-password Keychain item (the cloud API key).
public struct KeychainStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static let anthropic = KeychainStore(service: "dev.sayless.mac.processing", account: "anthropic-api-key")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String) -> Bool {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
