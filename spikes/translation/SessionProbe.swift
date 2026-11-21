// Headless TranslationSession (macOS 26+): no SwiftUI view. Works only for pairs already installed.
// Build: swiftc -parse-as-library -o /tmp/sessionprobe SessionProbe.swift && /tmp/sessionprobe
import Foundation
import Translation

@main struct Probe {
  static func main() async {
    let av = LanguageAvailability()
    let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")
    print("status es->en:", await av.status(from: src, to: dst))
    let session = TranslationSession(installedSource: src, target: dst)
    print("isReady:", await session.isReady, "canRequestDownloads:", await session.canRequestDownloads)
    do {
      let reqs = ["Buenos días a todos.", "La reunión empieza en cinco minutos.", "¿Podemos revisar el presupuesto?"]
        .enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)") }
      let out = try await session.translations(from: reqs)   // batch, order-preserving via clientIdentifier
      for r in out { print(r.clientIdentifier ?? "-", r.targetText) }
    } catch { print("error:", error) }
  }
}
