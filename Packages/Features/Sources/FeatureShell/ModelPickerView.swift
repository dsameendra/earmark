import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Popover opened from the sidebar's model chip: pick the speech model for files, live captions or dictation.
struct ModelPickerView: View {
    let model: ModelPickerModel
    var onManageModels: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Picker(
                "Use", selection: Binding(get: { model.useCase }, set: { use in Task { await model.setUseCase(use) } })
            ) {
                ForEach(UseCase.allCases, id: \.self) { Text(ModelPickerModel.title(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Use case")
            .accessibilityIdentifier("modelPicker.useCase")

            Text(model.contextSummary)
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)

            if let pending = model.pending { confirmation(pending) }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DSTypography.caption).foregroundStyle(DSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("modelPicker.error")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    automaticRow
                    ForEach(ModelPickerGroup.allCases, id: \.self) { group in
                        let entries = model.entries(in: group)
                        if !entries.isEmpty {
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                Text(group.title.uppercased())
                                    .font(DSTypography.label).tracking(DSTypography.labelTracking)
                                    .foregroundStyle(DSColor.secondaryText)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(entries) { row($0) }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 200, idealHeight: 320, maxHeight: 380)

            Divider()
            HStack {
                Spacer()
                Button("Manage Models…", action: onManageModels)
                    .accessibilityIdentifier("modelPicker.manage")
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 380, idealWidth: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelPicker")
        .task { await model.reload() }
    }

    private var automaticRow: some View {
        Button {
            Task { await model.select(nil) }
        } label: {
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                checkmark(model.isAutomaticSelected)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text("Automatic").font(DSTypography.body).fontWeight(.semibold)
                    Text("Earmark picks the best model for your language and this Mac.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsHover(shape: .rounded(DSRadius.small), horizontalPadding: DSSpacing.sm))
        .accessibilityAddTraits(model.isAutomaticSelected ? .isSelected : [])
        .accessibilityIdentifier("modelPicker.automatic")
    }

    private func row(_ entry: ModelPickerEntry) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            rowButton(entry)
            progress(entry).padding(.leading, DSSpacing.lg + DSSpacing.sm)
        }
    }

    private func rowButton(_ entry: ModelPickerEntry) -> some View {
        Button {
            Task { await model.select(entry.id) }
        } label: {
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                checkmark(entry.isSelected)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                        Text(entry.descriptor.displayName).font(DSTypography.body).fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.isRecommended { StatusPill("Recommended", systemImage: "star.fill", tone: .success) }
                    }
                    Text("\(entry.sizeText) · \(entry.stateText)")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = entry.disabledReason {
                        Label(reason, systemImage: "nosign")
                            .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if entry.isRecommended, let why = model.recommendationWhy(for: entry.id) {
                        Text(why).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing(entry)
            }
            .contentShape(Rectangle())
            .opacity(entry.isDisabled ? 0.55 : 1)
        }
        .buttonStyle(.dsHover(shape: .rounded(DSRadius.small), horizontalPadding: DSSpacing.sm))
        .disabled(entry.isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
        .accessibilityIdentifier("modelPicker.row.\(entry.id.rawValue)")
    }

    @ViewBuilder private func progress(_ entry: ModelPickerEntry) -> some View {
        if let fraction = model.downloads[entry.id] {
            HStack {
                ProgressView(value: fraction).accessibilityLabel("Downloading \(entry.descriptor.displayName)")
                Button("Cancel", systemImage: "xmark.circle") { Task { await model.cancelDownload(entry.id) } }
                    .labelStyle(.iconOnly).buttonStyle(.dsHoverIcon).help("Cancel download")
                    .accessibilityLabel("Cancel download of \(entry.descriptor.displayName)")
                    .accessibilityIdentifier("modelPicker.cancel.\(entry.id.rawValue)")
            }
        } else if case .downloading(let fraction) = entry.state {
            ProgressView(value: fraction)
        }
    }

    @ViewBuilder private func trailing(_ entry: ModelPickerEntry) -> some View {
        if entry.isDisabled || model.downloads[entry.id] != nil {
            EmptyView()
        } else {
            switch entry.state {
            case .notInstalled: DSIcon(.download).foregroundStyle(DSColor.secondaryText).accessibilityHidden(true)
            case .failed: DSIcon(.retry).foregroundStyle(DSColor.danger).accessibilityHidden(true)
            default: EmptyView()
            }
        }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: "checkmark").fontWeight(.semibold)
            .foregroundStyle(DSColor.accent).opacity(on ? 1 : 0)
            .frame(width: DSSpacing.lg).accessibilityHidden(true)
    }

    private func confirmation(_ pending: PendingModelDownload) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(pending.text.title).font(DSTypography.headline)
            Text(pending.text.message).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelPending() }
                    .accessibilityIdentifier("modelPicker.pending.cancel")
                Button(pending.isRetry ? "Retry" : pending.text.confirmTitle) { Task { await model.confirmPending() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("modelPicker.pending.confirm")
            }
        }
        .padding(DSSpacing.md)
        .dsSolidSurface(.inset, radius: DSRadius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelPicker.pending")
    }
}
