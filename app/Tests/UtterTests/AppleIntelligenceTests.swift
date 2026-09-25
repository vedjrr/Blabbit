import Foundation
import Testing
@testable import UtterKit

/// PARITY D4: the on-device Apple Intelligence model, for real (no stub).
@Suite(.enabled(if: AppleIntelligenceProcessor.unavailableReason == nil,
                "Apple Intelligence isn't available on this Mac"))
struct AppleIntelligenceTests {
    @Test func rewritesOnDevice() async throws {
        let started = Date()
        let out = try await AppleIntelligenceProcessor(timeout: 30)
            .process("um so basically we should like ship it on friday", instruction: TextPipeline.professionalInstruction, vocabulary: ["HoldMyCode"])
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.info("apple intelligence test ms=\(ms) chars=\(out.count)")
        #expect(!out.isEmpty)
        #expect(!out.lowercased().contains("um so"), "the filler was kept: \(out)")
        #expect(out.lowercased().contains("friday"))
    }

    @Test func countsAsLocal() {
        var s = ProcessorSettings()
        s.provider = .appleIntelligence
        #expect(s.isLocal, "Local-only mode must allow the on-device model")
        #expect(s.makeProcessor() is AppleIntelligenceProcessor)
    }
}
