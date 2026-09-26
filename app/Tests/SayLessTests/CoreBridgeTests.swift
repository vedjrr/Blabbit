import Testing
import SayLessCore

@Test func rustCoreIsLinkedAndReportsRuntime() {
    #expect(coreVersion().hasPrefix("transcribe-cpp "))
}
