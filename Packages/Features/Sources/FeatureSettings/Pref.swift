import AppCore
import Observation
import SwiftUI

/// One typed, immediately persisted setting (SET-AC-01). Reads fall back to `fallback` when the key is absent.
@MainActor @Observable
public final class Pref<Value: Codable & Sendable & Equatable> {
    public private(set) var value: Value
    @ObservationIgnored private let key: String
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let fallback: Value

    public init(_ key: String, default fallback: Value, store: any SettingsStore) {
        self.key = key
        self.fallback = fallback
        self.store = store
        value = fallback
    }

    public func load() async {
        value = await store.value(for: key, as: Value.self) ?? fallback
    }

    /// Updates the in-memory value and persists it.
    public func set(_ newValue: Value) async {
        value = newValue
        await store.set(newValue, for: key)
    }

    /// Synchronous update for SwiftUI bindings; persistence happens in a detached main-actor task.
    public func update(_ newValue: Value) {
        value = newValue
        let store = store
        let key = key
        Task { await store.set(newValue, for: key) }
    }

    public var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.update($0) })
    }
}
