import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Symbol names for the Meetings screen, reached by the view through this seam (rule A3).
enum MeetingsSymbol {
    static let transcriptOnly = "text.bubble"
    static let recorded = DSSymbol.record
    static let stop = "stop.fill"
    static let openTranscript = DSSymbol.library
    static let policy = DSSymbol.settings
    static let detect = DSSymbol.retry
    static let error = "exclamationmark.triangle"
    static let emptyState = DSSymbol.meetings
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
            PermissionGateBanner(model: model.permissionGate, feature: "Meeting capture", identifier: "meetings.permissions")
                .padding(.bottom, model.permissionGate.isBlocked ? DSSpacing.md : 0)
            inline
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DSSpacing.lg)
        .dsSolidSurface(.sheet, radius: DSRadius.panel)
        .dsPanelInset()
        .background(DSColor.paper)
        .navigationTitle("Meetings")
        .toolbar { policyToolbar }
        .task { await model.load() }
    }

    // MARK: Inline surfaces (solid, never glass)

    @ViewBuilder private var inline: some View {
        let banners = model.bannerDetections
        let current = model.currentMeeting
        let hasInline =
            !banners.isEmpty || current != nil || model.pendingRecording != nil || model.consentReminder != nil || model.actionError != nil
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
        VStack(spacing: 0) {
            AvailableNowSection(model: model)
            storedContent
        }
    }

    @ViewBuilder private var storedContent: some View {
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
                systemImage: MeetingsSymbol.emptyState.systemImageName, title: "No meetings yet",
                message: "Zoom, Microsoft Teams, Google Meet and Discord meetings that Earmark transcribes or records appear here. You choose what happens.")
        } else {
            List(model.rows) { row in
                MeetingRow(row: row) { if let id = row.meeting.transcriptID { onOpenTranscript(id) } }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("meetings.list")
        }
    }

    @ToolbarContentBuilder private var policyToolbar: some ToolbarContent {
        // Each control is its own View so it observes the model itself: reading it inside the toolbar builder's closures is
        // not tracked. Written out (not ForEach): Swift 6.3 (Xcode 26.x) cannot resolve a ForEach of ToolbarItems here.
        ToolbarItem { DetectMeetingsButton(model: model) }
        ToolbarItem { MeetingPolicyMenu(model: model) }
    }
}

/// "Detect meetings": looks again right now and lists every live call that can be transcribed. For a missed notification,
/// a muted join, or a call Earmark does not start on its own (Meet in a tab, a Discord channel).
struct DetectMeetingsButton: View {
    let model: MeetingsModel

    var body: some View {
        Button {
            Task { await model.detect() }
        } label: {
            DSToolbarLabel(model.isDetecting ? "Detecting…" : "Detect meetings", symbol: MeetingsSymbol.detect)
        }
        .labelStyle(.titleAndIcon)
        .dsToolbarControl()
        .disabled(model.isDetecting)
        .accessibilityIdentifier("meetings.detect")
        .help("Look for meetings that are running now (Zoom, Teams, Meet, Discord, other browser calls)")
    }
}

/// One "Detection" menu for what Earmark does when a meeting starts, per app. Flat sections (no submenus) with a checkmark on
/// the current choice. Four apps do not fit as four toolbar menus.
struct MeetingPolicyMenu: View {
    let model: MeetingsModel

    var body: some View {
        let summary = MeetingApp.allCases.map { "\($0.badgeTitle) \(model.policy(for: $0).behavior.title)" }.joined(separator: ", ")
        Menu {
            ForEach(MeetingApp.allCases, id: \.self) { app in
                let current = model.policy(for: app).behavior
                Section(app.title) {
                    ForEach(MeetingBehavior.allCases, id: \.self) { behavior in
                        Button {
                            Task { await model.setBehavior(behavior, for: app) }
                        } label: {
                            if current == behavior {
                                Label(behavior.title, systemImage: "checkmark")
                            } else {
                                Text(behavior.title)
                            }
                        }
                        .accessibilityIdentifier("meetings.policy.\(app.rawValue).\(behavior.rawValue)")
                    }
                }
            }
        } label: {
            DSToolbarLabel("Detection", symbol: MeetingsSymbol.policy)
        }
        .labelStyle(.titleAndIcon)
        .dsToolbarControl()
        .accessibilityIdentifier("meetings.policy")
        .accessibilityValue(summary)
        .help("What Earmark does when a Zoom, Teams, Meet or Discord meeting starts")
    }
}

// MARK: - Banner

struct DetectionBanner: View {
    let model: MeetingsModel
    let detection: DetectedMeeting

    var body: some View {
        let app = detection.app
        HStack(spacing: DSSpacing.md) {
            DSIcon(app.symbol)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text("\(app.occurrenceName) detected").font(DSTypography.headline)
                Text("Started \(detection.startedAt, style: .relative) ago · nothing is recorded until you choose")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            Button("Dismiss") { Task { await model.dismissDetection(app) } }
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).dismiss")
            Button("Transcribe") { Task { await model.startCapture(app, mode: .transcribeOnly) } }
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).transcribe")
            Button("Transcribe and record") { Task { await model.startCapture(app, mode: .transcribeAndRecord) } }
                .dsProminentButton().tint(DSColor.recording)
                .accessibilityIdentifier("meetings.banner.\(app.rawValue).record")
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.occurrenceName) detected")
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
                Button("Open last transcript", symbol: MeetingsSymbol.openTranscript) { onOpenTranscript(id) }
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
            DSIcon(current.app.symbol)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(current.app.occurrenceName).font(DSTypography.headline)
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
                .dsProminentButton().tint(DSColor.recording)
                .accessibilityIdentifier("meetings.current.record")
        case .capturing:
            Button("Notes and chat", systemImage: "note.text") {  // stock-chrome: workspace glyph
                Task { if let id = await model.liveTranscriptID() { onOpenTranscript(id) } }
            }
            .help("Write notes, add slides or ask about what was said so far, while the meeting runs")
            .accessibilityIdentifier("meetings.current.workspace")
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
    private var canOpen: Bool { row.meeting.transcriptID != nil }

    var body: some View {
        if canOpen {
            Button(action: onOpen) { content }
                .buttonStyle(.dsHover(shape: .rounded(DSRadius.small)))
                .help("Open transcript")
                .accessibilityIdentifier("meetings.row.\(row.id).open")
                .listRowSeparator(.hidden)
                .listRowBackground(DSColor.contentBackground)
        } else {
            content
                .listRowSeparator(.hidden)
                .listRowBackground(DSColor.contentBackground)
                .accessibilityIdentifier("meetings.row.\(row.id)")
        }
    }

    private var content: some View {
        HStack(spacing: DSSpacing.md) {
            DSIcon(row.isRecorded ? MeetingsSymbol.recorded : nil, orStock: MeetingsSymbol.transcriptOnly).dsSymbolStyle(.monochrome)
                .foregroundStyle(row.isRecorded ? DSColor.recording : DSColor.secondaryText)
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
            if canOpen {
                DSIcon(MeetingsSymbol.openTranscript).foregroundStyle(DSColor.tertiaryText).accessibilityHidden(true)
            }
        }
        .padding(.vertical, DSSpacing.md)
        .contentShape(Rectangle())
    }
}

#Preview("Meetings - empty") { MeetingsView(model: MeetingsModel(services: .preview())).frame(width: 760, height: 460) }

#Preview("Meetings - list") {
    MeetingsView(model: MeetingsModel(services: .preview(meetings: [Meeting(app: .zoom, startedAt: Date())]))).frame(
        width: 760, height: 460)
}


// MARK: - Available now

/// Live calls Earmark can see right now, each with its own Transcribe actions. Stays empty (no section) until there is
/// something to show or the user pressed Detect meetings.
struct AvailableNowSection: View {
    let model: MeetingsModel

    var body: some View {
        let items = model.availableNow
        if !items.isEmpty || (model.detectFoundNothing && model.available.isEmpty) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack {
                    Text("Available now").font(DSTypography.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.detectFoundNothing {
                        Button("Dismiss") { model.dismissDetectResult() }.accessibilityIdentifier("meetings.available.dismiss")
                    }
                }
                if items.isEmpty {
                    NothingFound(model: model)
                } else {
                    ForEach(items) { item in AvailableRow(model: model, item: item) }
                    if items.contains(where: { $0.app == .meet || $0.app == .browser }) {
                        Text("A browser call captures all audio from that browser, including other tabs. Your microphone is recorded separately.")
                            .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                            .accessibilityIdentifier("meetings.available.browserNote")
                    }
                    if model.needsAccessibilityForMeet { AccessibilityHint() }
                }
            }
            .padding(DSSpacing.lg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meetings.available")
        }
    }
}

struct AvailableRow: View {
    let model: MeetingsModel
    let item: LiveMeetingCandidate

    var body: some View {
        let busy = model.captureState.isActive
        HStack(spacing: DSSpacing.md) {
            DSIcon(item.app.symbol)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(item.label).font(DSTypography.body.weight(.medium))
                Text(item.detail).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            Button("Transcribe") { Task { await model.startCapture(item, mode: .transcribeOnly) } }
                .disabled(busy)
                .accessibilityIdentifier("meetings.available.\(item.id).transcribe")
            Button("Transcribe and record") { Task { await model.startCapture(item, mode: .transcribeAndRecord) } }
                .dsProminentButton().tint(DSColor.recording)
                .disabled(busy)
                .accessibilityIdentifier("meetings.available.\(item.id).record")
        }
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label), available to transcribe")
        .accessibilityIdentifier("meetings.available.\(item.id)")
    }
}

struct NothingFound: View {
    let model: MeetingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("No meeting found").font(DSTypography.body.weight(.medium))
            Text("Earmark looked at Zoom, Teams, Discord and your browsers. Join the call first, then try again.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            ForEach(model.scanNotes, id: \.self) { note in
                Text(note).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.hairline))
        .accessibilityIdentifier("meetings.available.nothing")
    }
}

/// Shown when a browser call is listed as a plain "Browser call" because window titles cannot be read.
struct AccessibilityHint: View {
    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("To recognise Google Meet calls, allow Earmark in Accessibility.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                Link("Open Accessibility settings", destination: url).font(DSTypography.caption)
                    .accessibilityIdentifier("meetings.available.accessibility")
            }
        }
    }
}
