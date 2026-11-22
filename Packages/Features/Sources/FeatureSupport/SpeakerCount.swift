import AppCore

/// How many speakers the user expects (SCR-013). Maps to `JobSettings.diarization` (`["exact": n]`; empty means automatic).
public enum SpeakerCount: Hashable, Sendable {
    case auto
    case exact(Int)

    public static let maximum = 10

    /// `nil`, 0 and out-of-range values mean automatic.
    public init(storedValue: Int?) {
        if let value = storedValue, (1...Self.maximum).contains(value) { self = .exact(value) } else { self = .auto }
    }

    /// The value stored in settings (0 is automatic).
    public var storedValue: Int {
        switch self {
        case .auto: 0
        case .exact(let n): n
        }
    }

    /// The `JobSettings.diarization` dictionary.
    public var diarization: [String: Int] {
        switch self {
        case .auto: [:]
        case .exact(let n): ["exact": n]
        }
    }

    public init(diarization: [String: Int]) {
        if let exact = diarization["exact"] { self.init(storedValue: exact) } else { self = .auto }
    }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .exact(let n): n == 1 ? "1 speaker" : "\(n) speakers"
        }
    }

    /// Automatic, then 1...10.
    public static let choices: [SpeakerCount] = [.auto] + (1...maximum).map { .exact($0) }
}
