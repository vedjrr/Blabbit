import Foundation
import Testing
@testable import SayLessKit

@Suite struct SampleRingTests {
    func write(_ ring: SampleRing, _ values: [Float], host: UInt64, end: UInt64) {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count, hostNs: host, endNs: end, nowNs: host + 1) }
    }

    @Test func preservesOrderAcrossWrapAround() {
        let ring = SampleRing(capacity: 8)
        var out: [Float] = []
        write(ring, [1, 2, 3, 4, 5, 6], host: 10, end: 20)
        ring.drain(into: &out)
        write(ring, [7, 8, 9, 10, 11], host: 20, end: 30) // wraps
        ring.drain(into: &out)
        #expect(out == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let c = ring.cursor.withLock { $0 }
        #expect(c.dropped == 0)
        #expect(c.firstSampleNs == 10)
        #expect(c.firstCallbackNs == 11)
        #expect(c.lastEndNs == 30)
    }

    @Test func countsDroppedSamplesWhenFull() {
        let ring = SampleRing(capacity: 4)
        write(ring, [1, 2, 3], host: 0, end: 1)
        write(ring, [4, 5, 6], host: 1, end: 2) // only 1 fits
        var out: [Float] = []
        ring.drain(into: &out)
        #expect(out == [1, 2, 3, 4])
        #expect(ring.cursor.withLock { $0.dropped } == 2)
    }

    @Test func signalsWhenAudioUpToReleaseHasArrived() {
        let ring = SampleRing(capacity: 64)
        ring.cursor.withLock { $0.waitUntilNs = 100 }
        write(ring, [0, 0], host: 50, end: 90)
        #expect(ring.tailArrived.wait(timeout: .now()) == .timedOut)
        write(ring, [0, 0], host: 90, end: 110)
        #expect(ring.tailArrived.wait(timeout: .now() + .milliseconds(100)) == .success)
        #expect(ring.cursor.withLock { $0.waitUntilNs } == nil)
    }

    @Test func resetClearsStateAndPendingSignals() {
        let ring = SampleRing(capacity: 16)
        ring.cursor.withLock { $0.waitUntilNs = 1 }
        write(ring, [1], host: 0, end: 5)
        ring.reset()
        #expect(ring.tailArrived.wait(timeout: .now()) == .timedOut)
        var out: [Float] = []
        ring.drain(into: &out)
        #expect(out.isEmpty)
        #expect(ring.cursor.withLock { $0.firstSampleNs } == nil)
    }

    @Test func concurrentProducerAndConsumerLoseNothing() async {
        let ring = SampleRing(capacity: 48_000)
        let total = 480 * 420
        let producer = Task.detached {
            var next: Float = 0
            var chunk = [Float](repeating: 0, count: 480)
            var written = 0
            while written < total {
                for i in chunk.indices { chunk[i] = next; next += 1 }
                chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 480, hostNs: 0, endNs: 0, nowNs: 0) }
                written += 480
                if written % 9_600 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        var out: [Float] = []
        while out.count < total {
            ring.drain(into: &out)
            await Task.yield()
        }
        await producer.value
        ring.drain(into: &out)
        #expect(ring.cursor.withLock { $0.dropped } == 0)
        #expect(out.count == total)
        #expect(out.enumerated().allSatisfy { Float($0.offset) == $0.element })
    }
}
