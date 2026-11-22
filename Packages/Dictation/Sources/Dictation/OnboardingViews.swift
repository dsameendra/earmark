import AppCore
import DesignSystem
import SwiftUI

/// Copy and symbols for the Accessibility onboarding sheet (DICT-AC-06), kept in a model per rules A3/A7.
public struct AccessibilityOnboardingContent: Sendable, Equatable {
    public var title = "Allow Accessibility to dictate anywhere"
    public var message =
        "Earmark types your dictated text into the app you're using. macOS requires Accessibility access for that. Earmark never types anything until you allow it, and everything stays on your Mac."
    public var systemImage = "hand.raised.fill"
    public var openSettingsTitle = "Open System Settings"
    public var notNowTitle = "Not Now"
    public var grantedMessage = "Accessibility is on. Dictation is ready."
    public init() {}
}

/// Sheet shown on first use when Accessibility is not granted. The grant is detected live by
/// ``DictationController`` (no restart); the host dismisses the sheet through ``DictationOnboardingPresenting``.
public struct AccessibilityOnboardingView: View {
    private let content = AccessibilityOnboardingContent()
    private let isGranted: Bool
    private let openSettings: () -> Void
    private let dismiss: () -> Void

    public init(isGranted: Bool = false, openSettings: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.isGranted = isGranted
        self.openSettings = openSettings
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: DSSpacing.lg) {
            Image(systemName: content.systemImage)
                .font(.largeTitle)
                .foregroundStyle(DSColor.accent)
                .accessibilityHidden(true)
            Text(content.title).font(DSTypography.title).multilineTextAlignment(.center)
            Text(isGranted ? content.grantedMessage : content.message)
                .font(DSTypography.body)
                .foregroundStyle(DSColor.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: DSSpacing.md) {
                Button(content.notNowTitle, action: dismiss)
                    .accessibilityIdentifier("dictation.onboarding.notNow")
                Button(content.openSettingsTitle, action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isGranted)
                    .accessibilityIdentifier("dictation.onboarding.openSettings")
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: 420)
        .accessibilityIdentifier("dictation.onboarding")
    }
}

/// Searchable dictation history list (DICT-AC-11). Entries copy on click; "Clear" removes everything.
public struct DictationHistoryView: View {
    @Bindable private var model: DictationHistoryModel
    private let copy: (String) -> Void

    public init(model: DictationHistoryModel, copy: @escaping (String) -> Void) {
        self.model = model
        self.copy = copy
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search dictation history", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("dictation.history.search")
                    .onSubmit { Task { await model.reload() } }
                Button("Clear", role: .destructive) { Task { await model.clear() } }
                    .accessibilityIdentifier("dictation.history.clear")
            }
            .padding(DSSpacing.md)
            if model.entries.isEmpty {
                EmptyState(systemImage: model.emptySystemImage, title: "No dictation yet", message: "Text you dictate shows up here.")
            } else {
                List(model.entries) { entry in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(entry.text).font(DSTypography.body).lineLimit(3)
                        Text(entry.createdAt, style: .relative).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copy(entry.text) }
                    .accessibilityIdentifier("dictation.history.row")
                }
                .accessibilityIdentifier("dictation.history.list")
            }
        }
        .task { await model.reload() }
        .onChange(of: model.query) { Task { await model.reload() } }
    }
}
