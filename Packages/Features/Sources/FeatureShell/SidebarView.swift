import AppCore
import DesignSystem
import FeatureLibrary
import FeatureSupport
import SwiftUI

/// How one sidebar row is drawn for a given selection (pure, so tests can pin it without rendering).
public struct SidebarRowAppearance: Equatable, Sendable {
    public var isSelected: Bool
    /// Duotone (ink plus Ember detail) when selected, monochrome at rest (`Icons` board, sidebar states).
    public var symbolStyle: DSSymbolStyle
    public var isBold: Bool

    public init(section: AppSection, selection: AppSection) {
        isSelected = section == selection
        symbolStyle = isSelected ? .duotone : .monochrome
        isBold = isSelected
    }
}

/// The sidebar column: brand, six section rows with one gliding selection pill, folders, model chip and Settings.
///
/// The column itself is the system `NavigationSplitView` sidebar (macOS 26 glass material, glass layer 1 of 3), so
/// no glass modifier is applied here; rows, chip and badges are solid content. The selection pill is a single shape
/// that glides between rows with the `glide` motion token (200-280 ms) and crossfades under Reduce Motion.
struct SidebarView: View {
    @Bindable var model: ShellModel
    @Namespace private var pillSpace
    @FocusState private var navigationFocused: Bool
    /// The row a drag is over (a pinned row id, `library` or `trash`), for the drop highlight and insertion line.
    @State private var targetedRow: String?
    /// A compatible drag is somewhere over the sidebar.
    @State private var sidebarTargeted = false
    @State private var isModelPickerPresented = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride

    private var motionReduced: Bool { policyOverride?.suppressesMotion ?? reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            brand
            if model.isRecordingActive { recordingRow }
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    ForEach(AppSection.topSections) { section in row(section) }
                    SidebarDivider()
                    row(.library)
                        .dropTarget(id: "library", targeted: $targetedRow, tint: .accent, accepts: { _ in true }) { drag in dropOnLibrary(drag) }
                    if !model.sidebar.pinned.isEmpty { pinnedList } else if showsPinHint { pinHint }
                    SidebarDivider()
                    row(.recentlyDeleted)
                        .dropTarget(id: "trash", targeted: $targetedRow, tint: .danger, accepts: { _ in true }) { drag in dropOnTrash(drag) }
                }
                .compositingGroup()
                .dsAnimation(.glide, value: model.sidebar.pinned.map(\.id))
                .dsAnimation(.glide, value: showsPinHint)
            }
            .dropDestination(for: WorkspaceDrag.self) { dropped, _ in dropOnSidebar(dropped.first) } isTargeted: { sidebarTargeted = $0 }
            .scrollIndicators(.hidden)
            if let chip = model.sidebar.modelChip {
                Button { isModelPickerPresented.toggle() } label: { CompactModelChipView(chip: chip) }
                    .buttonStyle(.plain)
                    .help("Choose the speech model for files, live captions and dictation")
                    .accessibilityLabel("Speech model, \(chip.name), \(chip.statusText). Opens the model picker.")
                    .accessibilityValue(chip.detail)
                    .accessibilityIdentifier("sidebar.modelChip")
                    .popover(isPresented: $isModelPickerPresented, arrowEdge: .trailing) {
                        ModelPickerView(model: model.sidebar.picker, onManageModels: {
                            isModelPickerPresented = false
                            openSettings()
                        })
                    }
            }
            settingsRow
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.bottom, DSSpacing.sm)
        .dsAnimation(.glide, value: model.selection)
        .dsIconContext(.sidebar)
        .focusable()
        .focusEffectDisabled()
        .focused($navigationFocused)
        .onKeyPress(.upArrow) {
            guard navigationFocused else { return .ignored }
            model.moveSidebarSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard navigationFocused else { return .ignored }
            model.moveSidebarSelection(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("earmark").font(.system(size: 22, design: .serif)).foregroundStyle(DSColor.primaryText)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.top, DSSpacing.xs)
        .padding(.bottom, DSSpacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Earmark")
        .accessibilityIdentifier("sidebar.brand")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Section rows

    private func row(_ section: AppSection) -> some View {
        let look = SidebarRowAppearance(section: section, selection: model.selection)
        return Button {
            if section == .library { model.library.filters.folderID = nil }  // the Library row is the whole Library
            model.select(section)
            navigationFocused = true
        } label: {
            HStack(spacing: 11) {
                DSIcon(section.symbol, style: look.symbolStyle).font(.system(size: 17)).frame(width: 22)
                    .foregroundStyle(look.isSelected ? DSColor.primaryText : DSColor.secondaryText)
                Text(section.title).fontWeight(look.isBold ? .semibold : .regular)
                Spacer(minLength: DSSpacing.xs)
                if section == .queue, let badge = model.sidebar.queueBadge { Badge(text: badge) }
            }
            .foregroundStyle(look.isSelected ? DSColor.primaryText : DSColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: DSLayout.minControlHeight + 6)
            .background { if look.isSelected { pill } }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.medium + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityHint("Command \(section.shortcutNumber)")
        .accessibilityAddTraits(look.isSelected ? .isSelected : [])
        .accessibilityIdentifier(section.accessibilityIdentifier)
    }

    /// The single selection pill. Glides between rows (matched geometry) or crossfades under Reduce Motion.
    @ViewBuilder private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.medium + 4, style: .continuous)
        let base = shape.fill(DSColor.selectionPill)
            .overlay(shape.strokeBorder(DSColor.hairline, lineWidth: 0.5))
            .shadow(color: DSColor.shadow.opacity(0.12), radius: 8, y: 3)
        if motionReduced {
            base.transition(.opacity)
        } else {
            base.matchedGeometryEffect(id: "selection-pill", in: pillSpace)
        }
    }

    // MARK: Recording

    private var recordingRow: some View {
        Button {
            model.select(model.recordingSection)
        } label: {
            HStack {
                RecordingIndicator(label: "Recording")
                Spacer(minLength: DSSpacing.xs)
                Text(model.recordingSection.title).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: DSLayout.minControlHeight + 2)
            .background(DSColor.recording.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityLabel("Recording in progress")
        .accessibilityHint("Opens \(model.recordingSection.title)")
        .accessibilityIdentifier("sidebar.recording")
    }

    // MARK: Pinned

    private var pinnedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sidebar.pinned) { item in
                pinnedRow(item).transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
            // Below the last row: dropping here pins at the end.
            Color.clear.frame(height: 10).contentShape(Rectangle())
                .overlay(alignment: .top) { if targetedRow == "tail" { InsertionLine() } }
                .dropDestination(for: WorkspaceDrag.self) { dropped, _ in dropOnSidebar(dropped.first) } isTargeted: { setTargeted("tail", $0) }
        }
        .padding(.leading, DSSpacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned")
        .accessibilityIdentifier("sidebar.pinned")
    }

    private func isActive(_ item: PinnedItem) -> Bool {
        switch item {
        case .folder(let folder, _): model.selection == .library && model.openedTranscript == nil && model.library.filters.folderID == folder.id
        case .transcript(let transcript): model.openedTranscript == transcript.id
        }
    }

    private func pinnedRow(_ item: PinnedItem) -> some View {
        let active = isActive(item)
        return Button {
            switch item {
            case .folder(let folder, _): model.openFolder(folder.id)
            case .transcript(let transcript): model.openTranscript(transcript.id)
            }
            navigationFocused = true
        } label: {
            HStack(spacing: 9) {
                pinnedIcon(item)
                Text(item.title).lineLimit(1)
                Spacer(minLength: DSSpacing.xs)
                if case .folder(_, let count) = item, count > 0 {
                    Text("\(count)").font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText)
                }
            }
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? DSColor.primaryText : DSColor.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background { if active { RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).fill(DSColor.selectionPill) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { if targetedRow == item.id, !movesIntoFolder(item) { InsertionLine() } }
        .background {
            if targetedRow == item.id, movesIntoFolder(item) {
                RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).fill(DSColor.accent.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).strokeBorder(DSColor.accent, lineWidth: 1.5))
            }
        }
        .draggable(WorkspaceDragState.shared.begin(WorkspaceDrag(pinnedRow: item.id))) {
            Text(item.title).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(DSColor.contentBackground, in: Capsule())
        }
        .dropDestination(for: WorkspaceDrag.self) { dropped, _ in dropOnPinned(dropped.first, item: item) } isTargeted: { setTargeted(item.id, $0) }
        .contextMenu {
            Button("Unpin from Sidebar", systemImage: "pin.slash") { Task { await model.sidebar.unpin(item) } }
            Button("Move Up", systemImage: "arrow.up") { Task { await model.sidebar.movePinned(item.id, by: -1) } }
            Button("Move Down", systemImage: "arrow.down") { Task { await model.sidebar.movePinned(item.id, by: 1) } }
        }
        .accessibilityLabel(pinnedLabel(item))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction(named: "Unpin") { Task { await model.sidebar.unpin(item) } }
        .accessibilityAction(named: "Move up") { Task { await model.sidebar.movePinned(item.id, by: -1) } }
        .accessibilityAction(named: "Move down") { Task { await model.sidebar.movePinned(item.id, by: 1) } }
        .accessibilityIdentifier("sidebar.pinned.\(item.id)")
    }

    @ViewBuilder private func pinnedIcon(_ item: PinnedItem) -> some View {
        switch item {
        case .folder(let folder, _):
            Circle().fill(SpeakerPalette.color(forSlot: folder.colorIndex)).frame(width: 8, height: 8).frame(width: 14).accessibilityHidden(true)
        case .transcript:
            Image(systemName: "doc.text")  // stock-chrome: pinned transcript
                .font(.system(size: 12)).frame(width: 14).accessibilityHidden(true)
        }
    }

    private func pinnedLabel(_ item: PinnedItem) -> String {
        switch item {
        case .folder(let folder, let count): "Pinned folder \(folder.name), \(count) items"
        case .transcript(let transcript): "Pinned transcript \(transcript.title)"
        }
    }

    // MARK: Drag and drop

    private var dragKind: WorkspaceDragState.Kind? { WorkspaceDragState.shared.kind }

    /// The "Drop to pin" hint: only while a transcript or folder is dragged over the sidebar and nothing is pinned yet.
    private var showsPinHint: Bool {
        guard sidebarTargeted else { return false }
        switch dragKind {
        case .transcripts, .folder: return true
        default: return false
        }
    }

    private var pinHint: some View {
        HStack(spacing: 9) {
            Image(systemName: "pin").font(.system(size: 12)).frame(width: 14)  // stock-chrome: pin hint
            Text("Drop here to pin").font(.system(size: 13))
        }
        .foregroundStyle(DSColor.accentText)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous)
                .strokeBorder(DSColor.accent.opacity(targetedRow == "tail" ? 1 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(DSColor.accent.opacity(targetedRow == "tail" ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        )
        .padding(.leading, DSSpacing.sm)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        .dropDestination(for: WorkspaceDrag.self) { dropped, _ in dropOnSidebar(dropped.first) } isTargeted: { setTargeted("tail", $0) }
        .accessibilityHidden(true)
    }

    private func setTargeted(_ id: String, _ targeted: Bool) {
        if targeted {
            guard targetedRow != id else { return }
            targetedRow = id
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        } else if targetedRow == id {
            targetedRow = nil
        }
    }

    /// A folder row accepts transcripts to move into it; everything else dropped on a pinned row is placed before it.
    private func movesIntoFolder(_ item: PinnedItem) -> Bool {
        guard case .folder = item, case .transcripts = dragKind else { return false }
        return true
    }

    private func dropOnPinned(_ drag: WorkspaceDrag?, item: PinnedItem) -> Bool {
        guard let drag else { return false }
        defer { WorkspaceDragState.shared.end() }
        if let row = drag.pinnedRow {
            guard row != item.id else { return false }
            Task { await model.sidebar.movePinned(row, before: item.id) }
            return true
        }
        if let folder = drag.folder {
            Task { await model.sidebar.pin(folder: folder, before: item.id) }
            return true
        }
        guard !drag.transcripts.isEmpty else { return false }
        if case .folder(let folder, _) = item {
            Task { await model.library.move(drag.transcripts, to: folder.id) }
        } else {
            Task { await model.sidebar.pin(transcripts: drag.transcripts, before: item.id) }
        }
        return true
    }

    /// Dropped on the empty part of the sidebar or the tail of the pinned list: pin at the end.
    private func dropOnSidebar(_ drag: WorkspaceDrag?) -> Bool {
        guard let drag else { return false }
        defer { WorkspaceDragState.shared.end() }
        if let row = drag.pinnedRow {
            Task { await model.sidebar.movePinned(row, before: nil) }
            return true
        }
        if let folder = drag.folder {
            Task { await model.sidebar.pin(folder: folder) }
            return true
        }
        guard !drag.transcripts.isEmpty else { return false }
        Task { await model.sidebar.pin(transcripts: drag.transcripts) }
        return true
    }

    /// Dropped on Library: the transcripts leave their folder.
    private func dropOnLibrary(_ drag: WorkspaceDrag) -> Bool {
        defer { WorkspaceDragState.shared.end() }
        guard !drag.transcripts.isEmpty else { return false }
        Task { await model.library.move(drag.transcripts, to: nil) }
        return true
    }

    /// Dropped on Recently Deleted: the transcripts move there (and can be restored).
    private func dropOnTrash(_ drag: WorkspaceDrag) -> Bool {
        defer { WorkspaceDragState.shared.end() }
        guard !drag.transcripts.isEmpty else { return false }
        Task { await model.library.delete(drag.transcripts) }
        return true
    }

    // MARK: Settings

    private var settingsRow: some View {
        SettingsLink {
            HStack(spacing: 11) {
                DSIcon(.settings).font(.system(size: 17)).frame(width: 22)
                Text("Settings")
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSColor.secondaryText)
            .frame(maxWidth: .infinity, minHeight: DSLayout.minControlHeight + 6, alignment: .leading)
        }
        // Hover/pressed highlight is drawn behind the full padded row, in the same shape as the sidebar selection pill.
        .buttonStyle(DSHoverButtonStyle(shape: .rounded(DSRadius.medium + 4), horizontalPadding: 14))
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("sidebar.settings")
    }
}

/// Count badge: `accentText` on the Ember tint (4.5:1 in both appearances).
private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(DSColor.accentText)
            .frame(minWidth: 18)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(DSColor.accentTint, in: Capsule())
            .accessibilityLabel("\(text) active")
    }
}

/// Footer chip: model name, status, Ember rule and size ("Whisper large-v3 turbo  Ready").
struct ModelChipView: View {
    let chip: SidebarModelChip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FILE TRANSCRIPTION")
                .font(DSTypography.label).tracking(DSTypography.labelTracking)
                .foregroundStyle(DSColor.secondaryText)
            HStack {
                Text(chip.name).fontWeight(.semibold).foregroundStyle(DSColor.primaryText).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: DSSpacing.xs) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(chip.statusText).foregroundStyle(statusColor).fontWeight(.medium)
            }
            if showsProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DSColor.primaryText.opacity(0.1))
                        Capsule().fill(DSColor.accent).frame(width: proxy.size.width * chip.fraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            Text(chip.detail).foregroundStyle(DSColor.secondaryText).lineLimit(2)
        }
        .font(.system(size: 12))
        .padding(.horizontal, DSSpacing.md).padding(.vertical, 10)
        .dsSolidSurface(.inset, radius: DSRadius.large)
        .padding(.horizontal, 4)
        .dsAnimation(.glide, value: chip)
    }

    private var showsProgress: Bool {
        switch chip.status {
        case .downloading, .paused: true
        case .ready, .notInstalled, .failed: false
        }
    }

    private var statusColor: Color {
        switch chip.status {
        case .ready: DSColor.success
        case .failed: DSColor.danger
        case .paused: DSColor.warning
        case .downloading: DSColor.accentText
        case .notInstalled: DSColor.secondaryText
        }
    }
}


/// The speech model as one compact line (name, status dot, short status); the picker opens from it.
struct CompactModelChipView: View {
    let chip: SidebarModelChip

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(chip.name).font(.system(size: 12, weight: .medium)).foregroundStyle(DSColor.primaryText).lineLimit(1)
            Spacer(minLength: DSSpacing.xs)
            Text(shortStatus).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: DSLayout.minControlHeight)
        .dsSolidSurface(.inset, radius: DSRadius.medium)
        .padding(.horizontal, 4)
        .dsAnimation(.glide, value: chip)
    }

    private var shortStatus: String {
        switch chip.status {
        case .downloading(let fraction): "\(Int(fraction * 100))%"
        default: chip.statusText
        }
    }

    private var statusColor: Color {
        switch chip.status {
        case .ready: DSColor.success
        case .failed: DSColor.danger
        case .paused: DSColor.warning
        case .downloading: DSColor.accentText
        case .notInstalled: DSColor.secondaryText
        }
    }
}

/// A hairline between sidebar groups.
private struct SidebarDivider: View {
    var body: some View {
        Rectangle().fill(DSColor.hairline).frame(height: 1)
            .padding(.horizontal, 6).padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

/// The accent line that shows where a dropped item will land.
private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(DSColor.accent).frame(width: 6, height: 6)
            Capsule().fill(DSColor.accent).frame(height: 2)
        }
        .padding(.horizontal, 4)
        .offset(y: -1)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum DropTint { case accent, danger }

private extension View {
    /// Makes a sidebar row a drop target that rings itself while a compatible drag is over it.
    func dropTarget(
        id: String, targeted: Binding<String?>, tint: DropTint, accepts: @escaping (WorkspaceDrag) -> Bool, action: @escaping (WorkspaceDrag) -> Bool
    ) -> some View {
        let color = tint == .danger ? DSColor.danger : DSColor.accent
        let shape = RoundedRectangle(cornerRadius: DSRadius.medium + 4, style: .continuous)
        return background {
            if targeted.wrappedValue == id {
                shape.fill(color.opacity(0.12)).overlay(shape.strokeBorder(color, lineWidth: 1.5)).transition(.opacity)
            }
        }
        .dsAnimation(.glide, value: targeted.wrappedValue == id)
        .dropDestination(for: WorkspaceDrag.self) { dropped, _ in
            guard let drag = dropped.first, accepts(drag) else { return false }
            return action(drag)
        } isTargeted: { inside in
            if inside {
                if targeted.wrappedValue != id {
                    targeted.wrappedValue = id
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            } else if targeted.wrappedValue == id {
                targeted.wrappedValue = nil
            }
        }
    }
}
