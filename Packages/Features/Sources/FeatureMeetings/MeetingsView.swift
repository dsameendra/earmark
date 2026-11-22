import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Symbol names for the Meetings screen, reached by the view through this seam (rule A3).
enum MeetingsSymbol {
    static let transcriptOnly = "text.bubble"
    static let recorded = "record.circle"
    static let stop = "stop.fill"
    static let openTranscript = "doc.text"
    static let policy = "slider.horizontal.3"
    static let error = "exclamationmark.triangle"
    static let emptyState = "person.2.wave.2"
}

/// Meetings: inline detection banner, current-meeting card with live transcript, and the stored meetings list.
public struct MeetingsView: View {
    private let model: MeetingsModel
    private let onOpenTranscript: (TranscriptID) -> Void

    public init(model: MeetingsModel, onOpenTranscript: @escaping (TranscriptID) -> Void = { _ in }) {
        self.model = model
        self.onOpenTranscript = onOpenTranscript
    }

    public var body: some View {
        VStack(spacing: 0) {
            inline
            content
        }
        .background(DSColor.contentBackground)
        .navigationTitle("Meetings")
        .toolbar { policyToolbar }
        .task { await model.load() }
    }

    // MARK: Inline surfaces (solid, never glass)

    @ViewBuilder private var inline: some View {
        let banners = model.bannerDetections
        let current = model.currentMeeting
        let hasInline = !banners.isEmpty || current != nil || model.pendingRecording != nil || model.consentReminder != nil || model.actionError != nil
        if hasInline {
            VStack(spacing: DSSpacing.md) {
                ForEach(banners) { DetectionBanner(model: model, detection: $0) }
                if let pending = model.pendingRecording {
                    RecordingConsentNotice(
                        onAcknowledge: { Task { await model.confirmConsent() } }, onCancel: { model.cancelConsent() }
                    )
                    .accessibilityHint("Acknowledge to start recording \(pending.app.title)")
                }
                if model.consentReminder != nil {
                    ConsentReminder { model.dismissConsentReminder() }
                }
                if let current { CurrentMeetingCard(model: model, current: current, onOpenTranscript: onOpenTranscript) }
                if let message = model.actionError { ErrorBanner(message: message) { model.dismissError() } }
            }
            .padding(DSSpacing.lg)
        }
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        if model.isLoading {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                ForEach(0..<4, id: \.self) { _ in Skeleton(height: 26) }
                Spacer()
            }
            .padding(DSSpacing.xl)
        } else if let message = model.errorMessage {
            ErrorState(message: message) { Task { await model.load() } }
        } else if model.rows.isEmpty {
            EmptyState(
                systemImage: MeetingsSymbol.emptyState, title: "No meetings yet",
                message: "Zoom and Microsoft Teams meetings that Earmark transcribes or records appear here. You choose what happens.")
        } else {
            List(model.rows) { row in
                MeetingRow(row: row) { if let id = row.meeting.transcriptID { onOpenTranscript(id) } }
            }
            .accessibilityIdentifier("meetings.list")
        }
    }

    @ToolbarContentBuilder private var policyToolbar: some ToolbarContent {
        ToolbarItemGroup {
            ForEach(MeetingApp.allCases, id: \.self) { app in
                Menu {
                    ForEach(MeetingBehavior.allCases, id: \.self) { behavior in
                        Button {
                            Task { await model.setBehavior(behavior, for: app) }
                        } label: {
                            if model.policy(for: app).behavior == behavior {
                                Label(behavior.title, systemImage: "checkmark")
                            } else {
                                Text(behavior.title)
                            }
                        }
                        .accessibilityIdentifier("meetings.policy.\(app.rawValue).\(behavior.rawValue)")
                    }
                } label: {
                    Label("\(app.badgeTitle) · \(model.policy(for: app).behavior.title)", systemImage: MeetingsSymbol.policy)
                }
                .accessibilityIdentifier("meetings.policy.\(app.rawValue)")
                .help("What Earmark does when a \(app.title) meeting starts")
            }
        }
    }
}

// MARK: - Banner

struct DetectionBanner: View {
    let model: MeetingsModel
    let detection: DetectedMeeting

    var body: some View {
        let app = detection.app
        HStack(spacing: DSSpacing.md) {
            Image(systemName: app.systemImage).foregroundStyle(DSColor.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text("\(app.badgeTitle) meeting detected").font(DSTypography.headline)
                Text("Started \(detection.startedAt, style: .relative) ago · nothing is recorded until you choose")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            Button("Dismiss") { Task { await model.dismissDetection(app) } }
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).dismiss")
            Button("Transcribe") { Task { await model.startCapture(app, mode: .transcribeOnly) } }
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).transcribe")
            Button("Transcribe and record") { Task { await model.startCapture(app, mode: .transcribeAndRecord) } }
                .buttonStyle(.borderedProminent).tint(DSColor.recording)
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).record")
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.badgeTitle) meeting detected")
        .accessibilityIdentifier("meetings.banner.\(app.rawValue)")
    }
}

struct ConsentReminder: View {
    let onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(MeetingConsentModel.headline).font(DSTypography.headline)
                Text(MeetingConsentModel.message).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            Button(MeetingConsentModel.acknowledgeTitle, action: onDismiss).accessibilityIdentifier("meetings.consentReminder.dismiss")
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetings.consentReminder")
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: MeetingsSymbol.error).foregroundStyle(DSColor.danger).accessibilityHidden(true)
            Text(message).font(DSTypography.body)
            Spacer()
            Button("Dismiss", action: onDismiss).accessibilityIdentifier("meetings.error.dismiss")
        }
        .padding(DSSpacing.md)
        .background(DSColor.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetings.error")
    }
}

// MARK: - Current meeting

struct CurrentMeetingCard: View {
    let model: MeetingsModel
    let current: CurrentMeeting
    let onOpenTranscript: (TranscriptID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            if case .capturing = current.phase { LiveTranscriptView(lines: model.lines) }
            if let id = model.finishedTranscriptID, current.phase == .detected {
                Button("Open last transcript", systemImage: MeetingsSymbol.openTranscript) { onOpenTranscript(id) }
                    .accessibilityIdentifier("meetings.current.openTranscript")
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current meeting")
        .accessibilityIdentifier("meetings.current")
    }

    private var header: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: current.app.systemImage).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text("\(current.app.title) meeting").font(DSTypography.headline)
                status
            }
            Spacer()
            controls
        }
    }

    @ViewBuilder private var status: some View {
        switch current.phase {
        case .detected: Text("Detected, not capturing").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case .starting: Text("Starting…").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case .stopping: Text("Finishing…").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case .failed(let message): Text(message).font(DSTypography.caption).foregroundStyle(DSColor.danger)
        case .capturing(let mode, let since):
            HStack(spacing: DSSpacing.sm) {
                if mode.recordsAudio { RecordingIndicator(label: "Recording") } else { Text("Transcribing").font(DSTypography.badge) }
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))), format: .time(pattern: .hourMinuteSecond))
                        .font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch current.phase {
        case .detected:
            Button("Transcribe") { Task { await model.startCapture(current.app, mode: .transcribeOnly) } }
                .accessibilityIdentifier("meetings.current.transcribe")
            Button("Record") { Task { await model.startCapture(current.app, mode: .transcribeAndRecord) } }
                .buttonStyle(.borderedProminent).tint(DSColor.recording)
                .accessibilityIdentifier("meetings.current.record")
        case .capturing:
            Button("Stop", systemImage: MeetingsSymbol.stop) { Task { await model.stopCapture() } }
                .accessibilityIdentifier("meetings.current.stop")
        case .failed:
            Button("Dismiss") { model.dismissError() }.accessibilityIdentifier("meetings.current.dismissFailure")
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Live transcript

struct LiveTranscriptView: View {
    let lines: [CaptionLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.sm) {
                    if lines.isEmpty {
                        Text("Listening for speech…").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    ForEach(lines) { line in
                        LiveLineRow(line: line).id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 220)
            .onChange(of: lines.last?.id) { if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .accessibilityIdentifier("meetings.liveTranscript")
    }
}

struct LiveLineRow: View {
    let line: CaptionLine

    var body: some View {
        let speaker = LiveSpeakerDisplay(line: line)
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            if speaker.isVisible {
                SpeakerChip(name: speaker.name, slot: speaker.slot)
                    .opacity(speaker.isProvisional ? 0.8 : 1)
                    .help(speaker.isProvisional ? "Provisional label. It may change when the meeting is finalized." : "")
                    .accessibilityValue(speaker.isProvisional ? "provisional" : "")
            }
            Text(line.text).font(DSTypography.body).foregroundStyle(line.isVolatile ? DSColor.secondaryText : DSColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

struct MeetingRow: View {
    let row: MeetingRowInfo
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: row.isRecorded ? MeetingsSymbol.recorded : MeetingsSymbol.transcriptOnly)
                .foregroundStyle(row.isRecorded ? DSColor.recording : DSColor.secondaryText).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(row.title).font(DSTypography.body.weight(.medium)).lineLimit(1)
                HStack(spacing: DSSpacing.xs) {
                    Text(row.meeting.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                    if let count = row.speakerCount, count > 0 { Text("· \(count) speakers") }
                    Text("· \(row.capturesDescription)")
                }
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            if let duration = row.duration, duration > 0 {
                Text(Duration.seconds(duration), format: .time(pattern: .hourMinuteSecond))
                    .font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            }
            StatusPill(LocalizedStringKey(row.meeting.app.badgeTitle))
            if row.meeting.transcriptID != nil {
                Button("Open", systemImage: MeetingsSymbol.openTranscript, action: onOpen).labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Open transcript")
                    .accessibilityIdentifier("meetings.row.\(row.id).open")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetings.row.\(row.id)")
    }
}

#Preview("Meetings - empty") { MeetingsView(model: MeetingsModel(services: .preview())).frame(width: 760, height: 460) }

#Preview("Meetings - list") {
    MeetingsView(model: MeetingsModel(services: .preview(meetings: [Meeting(app: .zoom, startedAt: Date())]))).frame(
        width: 760, height: 460)
}
