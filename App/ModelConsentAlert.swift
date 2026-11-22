import AppKit
import FeatureSupport

/// The licence/size confirmation shown by the model manager's consent hook (SCR-011), whichever feature started the download.
struct ModelConsentAlert: ModelConsentPresenting {
    @MainActor func present(_ text: ModelConsentText) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text.title
        alert.informativeText = text.message
        let confirm = alert.addButton(withTitle: text.confirmTitle)
        confirm.setAccessibilityIdentifier("modelConsent.confirm")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.setAccessibilityIdentifier("modelConsent.cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
