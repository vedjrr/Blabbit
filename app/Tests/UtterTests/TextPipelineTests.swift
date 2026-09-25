import Foundation
import Testing
@testable import UtterKit

/// A processor double (test target only).
struct FakeProcessor: TextProcessor {
    var reply: Result<String, TextProcessorError>
    let calls: Counter
    var name: String { "Fake" }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    func process(_ text: String, instruction: String, vocabulary: [String]) async throws -> String {
        calls.bump()
        return try reply.get()
    }
}

/// Answers every request with a canned response and records it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        guard let (status, data) = Self.handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct TextPipelineTests {
    var settings: TextPipelineSettings {
        var s = TextPipelineSettings()
        s.vocabulary = ["HoldMyCode", "Decivra", "Maynooth", "PostgreSQL", "TypeScript", "SwiftUI", "WhisperKit"]
        return s
    }

    @Test func localStagesRunThroughTheRustCore() async {
        var s = settings
        let raw = "um so i think we should uh use post gur SQL and type script, new paragraph, thanks"
        s.mode = .clean
        let clean = await TextPipeline(settings: s).run(raw)
        #expect(clean.final == "So I think we should use PostgreSQL and TypeScript.\n\nThanks.")
        #expect(clean.raw == raw && clean.processor == nil)
        #expect(clean.changes.contains { $0.contains("PostgreSQL") })
        s.mode = .exact
        #expect(await TextPipeline(settings: s).run(raw).final == "um so i think we should uh use PostgreSQL and TypeScript, new paragraph, thanks")
        s.mode = .code
        #expect(await TextPipeline(settings: s).run("um call the javascript api").final == "call the JavaScript API")
    }

    @Test func localModesNeverCallAProcessor() async {
        let calls = FakeProcessor.Counter()
        let fake = FakeProcessor(reply: .success("SHOULD NOT APPEAR"), calls: calls)
        for mode in [TextPipelineSettings.Mode.exact, .clean, .code] {
            var s = settings
            s.mode = mode
            let out = await TextPipeline(settings: s, processor: fake).run("hello there")
            #expect(!out.final.contains("SHOULD NOT"))
        }
        #expect(calls.value == 0, "Exact/Clean/Code must never use an AI processor (or the network)")
    }

    @Test func processorRefinesAndFailuresFallBack() async {
        var s = settings
        s.mode = .professional
        let calls = FakeProcessor.Counter()
        let ok = await TextPipeline(settings: s, processor: FakeProcessor(reply: .success("  Polished text.  "), calls: calls)).run("um polish this")
        #expect(ok.final == "Polished text." && ok.processor == "Fake" && ok.processorProblem == nil)

        let down = await TextPipeline(settings: s, processor: FakeProcessor(reply: .failure(.unreachable("Ollama")), calls: calls)).run("um polish this")
        #expect(down.final == "Polish this.", "falls back to the local result")
        #expect(down.processorProblem == TextProcessorError.unreachable("Ollama").userMessage)

        let empty = await TextPipeline(settings: s, processor: FakeProcessor(reply: .success("   "), calls: calls)).run("um polish this")
        #expect(empty.final == "Polish this.")

        // No processor configured: Professional still works, locally.
        #expect(await TextPipeline(settings: s).run("um polish this").final == "Polish this.")
    }

    @Test func settingsPersistAndTolerateOldData() throws {
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TextPipelineSettings.load(from: defaults) == TextPipelineSettings())
        var s = settings
        s.mode = .code
        s.language = "de"
        s.save(to: defaults)
        #expect(TextPipelineSettings.load(from: defaults) == s)
        defaults.set(Data(#"{"mode":"exact","futureKey":1}"#.utf8), forKey: TextPipelineSettings.defaultsKey)
        let old = TextPipelineSettings.load(from: defaults)
        #expect(old.mode == .exact && old.removeFillers && old.vocabulary.isEmpty)
    }

    @Test func languageOnlyGoesToModelsThatSupportIt() {
        var s = TextPipelineSettings()
        #expect(s.effectiveLanguage(forModelLanguages: ["en", "de"]) == nil, "auto by default")
        s.language = "de"
        #expect(s.effectiveLanguage(forModelLanguages: ["en", "de", "fr"]) == "de")
        #expect(s.effectiveLanguage(forModelLanguages: ["en"]) == nil, "Parakeet V2 / Moonshine: English only")
        #expect(s.effectiveLanguage(forModelLanguages: nil) == nil)
    }

    @Test func whisperGetsTheVocabularyAsPrompt() {
        #expect(settings.initialPrompt(forModelFamily: "whisper", modelID: "whisper-small")
            == "We talked about HoldMyCode, Decivra, Maynooth, PostgreSQL, TypeScript, SwiftUI and WhisperKit.")
        #expect(settings.initialPrompt(forModelFamily: "whisper", modelID: "whisper-large-v3-turbo") == nil, "Turbo measured worse with a prompt")
        #expect(settings.initialPrompt(forModelFamily: "parakeet") == nil)
        #expect(TextPipelineSettings().initialPrompt(forModelFamily: "whisper") == nil)
    }

    @Test func ollamaRequestAndReply() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"message":{"role":"assistant","content":"Fixed text."},"done":true}"#.utf8)) }
        let p = OllamaProcessor(baseURL: URL(string: "http://localhost:11434")!, model: "llama3.2", session: StubURLProtocol.session())
        #expect(try await p.process("fix this", instruction: "Fix it.", vocabulary: ["Decivra"]) == "Fixed text.")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat" && request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "llama3.2" && body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["role"] == "system" && messages[0]["content"]!.contains("Decivra"))
        #expect(messages[1] == ["role": "user", "content": "fix this"])

        StubURLProtocol.handler = { _ in (500, Data("boom".utf8)) }
        await #expect(throws: TextProcessorError.rejected(status: 500, detail: "boom")) {
            try await p.process("x", instruction: "y", vocabulary: [])
        }
        StubURLProtocol.handler = nil // connection refused
        await #expect(throws: TextProcessorError.unreachable("Ollama")) {
            try await p.process("x", instruction: "y", vocabulary: [])
        }
    }

    @Test func anthropicRequestAndReply() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"Polished."}],"stop_reason":"end_turn"}"#.utf8)) }
        let p = AnthropicProcessor(apiKey: "sk-test", model: "claude-haiku-4-5-20251001", session: StubURLProtocol.session())
        #expect(try await p.process("polish", instruction: "Polish.", vocabulary: []) == "Polished.")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url == AnthropicProcessor.endpoint)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5-20251001" && body["system"] is String)

        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"type":"authentication_error"}}"#.utf8)) }
        do {
            _ = try await p.process("x", instruction: "y", vocabulary: [])
            Issue.record("expected a rejection")
        } catch let error as TextProcessorError {
            #expect(error.userMessage.contains("rejected the API key"))
        }
        StubURLProtocol.handler = nil
    }

    @Test func localOnlyMeansThisMac() {
        var p = ProcessorSettings()
        #expect(p.isLocal)
        p.provider = .ollama
        for local in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            p.ollamaURL = local
            #expect(p.isLocal, "\(local)")
        }
        for remote in ["http://10.0.0.5:11434", "http://my-server.lan:11434", "https://ollama.example.com", "not a url"] {
            p.ollamaURL = remote
            #expect(!p.isLocal, "\(remote) is not on this Mac")
        }
        p.provider = .anthropic
        #expect(!p.isLocal)
    }

    @Test func cloudNeedsAKeyInTheKeychain() {
        let store = KeychainStore(service: "dev.utter.test.\(UUID().uuidString)", account: "anthropic")
        defer { store.delete() }
        var p = ProcessorSettings()
        #expect(p.provider == .none && p.makeProcessor(keychain: store) == nil, "cloud is off by default")
        p.provider = .anthropic
        #expect(p.makeProcessor(keychain: store) == nil, "no key, no cloud processor")
        #expect(store.write("sk-secret"))
        #expect(store.read() == "sk-secret")
        #expect(p.makeProcessor(keychain: store)?.name == "Anthropic (claude-haiku-4-5-20251001)")
        #expect(store.delete() && store.read() == nil)
        p.provider = .ollama
        #expect(p.makeProcessor(keychain: store)?.name == "Ollama (llama3.2)")
    }
}

/// PARITY D5 (saved prompts) and D9 (provider model lists).
extension TextPipelineTests {
    @Test func olderCustomInstructionBecomesTheFirstPrompt() throws {
        let old = #"{"mode":"custom","customInstruction":"Make it rhyme."}"#
        let s = try JSONDecoder().decode(TextPipelineSettings.self, from: Data(old.utf8))
        #expect(s.customInstruction == "Make it rhyme.")
        #expect(s.prompts.first?.name == "My instruction")
        #expect(s.prompts.count == SavedPrompt.starters.count + 1)
    }

    @Test func defaultInstructionNeedsNoMigration() throws {
        let old = #"{"customInstruction":"Rewrite this as a concise, friendly message."}"#
        let s = try JSONDecoder().decode(TextPipelineSettings.self, from: Data(old.utf8))
        #expect(s.prompts == SavedPrompt.starters)
    }

    @Test func selectedPromptRoundTripsAndDrivesTheInstruction() throws {
        var s = TextPipelineSettings()
        s.selectedPromptID = "bullets"
        #expect(s.customInstruction.contains("bullet points"))
        s.customInstruction = "Shout it."
        let back = try JSONDecoder().decode(TextPipelineSettings.self, from: JSONEncoder().encode(s))
        #expect(back.selectedPromptID == "bullets" && back.customInstruction == "Shout it.")
        #expect(back.prompts.first { $0.id == "friendly" }?.instruction == SavedPrompt.starters[0].instruction)
    }

    @Test func ollamaTagsAreListed() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"models":[{"name":"qwen2.5:7b"},{"name":"llama3.2:latest"}]}"#.utf8)) }
        let models = try await ProcessorModels.ollama(baseURL: URL(string: "http://localhost:11434")!, session: StubURLProtocol.session())
        #expect(models == ["llama3.2:latest", "qwen2.5:7b"])
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/tags")
    }

    @Test func anthropicModelsAreListedWithTheKey() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"claude-sonnet-5","type":"model"},{"id":"claude-haiku-4-5-20251001","type":"model"}]}"#.utf8)) }
        let models = try await ProcessorModels.anthropic(apiKey: "sk-test", session: StubURLProtocol.session())
        #expect(models == ["claude-sonnet-5", "claude-haiku-4-5-20251001"])
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.url?.path == "/v1/models")
    }

    @Test func aFailedListIsAPlainError() async {
        StubURLProtocol.handler = { _ in (401, Data("bad key".utf8)) }
        await #expect(throws: TextProcessorError.self) {
            try await ProcessorModels.anthropic(apiKey: "sk-bad", session: StubURLProtocol.session())
        }
    }
}
