import AppCore
import Foundation

/// Offline intake for reviewed recipes only. A repository link selects catalog
/// variants; it never turns an arbitrary checkpoint into an executable model.
public enum ReviewedHuggingFaceModels {
    public struct UnsupportedSource: Error, LocalizedError, Sendable {
        public var errorDescription: String? {
            "This source has no supported model recipe in this build. Choose a reviewed repository or variant folder. Use its reviewed commit or main; other revisions need validation first."
        }
    }

    public static func resolve(_ input: String, catalog: [ModelDescriptor] = BuiltInCatalog.models) throws -> [ModelID] {
        let requested = try HuggingFaceImportLocation(input)
        let matches = catalog.filter { descriptor in
            guard descriptor.isRunnable, !descriptor.isCustom, let url = descriptor.sourceURL,
                  let recipe = try? HuggingFaceImportLocation(url.absoluteString),
                  HuggingFaceImportLocation.isCommit(recipe.revision),
                  requested.repository == recipe.repository,
                  requested.revision == "main" || requested.revision.lowercased() == recipe.revision.lowercased()
            else { return false }
            switch requested.selection {
            case .repository: return true
            case .folder: return recipe.selection == .folder && requested.path == recipe.path
            case .file: return recipe.selection == .file && requested.path == recipe.path
            }
        }
        guard !matches.isEmpty else { throw UnsupportedSource() }
        return matches.map(\.id)
    }
}
