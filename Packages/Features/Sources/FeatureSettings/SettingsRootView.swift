import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Content of the separate Settings scene: a section list with a detail pane.
public struct SettingsRootView: View {
    @State private var selection: SettingsSection = .general
    private let general: GeneralSettingsModel

    public init(store: any SettingsStore) { general = GeneralSettingsModel(store: store) }

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { selection }, set: { selection = $0 ?? selection })
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .accessibilityLabel("Settings sections")
        } detail: {
            detail.navigationTitle(selection.title)
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralSettingsView(model: general)
        default:
            EmptyState(
                systemImage: selection.systemImage, title: LocalizedStringKey(selection.title),
                message: "These settings arrive in a later update.")
        }
    }
}

struct GeneralSettingsView: View {
    let model: GeneralSettingsModel

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle(
                    "Show Dock icon",
                    isOn: Binding(get: { model.showDockIcon }, set: { value in Task { await model.setShowDockIcon(value) } })
                )
                .accessibilityHint("When off, Earmark lives in the menu bar only")
                Toggle(
                    "Keep running in the menu bar when the window closes",
                    isOn: Binding(get: { model.keepRunning }, set: { value in Task { await model.setKeepRunning(value) } }))
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

#Preview("Settings") { SettingsRootView(store: InMemorySettingsStore()) }
