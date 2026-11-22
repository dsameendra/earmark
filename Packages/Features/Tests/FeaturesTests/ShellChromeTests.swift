import AppCore
import DesignSystem
import FeatureLibrary
import FeatureSupport
import Foundation
import SwiftUI
import Testing

@testable import FeatureShell

/// T34 shell chrome: section shortcuts, responsive thresholds, sidebar state, glass budget, accessibility rules.
@Suite("Shell chrome") @MainActor struct ShellChromeTests {
    // MARK: Section shortcuts (NAV-AC-02)

    @Test func commandDigitsSelectSectionsInOrder() {
        let expected: [AppSection] = [.home, .queue, .meetings, .live, .library, .recentlyDeleted]
        for (index, section) in expected.enumerated() { #expect(AppSection(shortcutDigit: index + 1) == section) }
        #expect(AppSection(shortcutDigit: 0) == nil && AppSection(shortcutDigit: 7) == nil && AppSection(shortcutDigit: -1) == nil)
    }

    @Test func shortcutKeysAreOneThroughSixAndUnique() {
        #expect(AppSection.allCases.map(\.shortcutKey) == ["1", "2", "3", "4", "5", "6"])
        #expect(Set(AppSection.allCases.map(\.accessibilityIdentifier)).count == 6)
    }

    @Test func selectingBySectionPersistsAndClosesEditor() {
        let model = ShellModel(services: .preview())
        model.openedTranscript = TranscriptID()
        for digit in 1...6 {
            model.select(AppSection(shortcutDigit: digit)!)
            #expect(model.selection.shortcutNumber == digit)
            #expect(model.openedTranscript == nil)
        }
    }

    // MARK: Responsive thresholds (handoff section 5, NAV-AC-12)

    @Test func layoutThresholdsAt799_800_1099_1100() {
        #expect(ShellLayout(width: 799).widthClass == .compact && ShellLayout(width: 799).sidebarCollapsed)
        #expect(ShellLayout(width: 800).widthClass == .narrow && !ShellLayout(width: 800).sidebarCollapsed)
        #expect(ShellLayout(width: 1099).inspectorCollapsed)
        #expect(!ShellLayout(width: 1100).inspectorCollapsed && ShellLayout(width: 1100).widthClass == .regular)
        #expect(ShellLayout(width: 960).inspectorCollapsed && !ShellLayout(width: 960).sidebarCollapsed)  // the minimum window
    }

    @Test func homeColumnsAndLibraryColumnsFollowWidthClass() {
        #expect(ShellLayout(width: 700).homeActionColumns == 1)
        #expect(ShellLayout(width: 960).homeActionColumns == 2)
        #expect(ShellLayout(width: 1440).homeActionColumns == 4)
        #expect(ShellLayout(width: 700).droppedLibraryColumns == ["Language", "Speakers"])
        #expect(ShellLayout(width: 960).droppedLibraryColumns == ["Language"])
        #expect(ShellLayout(width: 1440).droppedLibraryColumns.isEmpty)
    }

    @Test func workspaceUsesAvailableWidthWithLocalReadingLimits() {
        let layout = ShellLayout(width: 1800)
        #expect(layout.contentMaxWidth == .infinity && layout.contentWidth(available: 1568) == 1568)
        #expect(layout.contentWidth(available: 900) == 900)
        #expect(DSLayout.minWindowSize == CGSize(width: 960, height: 600))
    }

    @Test func narrowWindowCollapsesSidebarOnlyWhenCrossing() {
        let model = ShellModel(services: .preview())
        model.updateWindowWidth(1440)
        #expect(model.columnVisibility == .all)
        model.updateWindowWidth(780)
        #expect(model.columnVisibility == .detailOnly)
        model.columnVisibility = .all  // user reveals the sidebar overlay
        model.updateWindowWidth(770)
        #expect(model.columnVisibility == .all, "no fight on every resize tick")
        model.updateWindowWidth(900)
        #expect(model.columnVisibility == .all)
    }

    @Test func inspectorHidesBelow1100AndToggleResetsWhenWide() {
        let model = ShellModel(services: .preview())
        model.updateWindowWidth(1440)
        #expect(model.isInspectorPresented)
        model.updateWindowWidth(1000)
        #expect(!model.isInspectorPresented)
        model.isInspectorToggledOn = true
        #expect(model.isInspectorPresented)
        model.updateWindowWidth(1200)
        #expect(!model.isInspectorToggledOn && model.isInspectorPresented)
    }

    // MARK: Sidebar selection state

    @Test func selectedRowIsDuotoneAndBold_othersMonochrome() {
        for selection in AppSection.allCases {
            for section in AppSection.allCases {
                let look = SidebarRowAppearance(section: section, selection: selection)
                #expect(look.isSelected == (section == selection))
                #expect(look.symbolStyle == (look.isSelected ? .duotone : .monochrome))
                #expect(look.isBold == look.isSelected)
            }
        }
    }

    @Test func queueBadgeCountsRunningAndPendingOnly() async {
        let jobs = [
            Job(kind: .transcribeFile, state: .running, progress: 0.5), Job(kind: .transcribeFile, state: .pending),
            Job(kind: .transcribeFile, state: .failed), Job(kind: .transcribeFile, state: .completed),
        ]
        let sidebar = SidebarModel(services: .preview(jobs: jobs))
        let run = Task { await sidebar.run() }
        for _ in 0..<50 where sidebar.activeJobs == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(sidebar.activeJobs == 2 && sidebar.queueBadge == "2")
        run.cancel()
        #expect(SidebarModel(services: .preview()).queueBadge == nil)
    }

    @Test func modelChipReflectsInstallState() {
        let descriptor = ModelDescriptor(
            id: "m", displayName: "Whisper", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 1_600_000_000,
            license: LicenseInfo(spdx: "MIT"))
        let ready = SidebarModelChip.make(model: descriptor, state: .installed(bytesOnDisk: 1))
        #expect(ready.status == .ready && ready.statusText == "Ready" && ready.fraction == 1 && ready.detail.hasPrefix("On this Mac"))
        let loading = SidebarModelChip.make(model: descriptor, state: .downloading(fraction: 0.4))
        #expect(loading.statusText == "40%" && loading.fraction == 0.4)
        #expect(SidebarModelChip.make(model: descriptor, state: .notInstalled).fraction == 0)
    }

    @Test func recordingRowFollowsLiveSession() async {
        let model = ShellModel(services: .preview())
        #expect(!model.isRecordingActive)
        #expect(model.recordingSection == .live)
    }

    // MARK: Glass budget (T34, handoff 7)

    private static let featuresSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    private func source(_ relative: String) -> String {
        (try? String(contentsOf: Self.featuresSources.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    @Test func shellUsesAtMostOneOwnGlassLayerAndSystemSidebarMaterial() {
        let shell = source("FeatureShell/ShellView.swift") + source("FeatureShell/SidebarView.swift")
        let glassCalls = [".glassEffect(", ".dsGlass(", ".glassBackground(", "GlassEffectContainer", ".buttonStyle(.glass"]
        let uses = glassCalls.reduce(0) { $0 + shell.components(separatedBy: $1).count - 1 }
        // Budget: sidebar (system material, no call) + toolbar (the primary capsule) + one floater owned by the screen.
        #expect(uses <= DSGlass.maxLayersPerScreen - 1, "shell glass uses: \(uses)")
        #expect(shell.contains("ToolbarItem"))
        #expect(DSGlass.maxLayersPerScreen == 3 && DSGlass.allowedLayerMarkers == ["sidebar", "toolbar", "floater"])
    }

    @Test func sidebarContentIsSolidNotGlass() {
        let sidebar = source("FeatureShell/SidebarView.swift")
        #expect(!sidebar.contains("glassEffect") && !sidebar.contains("dsGlass") && !sidebar.contains("GlassCard"))
    }

    // MARK: Accessibility rules

    @Test func reduceTransparencyAndIncreaseContrastForceSolid() {  // NAV-AC-09
        #expect(AccessibilityPolicy(reduceTransparency: true).usesSolidSurface)
        #expect(AccessibilityPolicy(increaseContrast: true).usesSolidSurface)
        #expect(!AccessibilityPolicy().usesSolidSurface)
        let shell = source("FeatureShell/ShellView.swift")
        #expect(shell.contains(".borderedProminent"), "primary action is always solid")
    }

    @Test func reduceMotionReplacesSelectionGlideWithCrossfade() {  // NAV-AC-10
        let reduced = AccessibilityPolicy(reduceMotion: true)
        #expect(DSMotion.glide.animation(reduced) == .linear(duration: DSMotion.reducedDuration))
        #expect(DSMotion.glide.animation() != .linear(duration: DSMotion.reducedDuration))
        #expect(DSMotion.glide.durationRange == 0.2...0.28)  // 200-280 ms
        #expect((0.2...0.28).contains(DSMotion.glide.defaultDuration))
        let sidebar = source("FeatureShell/SidebarView.swift")
        #expect(sidebar.contains("matchedGeometryEffect") && sidebar.contains(".transition(.opacity)"))
        #expect(sidebar.contains(".dsAnimation(.glide"))
    }

    @Test func sidebarRowsReflowAtLargeTextAndFindShortcutExists() {  // NAV-AC-12, NAV-AC-04
        let sidebar = source("FeatureShell/SidebarView.swift")
        let heights = sidebar.components(separatedBy: ".frame(height: ").dropFirst().compactMap {
            Double($0.prefix { $0.isNumber || $0 == "." })
        }
        #expect(heights.allSatisfy { $0 <= 4 }, "fixed heights are limited to the 4 pt rule: \(heights)")
        #expect(sidebar.contains("minHeight") && !sidebar.contains("fixedSize"))
        let editor = source("FeatureEditor/TranscriptEditorView.swift")
        #expect(editor.contains(#".keyboardShortcut("f", modifiers: .command)"#))
    }

    @Test func primaryActionIsOnePerView() {
        let shell = source("FeatureShell/ShellView.swift")
        #expect(shell.components(separatedBy: ".buttonStyle(.borderedProminent)").count - 1 == 1)
    }
}
