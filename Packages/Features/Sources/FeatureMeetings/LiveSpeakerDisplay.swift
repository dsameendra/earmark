import AppCore
import Foundation

/// How a live caption line's speaker is shown (MTG-AC-13, DIA-AC-03/04).
public struct LiveSpeakerDisplay: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case you, remote, overflow, unknown }
    public var kind: Kind
    public var name: String
    /// Palette slot for `SpeakerChip` (0 is reserved for "You").
    public var slot: Int
    /// Remote labels stay provisional until the offline pass; the mic track ("You") is certain.
    public var isProvisional: Bool

    public static let youName = "You"
    public static let moreSpeakersName = "More speakers"

    public init(line: CaptionLine) {
        let label = line.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, label.caseInsensitiveCompare(Self.youName) == .orderedSame {
            self.init(kind: .you, name: Self.youName, slot: 0, isProvisional: false)
        } else if let slot = line.speakerSlot {
            if slot >= maxLiveSpeakers {
                self.init(kind: .overflow, name: Self.moreSpeakersName, slot: maxLiveSpeakers + 1, isProvisional: true)
            } else {
                let name = label.flatMap { $0.isEmpty ? nil : $0 } ?? "Speaker \(slot + 1)"
                self.init(kind: .remote, name: name, slot: slot + 1, isProvisional: true)
            }
        } else if let label, !label.isEmpty {
            self.init(kind: .remote, name: label, slot: 1, isProvisional: true)
        } else {
            self.init(kind: .unknown, name: "", slot: 1, isProvisional: true)
        }
    }

    public init(kind: Kind, name: String, slot: Int, isProvisional: Bool) {
        self.kind = kind
        self.name = name
        self.slot = slot
        self.isProvisional = isProvisional
    }

    public var isVisible: Bool { kind != .unknown }
}
