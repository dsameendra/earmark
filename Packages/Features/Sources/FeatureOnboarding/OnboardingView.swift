import AppCore
import AppKit
import DesignSystem
import FeatureSettings
import SwiftUI

/// First-run flow: an accent brand panel on the left, solid content on the right (no glass on content, rule A2).
/// Layout only; behaviour lives in `OnboardingModel`.
public struct OnboardingView: View {
    private let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(model: OnboardingModel) { self.model = model }

    public static let size = CGSize(width: 900, height: 620)

    public var body: some View {
        HStack(spacing: 0) {
            brandPanel
            VStack(spacing: 0) {
                content
                Divider()
                navigationBar
            }
            .background(DSColor.contentBackground)
        }
        .frame(width: Self.size.width)
        .frame(minHeight: Self.size.height, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .dsAnimation(.settle, value: model.step)
        .task { await model.load() }
        .task { await model.permissions.observe() }
    }

    // MARK: Brand panel

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            Text("earmark").font(DSTypography.title1)
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 184, height: 184)
                .shadow(color: DSColor.shadow.opacity(0.18), radius: 20, y: 10)
                .dsEntrance()
                .accessibilityHidden(true)
            Spacer()
            Text("Listen once.\nKeep what matters.").font(DSTypography.transcript).italic()
        }
        .foregroundStyle(DSColor.contentBackground)
        .padding(DSSpacing.xl)
        .padding(.top, DSSpacing.lg)
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(LinearGradient(colors: [DSColor.accent, DSColor.accentText], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .bottomLeading) {
            Circle().stroke(DSColor.contentBackground.opacity(0.14), lineWidth: 1)
                .frame(width: 440, height: 440).offset(x: -100, y: 210).allowsHitTesting(false)
        }
        .clipped()
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    ForEach(0..<5) { index in
                        Capsule().fill(index <= model.step.rawValue ? DSColor.accent : DSColor.hairline)
                            .frame(width: index == model.step.rawValue ? 28 : 10, height: 3)
                    }
                }
                .accessibilityHidden(true)
                Text(model.step.progressText).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("onboarding.progress")
                Text(model.step.title).font(DSTypography.title1).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("onboarding.title")
                Text(model.step.subtitle).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
            ScrollView {
                stepBody.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(model.step)
        .dsTransition(.settle)
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome: HighlightList(items: OnboardingHighlight.welcome)
        case .languages: LanguageStep(model: model.languages)
        case .permissions: permissionsStep
        case .tour: HighlightList(items: model.tourHighlights)
        case .ready: readyStep
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            ForEach(OnboardingPermissionsModel.kinds, id: \.self) { kind in
                PermissionRow(
                    state: model.permissions.rowState(for: kind),
                    onRequest: { Task { await model.permissions.request(kind) } },
                    onOpenSettings: { openURL(model.permissions.settingsURL(for: kind)) }
                )
                .padding(DSSpacing.md)
                .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
            }
            Text("Denying a permission never blocks Earmark. You can change any of these later in Settings.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            consentNotice
            HighlightList(items: OnboardingHighlight.ready)
        }
    }

    /// The one-time recording-consent notice (ONB-AC-08).
    private var consentNotice: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: RecordingConsentCopy.systemImage).foregroundStyle(DSColor.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(RecordingConsentCopy.title).font(DSTypography.headline)
                Text(RecordingConsentCopy.message).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
            }
            Spacer(minLength: DSSpacing.md)
            if model.consentAcknowledged {
                StatusPill(LocalizedStringKey(RecordingConsentCopy.acknowledged), systemImage: "checkmark.circle.fill", tone: .success)
                    .accessibilityIdentifier("onboarding.consent.acknowledged")
            } else {
                Button(RecordingConsentCopy.acknowledge) { Task { await model.acknowledgeConsent() } }
                    .accessibilityIdentifier("onboarding.consent.acknowledge")
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.consent")
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack {
            if model.canGoBack {
                Button("Back", systemImage: "chevron.left") { Task { await model.back() } }
                    .buttonStyle(.plain).foregroundStyle(DSColor.secondaryText).dsMinControlHeight()
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("onboarding.back")
            }
            Button("Skip") { Task { await model.skip() } }
                .buttonStyle(.plain)
                .foregroundStyle(DSColor.secondaryText)
                .dsMinControlHeight()
                .accessibilityHint("Closes the welcome. You can reopen it from Settings or the Help menu.")
                .accessibilityIdentifier("onboarding.skip")
            Spacer()
            Button(model.primaryTitle) { Task { await model.next() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(EmberButtonStyle())
                .accessibilityIdentifier(model.step.isLast ? "onboarding.finish" : "onboarding.continue")
        }
        .padding(.horizontal, DSSpacing.xl).padding(.vertical, DSSpacing.lg)
        .background(DSColor.contentBackground)
    }
}

// MARK: - Highlights

private struct HighlightList: View {
    let items: [OnboardingHighlight]
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    DSIcon(item.symbol, orStock: item.systemImage).dsSymbolStyle(.monochrome).frame(width: 24).foregroundStyle(
                        DSColor.accent)
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Text(item.title).font(DSTypography.headline)
                        Text(item.detail).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpacing.md)
                .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding.highlight.\(item.id)")
            }
        }
    }
}

// MARK: - Languages and model

private struct LanguageStep: View {
    let model: OnboardingLanguageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.options) { languageRow($0) }
                if model.showsMoreLanguages { ForEach(model.moreOptions) { languageRow($0) } }
                if !model.moreOptions.isEmpty {
                    Button(model.showsMoreLanguages ? "Fewer languages" : "More languages…") { model.showsMoreLanguages.toggle() }
                        .buttonStyle(.link)
                        .padding(.vertical, DSSpacing.sm)
                        .accessibilityIdentifier("onboarding.language.more")
                }
            }
            recommendation
                .padding(DSSpacing.lg)
                .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
            Text("Your audio stays on this Mac. Downloads start only when you choose.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
    }

    private func languageRow(_ option: OnboardingLanguageModel.LanguageOption) -> some View {
        HStack {
            Toggle(
                option.label,
                isOn: Binding(get: { model.isSelected(option.code) }, set: { _ in Task { await model.toggle(option.code) } })
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier("onboarding.language.\(option.code.rawValue)")
            if option.isDefault { StatusPill("Default", tone: .neutral) }
            if option.isExperimental { StatusPill("Experimental", systemImage: "flask", tone: .warning) }
        }
        .padding(.vertical, DSSpacing.xs)
    }

    @ViewBuilder private var recommendation: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Recommended for your Mac").font(DSTypography.headline)
            if model.recommendations.isEmpty {
                Text(
                    model.isLoading ? "Checking models…" : "No model is listed for these languages yet. You can add one later in Settings."
                )
                .font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
            }
            ForEach(model.recommendations) { item in
                RecommendationRow(model: model, item: item)
            }
            ForEach(model.warnings, id: \.self) { Text($0).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
            if let notice = model.offlineNotice {
                Label(notice, systemImage: "wifi.slash").font(DSTypography.caption).foregroundStyle(DSColor.warning)
                    .accessibilityIdentifier("onboarding.offline")
            }
            if let warning = model.diskWarning { diskWarning(warning) }
            if let error = model.errorMessage {
                Text(error).font(DSTypography.caption).foregroundStyle(DSColor.danger).accessibilityIdentifier("onboarding.download.error")
            }
            downloadControls
        }
    }

    private func diskWarning(_ warning: OnboardingLanguageModel.DiskWarning) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Label(warning.message, systemImage: "externaldrive.badge.exclamationmark").font(DSTypography.caption)
                .foregroundStyle(DSColor.warning)
            HStack {
                Button("Download anyway") { Task { await model.startDownload(confirmLowDisk: true) } }
                    .accessibilityIdentifier("onboarding.download.anyway")
                Button("Not now") { model.dismissDiskWarning() }.accessibilityIdentifier("onboarding.download.dismissDisk")
            }
        }
        .accessibilityIdentifier("onboarding.diskWarning")
    }

    @ViewBuilder private var downloadControls: some View {
        HStack {
            if model.isDownloading {
                if model.isPaused {
                    Button("Resume") { Task { await model.resume() } }.accessibilityIdentifier("onboarding.download.resume")
                } else {
                    Button("Pause") { Task { await model.pause() } }.accessibilityIdentifier("onboarding.download.pause")
                }
                Button("Cancel") { Task { await model.cancel() } }.accessibilityIdentifier("onboarding.download.cancel")
            } else if model.hasPendingDownload {
                Button("Download \(model.totalSizeText)") { Task { await model.startDownload() } }
                    .disabled(model.isOffline)
                    .accessibilityIdentifier("onboarding.download.start")
                Text("or continue and download later in Settings").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
        }
    }
}

private struct RecommendationRow: View {
    let model: OnboardingLanguageModel
    let item: OnboardingLanguageModel.Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text("\(item.name) · \(item.sizeText)").font(DSTypography.body)
                if item.isExperimental { StatusPill("Experimental", tone: .warning) }
                Spacer()
                if item.isInstalled { StatusPill("Installed", systemImage: "checkmark.circle.fill", tone: .success) }
            }
            Text(languagesText).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            if let progress = model.progress(for: item.id), !item.isInstalled { progressView(progress) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.model.\(item.id.rawValue)")
    }

    private var languagesText: String {
        "For " + item.languages.map(OnboardingLanguageModel.name).joined(separator: ", ")
    }

    @ViewBuilder private func progressView(_ progress: OnboardingLanguageModel.DownloadProgress) -> some View {
        switch progress.phase {
        case .queued: Text("Waiting to download").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case .downloading: ProgressRow(title: "Downloading", detail: bytes(progress), fraction: progress.fraction)
        case .paused: ProgressRow(title: "Paused", detail: bytes(progress), fraction: progress.fraction)
        case .verifying: ProgressRow(title: "Verifying", fraction: nil)
        case .completed: EmptyView()
        case .cancelled: Text("Download cancelled").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case .failed: EmptyView()
        }
    }

    private func bytes(_ progress: OnboardingLanguageModel.DownloadProgress) -> String? {
        guard let total = progress.bytesTotal else { return nil }
        let done = ByteCountFormatter.string(fromByteCount: progress.bytesReceived, countStyle: .file)
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
