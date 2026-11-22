import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

/// Sparkle stays dormant in unconfigured and mock builds. Release configuration requires HTTPS and an Ed25519 public key.
@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    var isConfigured: Bool { controller != nil }
    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard !AppEnvironment.usesMocks,
            let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https", url.host != nil,
            let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32
        else {
            controller = nil
            return
        }
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = updater
        observation = updater.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: AppUpdateController
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        }
    }
}
