import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// Settings > Intelligence: how summaries and chat behave, and whether Apple Intelligence is ready on this Mac.
@MainActor @Observable
public final class IntelligenceSettingsModel {
    public private(set) var availability: IntelligenceAvailability = .unavailable(.osTooOld)
    public private(set) var hasService = false
    public let summaryStyle: Pref<String>
    public let summaryLanguage: Pref<String>
    public let autoSummarize: Pref<Bool>
    public let includeNotes: Pref<Bool>
    public let includeFiles: Pref<Bool>
    public let keepChat: Pref<Bool>
    public private(set) var chatsCleared = false

    @ObservationIgnored private let intelligence: (any IntelligenceServicing)?
    @ObservationIgnored private let clearAll: (@Sendable () async -> Void)?

    public init(store: any SettingsStore, intelligence: (any IntelligenceServicing)?, clearAllChats: (@Sendable () async -> Void)?) {
        self.intelligence = intelligence
        clearAll = clearAllChats
        hasService = intelligence != nil
        summaryStyle = Pref(SettingsKey.intelligenceSummaryStyle, default: "auto", store: store)
        summaryLanguage = Pref(SettingsKey.intelligenceSummaryLanguage, default: "transcript", store: store)
        autoSummarize = Pref(SettingsKey.intelligenceAutoSummarize, default: false, store: store)
        includeNotes = Pref(SettingsKey.intelligenceIncludeNotes, default: true, store: store)
        includeFiles = Pref(SettingsKey.intelligenceIncludeFiles, default: true, store: store)
        keepChat = Pref(SettingsKey.intelligenceKeepChat, default: true, store: store)
    }

    public func load() async {
        if let intelligence { availability = await intelligence.availability() }
        await summaryStyle.load()
        await summaryLanguage.load()
        await autoSummarize.load()
        await includeNotes.load()
        await includeFiles.load()
        await keepChat.load()
    }

    public func clearChats() async {
        await clearAll?()
        chatsCleared = true
    }

    /// One line for the status row.
    public var statusTitle: String {
        guard hasService else { return "Apple Intelligence is not available in this build" }
        switch availability {
        case .available: return "Apple Intelligence is available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac does not support Apple Intelligence"
            case .notEnabled: return "Apple Intelligence is turned off"
            case .modelNotReady: return "Apple Intelligence is getting ready"
            case .osTooOld: return "Apple Intelligence needs a newer macOS"
            case .other: return "Apple Intelligence is not available right now"
            }
        }
    }

    public var statusDetail: String {
        if availability.isAvailable && hasService { return "Summaries and chat run on this Mac. Nothing is sent anywhere." }
        if case .unavailable(let reason) = availability { return IntelligenceCopy.explain(reason) }
        return "Notes, folders and slides work without it."
    }

    public var canOpenSystemSettings: Bool {
        if case .unavailable(.notEnabled) = availability { return true }
        if case .unavailable(.modelNotReady) = availability { return true }
        return false
    }
}

struct IntelligenceSettingsView: View {
    let model: IntelligenceSettingsModel
    @Environment(\.openURL) private var openURL
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    Circle().fill(model.availability.isAvailable && model.hasService ? DSColor.success : DSColor.warning)
                        .frame(width: 9, height: 9).padding(.top, 5).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Text(model.statusTitle).font(DSTypography.body.weight(.medium))
                        Text(model.statusDetail).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    Spacer()
                    if model.canOpenSystemSettings {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { openURL(url) }
                        }
                        .accessibilityIdentifier("settings.intelligence.openSystemSettings")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.intelligence.status")
            }
            Section {
                Picker("Summary style", selection: model.summaryStyle.binding) {
                    Text("Match the recording").tag("auto")
                    Text("Meeting").tag("meeting")
                    Text("Lecture").tag("lecture")
                    Text("General").tag("general")
                }
                .accessibilityIdentifier("settings.intelligence.style")
                Picker("Write summaries in", selection: model.summaryLanguage.binding) {
                    Text("The language of the recording").tag("transcript")
                    Text("My Mac's language").tag("app")
                }
                .accessibilityIdentifier("settings.intelligence.language")
                Toggle("Summarise automatically when a meeting finishes", isOn: model.autoSummarize.binding)
                    .accessibilityIdentifier("settings.intelligence.auto")
            } header: {
                Text("Summaries")
            } footer: {
                Text("Apple's on-device model supports about 15 languages. Long recordings take a few minutes and run in the background.")
            }
            Section {
                Toggle("Include my notes", isOn: model.includeNotes.binding).accessibilityIdentifier("settings.intelligence.notes")
                Toggle("Include attached files", isOn: model.includeFiles.binding).accessibilityIdentifier("settings.intelligence.files")
            } header: {
                Text("What summaries and chat read")
            } footer: {
                Text("These are the starting choices. Each summary and each chat can change them.")
            }
            Section {
                Toggle("Keep chat history", isOn: model.keepChat.binding).accessibilityIdentifier("settings.intelligence.keepChat")
                Button("Clear all chats…", role: .destructive) { confirmClear = true }.accessibilityIdentifier("settings.intelligence.clearChats")
                if model.chatsCleared { Text("All chats were cleared.").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
            } header: {
                Text("Chat")
            } footer: {
                Text("Conversations are saved with each transcript and stay on this Mac.")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .confirmationDialog("Clear every chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All Chats", role: .destructive) { Task { await model.clearChats() } }
        } message: {
            Text("Transcripts, notes and summaries are not affected.")
        }
    }
}
