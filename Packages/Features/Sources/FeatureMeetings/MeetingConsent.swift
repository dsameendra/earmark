import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// The one-time recording consent notice (MTG-AC-11). State lives in `SettingsKey.meetingConsentNotice` (true means
/// "still to be shown"), the same flag Settings > Meetings toggles and onboarding step 5 reads, so the notice appears
/// once in total however the user first reaches it.
@MainActor @Observable
public final class MeetingConsentModel {
    /// `true` until the user acknowledges the notice (or turns the Settings toggle off).
    public private(set) var isPending = true
    public private(set) var isLoaded = false

    @ObservationIgnored private let store: any SettingsStore

    public init(store: any SettingsStore) { self.store = store }

    public func load() async {
        isPending = await store.value(for: SettingsKey.meetingConsentNotice, as: Bool.self) ?? true
        isLoaded = true
    }

    /// Records that the user has been told; the notice never shows again.
    public func acknowledge() async {
        isPending = false
        isLoaded = true
        await store.set(false, for: SettingsKey.meetingConsentNotice)
    }

    public static let headline = "Recording consent"
    public static let message = "You are responsible for telling participants before you record. Laws differ by place; many require everyone's consent."
    public static let acknowledgeTitle = "Got it"
}

/// Inline consent notice on a solid surface (never a glass card, rule A2). Reused by onboarding (T27).
public struct RecordingConsentNotice: View {
    private let onAcknowledge: () -> Void
    private let onCancel: (() -> Void)?

    public init(onAcknowledge: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        self.onAcknowledge = onAcknowledge
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(MeetingConsentModel.headline).font(DSTypography.headline)
            Text(MeetingConsentModel.message).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
            HStack {
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("meetings.consent.cancel")
                }
                Button(MeetingConsentModel.acknowledgeTitle, action: onAcknowledge)
                    .buttonStyle(.borderedProminent).tint(DSColor.accent)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("meetings.consent.acknowledge")
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MeetingConsentModel.headline)
        .accessibilityIdentifier("meetings.consent")
    }
}
