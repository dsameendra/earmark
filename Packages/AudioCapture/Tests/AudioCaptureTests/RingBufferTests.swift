import Foundation
import Testing

@testable import AudioCapture

@Suite struct RingBufferTests {
    @Test func capacityRoundsUpToPowerOfTwo() {
        #expect(RingBuffer<Float>(minimumCapacity: 1000).capacity == 1024)
        #expect(RingBuffer<Float>(minimumCapacity: 1024).capacity == 1024)
        #expect(RingBuffer<Float>(minimumCapacity: 0).capacity == 2)
    }

    @Test func wrapAroundPreservesOrder() {
        let ring = RingBuffer<Float>(minimumCapacity: 8)
        var next: Float = 0
        var expected: Float = 0
        for _ in 0..<50 {
            let batch = (0..<5).map { _ -> Float in
                defer { next += 1 }
                return next
            }
            #expect(batch.withUnsafeBufferPointer { ring.write($0) } == 5)
            for value in ring.read(maxCount: 5) {
                #expect(value == expected)
                expected += 1
            }
        }
        #expect(ring.availableToRead == 0)
    }

    @Test func overflowDropsAndCounts() {
        let ring = RingBuffer<Float>(minimumCapacity: 8)
        let data = [Float](repeating: 1, count: 12)
        #expect(data.withUnsafeBufferPointer { ring.write($0) } == 8)
        #expect(ring.droppedCount == 4)
        #expect(ring.availableToWrite == 0)
        #expect(ring.discard(3) == 3)
        #expect(ring.availableToWrite == 3)
        #expect(ring.read(maxCount: 100).count == 5)
    }

    @Test func stressSPSCDeliversEverySampleInOrder() async {
        let ring = RingBuffer<Float>(minimumCapacity: 4_096)
        let total = 8_000_000
        let producer = Task.detached {
            var sent = 0
            var scratch = [Float](repeating: 0, count: 700)
            while sent < total {
                let n = min(Int.random(in: 1...700), total - sent)
                for i in 0..<n { scratch[i] = Float(sent + i) }  // exactly representable below 2^24
                var offset = 0
                while offset < n {  // spin on full: the test wants lossless delivery
                    let accepted = scratch.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[offset..<n])) }
                    offset += accepted
                    if accepted == 0 { sched_yield() }
                }
                sent += n
            }
        }
        let consumer = Task.detached { () -> Bool in
            var received = 0
            var ok = true
            var scratch = [Float](repeating: 0, count: 1_000)
            while received < total {
                let n = scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
                if n == 0 {
                    sched_yield()
                    continue
                }
                for i in 0..<n where scratch[i] != Float(received + i) { ok = false }
                received += n
            }
            return ok
        }
        await producer.value
        #expect(await consumer.value)
        #expect(ring.availableToRead == 0)
    }
}
