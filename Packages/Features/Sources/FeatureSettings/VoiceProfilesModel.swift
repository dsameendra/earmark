import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// Settings > Privacy: list, rename and delete locally stored voice profiles (DIA-AC-13). Only an embedding and a name
/// are stored, on this Mac.
@MainActor @Observable
public final class VoiceProfilesModel {
    public private(set) var profiles: [VoiceProfile] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let repository: (any VoiceProfileRepository)?

    public init(repository: (any VoiceProfileRepository)?) { self.repository = repository }

    /// `false` when no repository is wired (the section is hidden).
    public var isAvailable: Bool { repository != nil }

    public func load() async {
        guard let repository else { return }
        do {
            profiles = try await repository.profiles().sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rename(_ id: VoiceProfileID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repository, !trimmed.isEmpty, var profile = profiles.first(where: { $0.id == id }), profile.name != trimmed else { return }
        profile.name = trimmed
        do {
            try await repository.save(profile)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ id: VoiceProfileID) async {
        guard let repository else { return }
        do {
            try await repository.softDelete(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum VoiceProfileSymbol {
    static let profile = "waveform.circle"
    static let delete = "trash"
}

struct VoiceProfilesSection: View {
    let model: VoiceProfilesModel

    var body: some View {
        Section {
            if model.profiles.isEmpty {
                Text("No voice profiles saved.").foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("settings.voiceProfiles.empty")
            }
            ForEach(model.profiles) { profile in
                VoiceProfileRow(model: model, profile: profile)
            }
            if let message = model.errorMessage {
                Text(message).font(DSTypography.caption).foregroundStyle(DSColor.danger)
            }
        } header: {
            Text("Voice profiles")
        } footer: {
            Text("A voice profile is a numeric fingerprint of a voice plus a name. It stays on this Mac and never includes audio.")
        }
        .task { await model.load() }
    }
}

private struct VoiceProfileRow: View {
    let model: VoiceProfilesModel
    let profile: VoiceProfile
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: VoiceProfileSymbol.profile).foregroundStyle(DSColor.secondaryText).accessibilityHidden(true)
            TextField("Name", text: $name).textFieldStyle(.plain)
                .onSubmit { Task { await model.rename(profile.id, to: name) } }
                .accessibilityIdentifier("settings.voiceProfile.\(profile.id).name")
            Text(profile.createdAt, style: .date).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            Button(role: .destructive) {
                Task { await model.delete(profile.id) }
            } label: {
                Image(systemName: VoiceProfileSymbol.delete)
            }
            .buttonStyle(.borderless).help("Delete this voice profile").accessibilityLabel("Delete voice profile \(profile.name)")
            .accessibilityIdentifier("settings.voiceProfile.\(profile.id).delete")
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { name = profile.name }
    }
}
