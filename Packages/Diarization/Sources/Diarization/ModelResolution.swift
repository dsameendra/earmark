import AppCore
import Foundation

/// Catalog identifiers of the diarization models owned by the `Models` package (see `Catalog.swift`).
public enum DiarizationModelID {
    /// Offline pyannote Community-1 pipeline (segmentation + FBank + WeSpeaker embedding + PLDA).
    public static let community1: ModelID = "fluidaudio/diarization-community-1"
    /// LS-EEND `.ami` streaming checkpoint (primary live engine).
    public static let lseendAMI: ModelID = "fluidaudio/ls-eend-ami"
    /// Sortformer v2 streaming weights (fallback live engine). Never the v2.1 weights.
    public static let sortformerV2: ModelID = "fluidaudio/sortformer-v2"
}

/// Files a FluidAudio engine needs, found **inside the folder `ModelManaging.location(of:)` returns**.
///
/// The app's model folders keep the Hugging Face repo layout, which differs from FluidAudio's own cache layout, so files
/// are found by a bounded recursive search for their name instead of hard-coded paths. Nothing here ever touches the
/// network or `~/Library/Application Support/FluidAudio`; a missing file throws ``AppError/modelNotInstalled(_:)``.
enum ModelFiles {
    static let offlineModelNames = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
    static let pldaParameters = "plda-parameters.json"
    static let lseendAMIModel = "ls_eend_ami_100ms.mlmodelc"
    static let sortformerFastV2 = "Sortformer_v2.mlmodelc"
    static let sortformerBalancedV2 = "SortformerNvidiaLow_v2.mlmodelc"

    /// The directory (the root itself or a descendant, at most `maxDepth` levels down) that directly contains every name.
    static func directory(containingAll names: [String], under root: URL, maxDepth: Int = 4) -> URL? {
        let fm = FileManager.default
        func has(_ dir: URL) -> Bool {
            names.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
        if has(root) { return root }
        guard maxDepth > 0, let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard child.pathExtension != "mlmodelc", (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if let found = directory(containingAll: names, under: child, maxDepth: maxDepth - 1) { return found }
        }
        return nil
    }

    /// The first item named `name` (a file or a compiled `.mlmodelc` bundle) at most `maxDepth` levels below `root`.
    static func item(named name: String, under root: URL, maxDepth: Int = 6) -> URL? {
        directory(containingAll: [name], under: root, maxDepth: maxDepth)?.appendingPathComponent(name)
    }

    /// Resolves an installed model folder, mapping every failure to `modelNotInstalled`.
    static func folder(of model: ModelID, using models: any ModelManaging) async throws -> URL {
        do {
            return try await models.location(of: model)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.modelNotInstalled(model)
        }
    }
}
