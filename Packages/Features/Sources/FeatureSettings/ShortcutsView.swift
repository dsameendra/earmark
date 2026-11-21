import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// A click-to-record key field. Esc cancels; recording needs a modifier (or a function key).
struct KeyRecorderField: NSViewRepresentable {
    let combo: KeyCombo?
    let onRecord: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = onRecord
        button.title = button.isRecording ? "Type shortcut…" : (combo.map(ShortcutsModel.display) ?? "Record")
    }

    final class RecorderButton: NSButton {
        var onRecord: ((KeyCombo) -> Void)?
        private(set) var isRecording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(toggleRecording)
            setAccessibilityLabel("Shortcut recorder")
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var acceptsFirstResponder: Bool { true }

        @objc private func toggleRecording() {
            isRecording = true
            title = "Type shortcut…"
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            if event.keyCode == 53 {  // Esc
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mask = 0
            if flags.contains(.shift) { mask |= ModifierMask.shift }
            if flags.contains(.control) { mask |= ModifierMask.control }
            if flags.contains(.option) { mask |= ModifierMask.option }
            if flags.contains(.command) { mask |= ModifierMask.command }
            isRecording = false
            window?.makeFirstResponder(nil)
            onRecord?(KeyCombo(keyCode: event.keyCode, modifiers: mask))
        }
    }
}

struct ShortcutsSettingsView: View {
    let model: ShortcutsModel

    var body: some View {
        Form {
            section("Global", actions: ShortcutAction.allCases.filter(\.isGlobal))
            section("In the app", actions: ShortcutAction.allCases.filter { !$0.isGlobal })
            if let message = model.errorMessage {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger) }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .alert(
            "Shortcut already in use",
            isPresented: Binding(get: { model.pendingConflict != nil }, set: { if !$0 { model.cancelConflict() } })
        ) {
            Button("Use anyway") { Task { await model.confirmConflict() } }
            Button("Cancel", role: .cancel) { model.cancelConflict() }
        } message: {
            if let pending = model.pendingConflict {
                if let other = pending.conflictsWith {
                    Text(
                        "\(ShortcutsModel.display(pending.combo)) is already used for “\(other.title)”. "
                            + "Using it here will clear that shortcut."
                    )
                } else {
                    Text("\(ShortcutsModel.display(pending.combo)) is reserved by macOS and may not work.")
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, actions: [ShortcutAction]) -> some View {
        Section(title) {
            ForEach(actions) { action in
                LabeledContent(action.title) {
                    HStack {
                        KeyRecorderField(combo: model.combo(for: action)) { combo in Task { await model.record(combo, for: action) } }
                            .frame(width: 130, height: 24)
                        Button("Clear", systemImage: "xmark.circle") { Task { await model.clear(action) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.combo(for: action) == nil)
                            .accessibilityLabel("Clear \(action.title) shortcut")
                        Button("Reset", systemImage: "arrow.counterclockwise") { Task { await model.resetToDefault(action) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .accessibilityLabel("Reset \(action.title) shortcut")
                    }
                }
            }
        }
    }
}
