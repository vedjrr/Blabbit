import Testing
import UtterCore

@Test func rustCoreIsLinkedAndReportsRuntime() {
    #expect(coreVersion().hasPrefix("transcribe-cpp "))
}
