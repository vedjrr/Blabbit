import Testing
import BlabbitCore

@Test func rustCoreIsLinkedAndReportsRuntime() {
    #expect(coreVersion().hasPrefix("transcribe-cpp "))
}
