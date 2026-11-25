import Foundation

/// A data-only Hugging Face source, inspected before any weights are acquired. It is not a claim of model compatibility.
public struct HuggingFaceImportLocation: Sendable, Hashable {
    public enum Selection: String, Sendable { case repository, folder, file }
    public let repository: String
    public let revision: String
    public let path: String
    public let selection: Selection

    public enum InvalidSource: Error, LocalizedError, Equatable {
        case unsupportedURL, invalidRepository, invalidPath
        public var errorDescription: String? {
            switch self {
            case .unsupportedURL: "Use a Hugging Face model repository, folder or file link without credentials or a fragment."
            case .invalidRepository: "Enter a model repository as owner/model-name."
            case .invalidPath: "This model link has an unsupported revision or file path."
            }
        }
    }

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = text.contains("://") ? text : "https://huggingface.co/" + text
        guard let url = URLComponents(string: full), url.scheme == "https", url.host == "huggingface.co",
            url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443,
            (url.queryItems ?? []).allSatisfy({ $0.name == "download" && $0.value == "true" })
        else { throw InvalidSource.unsupportedURL }
        let encoded = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        var parts = Array(encoded.dropFirst())
        if parts.last == "" { parts.removeLast() }
        let decoded = try parts.map { part -> String in
            guard let value = String(part).removingPercentEncoding, !value.isEmpty,
                !value.contains("/"), !value.contains("\\"), !value.contains("%"),
                value != ".", value != "..", !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { throw InvalidSource.invalidPath }
            return value
        }
        guard decoded.count >= 2, Self.identifier(decoded[0]), Self.identifier(decoded[1]),
            !["datasets", "spaces", "api"].contains(decoded[0])
        else { throw InvalidSource.invalidRepository }
        repository = decoded[0] + "/" + decoded[1]
        if decoded.count == 2 {
            revision = "main"; path = ""; selection = .repository
        } else {
            guard decoded.count >= 4, Self.identifier(decoded[3]) else { throw InvalidSource.invalidPath }
            let rest = decoded.dropFirst(4).joined(separator: "/")
            switch decoded[2] {
            case "tree": selection = rest.isEmpty ? .repository : .folder
            case "resolve", "blob":
                guard !rest.isEmpty else { throw InvalidSource.invalidPath }
                selection = .file
            default: throw InvalidSource.invalidPath
            }
            revision = decoded[3]; path = rest
        }
    }

    /// Metadata must resolve the requested revision to this immutable form before acquisition starts.
    public static func isCommit(_ value: String) -> Bool {
        value.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil
    }

    private static func identifier(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
}
