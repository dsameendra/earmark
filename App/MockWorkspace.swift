#if DEBUG
    import AppCore
    import AppKit
    import EarmarkIntelligence
    import FeatureSupport
    import Foundation
    import PDFKit

    /// Deterministic workspace for UI tests under `-UseMocks`: a scripted on-device model, and (with `-EarmarkTestSlides YES`) a
    /// three-page PDF attached to the sample transcript through the real attachment code.
    @MainActor enum MockWorkspace {
        static func make(for transcript: TranscriptID) -> WorkspaceServices {
            var intelligence = ScriptedIntelligence()
            switch UITestConfiguration.value("-EarmarkTestIntelligence") {
            case "off": intelligence.state = .unavailable(.notEnabled)
            default: break
            }
            let attachments = InMemoryAttachments()
            var workspace = WorkspaceServices(
                folders: InMemoryFolders(items: seededFolders()), notes: InMemoryNotes(), attachments: attachments, chat: InMemoryChat(),
                intelligence: intelligence,
                files: AttachmentFiles(root: { FileManager.default.temporaryDirectory.appendingPathComponent("earmark-ui-attachments") }, repository: attachments))
            if UITestConfiguration.value("-EarmarkTestSlides") == "YES", let deck = makeDeck() {
                let semaphore = DispatchSemaphore(value: 0)
                let files = workspace.files
                Task.detached {
                    _ = try? await files?.attach([deck], role: .slides, to: transcript)
                    semaphore.signal()
                }
                semaphore.wait()
            }
            workspace.intelligence = intelligence
            return workspace
        }

        /// `-EarmarkTestFolders YES` seeds two folders, one pinned.
        private static func seededFolders() -> [Folder] {
            guard UITestConfiguration.value("-EarmarkTestFolders") == "YES" else { return [] }
            return [Folder(name: "Physics 201", colorIndex: 2, pinOrder: 0, createdAt: Date(timeIntervalSince1970: 1)), Folder(name: "Work", colorIndex: 0, createdAt: Date(timeIntervalSince1970: 2))]
        }

        private static func makeDeck() -> URL? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lecture slides.pdf")
            var box = CGRect(x: 0, y: 0, width: 640, height: 360)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
            let titles = ["The second law", "Heat engines", "Carnot efficiency"]
            for title in titles {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (title as NSString).draw(at: CGPoint(x: 40, y: 280), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .semibold)])
                ("Entropy never decreases in an isolated system." as NSString).draw(at: CGPoint(x: 40, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
            return url
        }
    }
#endif
