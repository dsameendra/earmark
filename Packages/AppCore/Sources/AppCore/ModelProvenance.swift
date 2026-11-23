import Foundation

/// How captions are produced; buffered recognition is not native cache-aware streaming.
public enum ModelStreamingImplementation: String, Codable, Sendable, Hashable { case buffered, native }

/// Describes checks performed during acquisition. Neither value claims independently benchmarked quality.
public enum ModelValidationLevel: String, Codable, Sendable, Hashable { case notChecked, formatChecked, nativeInferenceChecked }

public struct ModelArtifactDigest: Codable, Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256
    }
}

/// Acquisition evidence, retained with a model through restart. Relative filenames avoid recording original user paths.
/// This record alone cannot authorize a runtime, capabilities, remote code or an import profile.
public struct ModelProvenance: Codable, Sendable, Hashable {
    public let repository: String?
    public let revision: String?
    public let profileID: String
    public let profileVersion: Int
    public let artifacts: [ModelArtifactDigest]
    public let validation: ModelValidationLevel
    public init(
        repository: String? = nil, revision: String? = nil, profileID: String, profileVersion: Int,
        artifacts: [ModelArtifactDigest], validation: ModelValidationLevel
    ) {
        self.repository = repository; self.revision = revision
        self.profileID = profileID; self.profileVersion = profileVersion
        self.artifacts = artifacts; self.validation = validation
    }
}
