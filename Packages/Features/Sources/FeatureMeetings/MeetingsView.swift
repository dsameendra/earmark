import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Meetings list with a detection banner (Transcribe / Record / Dismiss). Capture itself arrives with T23/T24.
public struct MeetingsView: View {
    private let model: MeetingsModel

    public init(model: MeetingsModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            if let app = model.detectedApp { banner(for: app) }
            content
        }
        .navigationTitle("Meetings")
        .task { await model.load() }
        .task { await model.watchDetector() }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                ForEach(0..<4, id: \.self) { _ in Skeleton(height: 26) }
                Spacer()
            }
            .padding(DSSpacing.xl)
        } else if let message = model.errorMessage {
            ErrorState(message: message) { Task { await model.load() } }
        } else if model.meetings.isEmpty {
            EmptyState(
                systemImage: "person.2.wave.2", title: "No meetings yet",
                message: "Zoom and Microsoft Teams meetings that Earmark transcribes or records appear here. You choose what happens.")
        } else {
            List(model.meetings) { meeting in
                HStack {
                    Image(systemName: meeting.recording == nil ? "text.bubble" : "record.circle").accessibilityHidden(true)
                    Text(meeting.app == .zoom ? "Zoom" : "Teams")
                    Spacer()
                    Text(meeting.startedAt, style: .date).foregroundStyle(DSColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func banner(for app: MeetingApp) -> some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: "person.2.wave.2").accessibilityHidden(true)
            Text("\(app == .zoom ? "Zoom" : "Teams") meeting detected").font(DSTypography.headline)
            Spacer()
            Button("Transcribe") {}.disabled(true)
            Button("Record") {}.disabled(true)
            Button("Dismiss") { model.dismissDetection() }
        }
        .padding(DSSpacing.md)
        .glassBackground(radius: DSRadius.medium)
        .padding(DSSpacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected")
    }
}

#Preview("Meetings - empty") { MeetingsView(model: MeetingsModel(services: .preview())).frame(width: 640, height: 400) }

#Preview("Meetings - list") {
    MeetingsView(model: MeetingsModel(services: .preview(meetings: [Meeting(app: .zoom, startedAt: Date())]))).frame(
        width: 640, height: 400)
}
