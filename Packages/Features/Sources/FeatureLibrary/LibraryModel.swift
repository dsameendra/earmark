import AppCore
import FeatureSupport
import Foundation
import Observation

/// Which Library list a model/view shows.
public enum LibraryMode: Sendable {
    case library
    case recentlyDeleted
}

/// Drives the Library and Recently Deleted lists.
@MainActor @Observable
public final class LibraryModel {
    public let mode: LibraryMode
    public private(set) var items: [Transcript] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public var searchText = ""
    public var selection: Set<TranscriptID> = []

    @ObservationIgnored private let transcripts: any TranscriptRepository

    public init(services: AppServices, mode: LibraryMode) {
        self.mode = mode
        transcripts = services.transcripts
    }

    /// Items matching the current search text.
    public var visibleItems: [Transcript] {
        searchText.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Loads (or reloads) the list.
    public func reload() async {
        do {
            items = try await transcripts.list(LibraryQuery(sort: .createdDesc, deletedOnly: mode == .recentlyDeleted))
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    /// Soft-deletes the selection (Library).
    public func deleteSelected() async {
        let ids = Array(selection)
        await apply { try await $0.softDelete(ids, at: Date()) }
    }

    /// Restores the selection (Recently Deleted).
    public func restoreSelected() async {
        let ids = Array(selection)
        await apply { try await $0.restore(ids) }
    }

    /// Permanently removes the selection (Recently Deleted).
    public func purgeSelected() async {
        let ids = Array(selection)
        await apply { try await $0.purge(ids) }
    }

    private func apply(_ change: (any TranscriptRepository) async throws -> Void) async {
        do {
            try await change(transcripts)
            selection = []
        } catch {
            errorMessage = String(describing: error)
        }
        await reload()
    }
}
