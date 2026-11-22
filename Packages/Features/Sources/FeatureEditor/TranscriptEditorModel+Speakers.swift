import AppCore
import FeatureSupport
import Foundation

// MARK: - Word-level speaker reassignment (DIA-AC-11)

extension TranscriptEditorModel {
    /// Gives the words `wordRange` of a segment to `speakerID`, splitting the segment at word boundaries when the
    /// range does not cover all of it. One undo step restores the original segment exactly.
    /// Returns `false` when nothing changed.
    @discardableResult
    public func reassignWords(in id: SegmentID, wordRange: Range<Int>, to speakerID: SpeakerID?) -> Bool {
        guard let position = segments.firstIndex(where: { $0.id == id }) else { return false }
        let original = segments[position]
        var prepared = original
        if prepared.words.isEmpty { prepared.words = SegmentOps.synthesizedWords(for: original) }
        let lower = max(0, wordRange.lowerBound)
        let upper = min(prepared.words.count, wordRange.upperBound)
        guard lower < upper, original.speakerID != speakerID else { return false }

        if lower == 0 && upper == prepared.words.count {
            setSpeaker(speakerID, for: [id])
            return true
        }

        var tail: Segment?
        var head = prepared
        if upper < prepared.words.count {
            guard let (first, second) = SegmentOps.split(prepared, beforeWord: upper) else { return false }
            head = first
            tail = second
        }
        var pre: Segment?
        var middle = head
        if lower > 0 {
            guard let (first, second) = SegmentOps.split(head, beforeWord: lower) else { return false }
            pre = first
            middle = second
        }
        middle.speakerID = speakerID

        let pieces = [pre, middle, tail].compactMap { $0 }
        let inserted = pieces.dropFirst().enumerated().map { EditDelta.Placed(index: position + 1 + $0.offset, segment: $0.element) }
        perform(
            EditDelta(
                name: "Change Speaker", replaced: [.init(before: original, after: pieces[0])], inserted: Array(inserted)))
        return true
    }

    /// Gives the words of a segment from the playhead onward to `speakerID` (the playhead must fall inside the segment).
    @discardableResult
    public func reassignWordsFromPlayhead(in id: SegmentID, to speakerID: SpeakerID?) -> Bool {
        guard let segment = segment(id) else { return false }
        let words = segment.words.isEmpty ? SegmentOps.synthesizedWords(for: segment) : segment.words
        let time = playback.currentTime
        guard let index = words.firstIndex(where: { $0.start >= time }) else { return false }
        return reassignWords(in: id, wordRange: index..<words.count, to: speakerID)
    }

    /// True when the playhead lies inside the segment, so "from playhead" can split it.
    public func playheadIsInside(_ id: SegmentID) -> Bool {
        guard let segment = segment(id) else { return false }
        return playback.currentTime > segment.start && playback.currentTime < segment.end
    }
}

// MARK: - Live label vs final reconciliation (DIA-AC-06)

extension TranscriptEditorModel {
    func loadReconciliation() async {
        let report = await settings.value(for: SettingsKey.speakerReconciliation(transcriptID.description), as: ReconciliationReport.self)
        reconciliation = report.flatMap { $0.acknowledged || $0.isEmpty ? nil : $0 }
    }

    /// Segments the offline pass relabelled and the user has not yet seen flagged.
    public var relabeledSegmentIDs: Set<SegmentID> { Set(reconciliation?.relabeledSegmentIDs ?? []) }

    /// Marks the relabel as seen, so it is never flagged again.
    public func acknowledgeReconciliation() {
        guard var report = reconciliation else { return }
        report.acknowledged = true
        reconciliation = nil
        saveSetting(report, for: SettingsKey.speakerReconciliation(transcriptID.description))
    }
}

// MARK: - Voice profiles (DIA-AC-13)

extension TranscriptEditorModel {
    /// Whether "Save voice profile" can work: storage, an embedding provider and a playable media file.
    public var canSaveVoiceProfiles: Bool { voiceProfiles != nil && embeddings != nil && mediaURL != nil }

    /// Stores the speaker's voice (embedding and name only) locally and links it to the speaker.
    @discardableResult
    public func saveVoiceProfile(for speakerID: SpeakerID) async -> Bool {
        voiceProfileError = nil
        guard let voiceProfiles, let embeddings, let mediaURL, let speaker = speaker(speakerID) else { return false }
        // The longest stretch of this speaker (capped) gives the cleanest embedding.
        let best = segments.filter { $0.speakerID == speakerID && !$0.isIgnored }.max { $0.end - $0.start < $1.end - $1.start }
        guard let best else {
            voiceProfileError = "This speaker has no segments to learn a voice from."
            return false
        }
        let range = TimeRange(start: best.start, end: min(best.end, best.start + 30))
        do {
            let embedding = try await embeddings.embedding(file: mediaURL, range: range)
            let profile = VoiceProfile(name: speaker.name, embedding: embedding)
            try await voiceProfiles.save(profile)
            linkVoiceProfile(profile.id, to: speakerID, name: "Save Voice Profile")
            return true
        } catch {
            voiceProfileError = error.localizedDescription
            return false
        }
    }

    /// Deletes the speaker's stored voice profile and unlinks it.
    @discardableResult
    public func removeVoiceProfile(for speakerID: SpeakerID) async -> Bool {
        voiceProfileError = nil
        guard let voiceProfiles, let profileID = speaker(speakerID)?.voiceProfileID else { return false }
        do {
            try await voiceProfiles.softDelete(profileID)
            linkVoiceProfile(nil, to: speakerID, name: "Delete Voice Profile")
            return true
        } catch {
            voiceProfileError = error.localizedDescription
            return false
        }
    }

    private func linkVoiceProfile(_ id: VoiceProfileID?, to speakerID: SpeakerID, name: String) {
        guard let before = transcript?.speakers, let index = before.firstIndex(where: { $0.id == speakerID }) else { return }
        var after = before
        after[index].voiceProfileID = id
        perform(EditDelta(name: name, speakers: .init(before: before, after: after)))
    }
}
