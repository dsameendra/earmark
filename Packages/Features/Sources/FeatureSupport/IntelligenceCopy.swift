import AppCore
import Foundation

/// Plain-language wording for what the on-device model needs.
public enum IntelligenceCopy {
    public static func explain(_ reason: IntelligenceAvailability.Reason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac does not support Apple Intelligence, so summaries and chat are not available. Notes, folders and slides still work."
        case .notEnabled: "Turn on Apple Intelligence in System Settings to summarise and chat. Notes, folders and slides work without it."
        case .modelNotReady: "macOS is still preparing Apple Intelligence. Summaries and chat will be available when it finishes."
        case .osTooOld: "Summaries and chat need macOS 26 with Apple Intelligence."
        case .other(let text): "Apple Intelligence is not available right now (\(text))."
        }
    }

    public static func languageNotSupported(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "Apple's on-device model cannot work with \(name) yet. You can still write notes, attach slides and use the transcript as normal."
    }
}
