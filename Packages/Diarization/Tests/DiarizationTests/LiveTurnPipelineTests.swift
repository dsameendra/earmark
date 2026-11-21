import AppCore
import Foundation
import Testing

@testable import Diarization

@Suite("Live turn pipeline and stabilizer") struct LiveTurnPipelineTests {
    private func turns(_ events: [LiveDiarizationEvent]) -> [SpeakerTurn] {
        events.compactMap { if case .turn(let t) = $0 { t } else { nil } }
    }
    private func finalized(_ events: [LiveDiarizationEvent]) -> [TimeInterval] {
        events.compactMap { if case .finalized(let t) = $0 { t } else { nil } }
    }
    private func limitCount(_ events: [LiveDiarizationEvent]) -> Int {
        events.filter { if case .speakerLimitReached = $0 { true } else { false } }.count
    }

    @Test func tentativeBecomesProvisionalAndFinalIsNot() {
        var p = LiveTurnPipeline()
        let a = p.ingest(tentative: [RawLiveSegment(slot: 0, start: 1, end: 2)], finalized: [])
        #expect(turns(a).count == 1 && turns(a)[0].isProvisional && turns(a)[0].slot == 0)
        let b = p.ingest(tentative: [], finalized: [RawLiveSegment(slot: 0, start: 1, end: 2.5)])
        #expect(turns(b).count == 1 && !turns(b)[0].isProvisional)
        #expect(finalized(b) == [2.5])
    }

    @Test func finalizedUpToIsMonotonic() {
        var p = LiveTurnPipeline()
        var marks: [TimeInterval] = []
        for (start, end) in [(0.0, 3.0), (1.0, 2.0), (3.0, 5.0)] {
            marks += finalized(p.ingest(tentative: [], finalized: [RawLiveSegment(slot: 1, start: start, end: end)]))
        }
        #expect(marks == [3, 5])
        #expect(finalized(p.finish(totalDuration: 4)).isEmpty)
        #expect(finalized(p.finish(totalDuration: 9)) == [9])
    }

    @Test func timeOffsetShiftsEverything() {
        var p = LiveTurnPipeline(timeOffset: 100)
        let events = p.ingest(tentative: [], finalized: [RawLiveSegment(slot: 0, start: 1, end: 2)])
        #expect(turns(events)[0].range == TimeRange(start: 101, end: 102))
        #expect(finalized(events) == [102])
    }

    // DIA-AC-04
    @Test func fifthSpeakerIsDroppedAndLimitIsSignalledOnce() {
        var p = LiveTurnPipeline()
        let first = p.ingest(
            tentative: [], finalized: [RawLiveSegment(slot: 4, start: 0, end: 2), RawLiveSegment(slot: 2, start: 2, end: 3)])
        #expect(limitCount(first) == 1)
        #expect(turns(first).map(\.slot) == [2])
        let second = p.ingest(tentative: [], finalized: [RawLiveSegment(slot: 5, start: 5, end: 7)])
        #expect(limitCount(second) == 0)
        #expect(turns(second).isEmpty)
    }

    @Test func briefExtraSlotBlipDoesNotTriggerTheLimit() {
        var p = LiveTurnPipeline()
        let events = p.ingest(tentative: [RawLiveSegment(slot: 4, start: 0, end: 0.2)], finalized: [])
        #expect(limitCount(events) == 0)
    }

    // DIA-AC-02 (live side)
    @Test func userMaximumHidesHigherSlotsSilently() {
        var p = LiveTurnPipeline(configuration: .init(options: DiarizationOptions(speakerCount: .exact(2))))
        let events = p.ingest(
            tentative: [], finalized: [RawLiveSegment(slot: 0, start: 0, end: 1), RawLiveSegment(slot: 3, start: 1, end: 2)])
        #expect(turns(events).map(\.slot) == [0])
        #expect(limitCount(events) == 0)
    }

    @Test func unchangedProvisionalTurnIsNotResent() {
        var p = LiveTurnPipeline()
        _ = p.ingest(tentative: [RawLiveSegment(slot: 0, start: 1, end: 2)], finalized: [])
        let same = p.ingest(tentative: [RawLiveSegment(slot: 0, start: 1, end: 2.1)], finalized: [])
        #expect(turns(same).isEmpty)
        let grown = p.ingest(tentative: [RawLiveSegment(slot: 0, start: 1, end: 2.5)], finalized: [])
        #expect(turns(grown).count == 1)
    }

    @Test func firstLabelIsNotDelayedBeyondMinimumTurn() {
        var p = LiveTurnPipeline()
        #expect(turns(p.ingest(tentative: [RawLiveSegment(slot: 0, start: 5, end: 5.1)], finalized: [])).isEmpty)
        #expect(turns(p.ingest(tentative: [RawLiveSegment(slot: 0, start: 5, end: 5.25)], finalized: [])).count == 1)
    }

    @Test func provisionalBeforeFinalizationHorizonIsSkipped() {
        var p = LiveTurnPipeline()
        let events = p.ingest(
            tentative: [RawLiveSegment(slot: 1, start: 0, end: 1.5)], finalized: [RawLiveSegment(slot: 0, start: 0, end: 2)])
        #expect(turns(events).filter(\.isProvisional).isEmpty)
    }

    // Stabilizer
    @Test func shortFlipKeepsTheShownSlot() {
        var s = LabelStabilizer()
        _ = s.stabilize([SpeakerTurn(range: TimeRange(start: 0, end: 4), slot: 0, isProvisional: true)])
        let out = s.stabilize([
            SpeakerTurn(range: TimeRange(start: 0, end: 1.9), slot: 0, isProvisional: true),
            SpeakerTurn(range: TimeRange(start: 2.0, end: 2.3), slot: 1, isProvisional: true),
            SpeakerTurn(range: TimeRange(start: 2.4, end: 4), slot: 0, isProvisional: true),
        ])
        #expect(out.map(\.slot) == [0])
        #expect(out[0].range == TimeRange(start: 0, end: 4))
    }

    @Test func longChangeOfSpeakerIsKept() {
        var s = LabelStabilizer()
        _ = s.stabilize([SpeakerTurn(range: TimeRange(start: 0, end: 4), slot: 0, isProvisional: true)])
        let out = s.stabilize([
            SpeakerTurn(range: TimeRange(start: 0, end: 2), slot: 0, isProvisional: true),
            SpeakerTurn(range: TimeRange(start: 2, end: 4), slot: 1, isProvisional: true),
        ])
        #expect(out.map(\.slot) == [0, 1])
    }

    @Test func distinctSpeakersAreNotMergedAcrossGaps() {
        var s = LabelStabilizer()
        let out = s.stabilize([
            SpeakerTurn(range: TimeRange(start: 0, end: 1), slot: 0, isProvisional: true),
            SpeakerTurn(range: TimeRange(start: 1.1, end: 2), slot: 1, isProvisional: true),
        ])
        #expect(out.map(\.slot) == [0, 1])
    }
}
