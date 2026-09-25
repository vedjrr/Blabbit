import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model through FoundationModels (PARITY D4;
/// Handy reaches it through a Swift shim, Utter calls it directly). Runs on this
/// Mac, so Local-only mode allows it.
public struct AppleIntelligenceProcessor: TextProcessor {
    public let timeout: TimeInterval
    public var name: String { "Apple Intelligence" }

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    /// nil when available, otherwise why not, in plain English.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable: return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }

    public func process(_ text: String, instruction: String, vocabulary: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let reason = Self.unavailableReason { throw TextProcessorError.notConfigured(reason) }
            let prompt = systemPrompt(instruction: instruction, vocabulary: vocabulary)
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: prompt)
                    do {
                        return try await session.respond(to: text, options: GenerationOptions(temperature: 0)).content
                    } catch {
                        throw TextProcessorError.badResponse("\(error)")
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw TextProcessorError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw TextProcessorError.timedOut }
                return first
            }
        }
        #endif
        throw TextProcessorError.notConfigured("Apple Intelligence needs macOS 26 or later")
    }
}
