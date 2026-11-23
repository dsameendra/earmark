import AppCore
import CryptoKit
import Foundation

/// Offline, additive repair for the exact v3 vocabulary shipped by the old download manifest.
/// Both upstream names have identical bytes at the pinned checkpoint. Unknown files are never promoted or overwritten.
enum ParakeetVocabularyCompatibility {
    static func repair(in folder: URL) throws {
        let manager = FileManager.default
        let canonical = folder.appendingPathComponent("parakeet_vocab.json")
        guard !manager.fileExists(atPath: canonical.path) else { return }
        let legacy = folder.appendingPathComponent("parakeet_v3_vocab.json")
        guard manager.fileExists(atPath: legacy.path) else { return }
        let data = try Data(contentsOf: legacy)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735" else {
            throw AppError.other("The older Parakeet vocabulary could not be verified. Reinstall Parakeet in Settings > Models.")
        }
        try data.write(to: canonical, options: .atomic)
    }
}
