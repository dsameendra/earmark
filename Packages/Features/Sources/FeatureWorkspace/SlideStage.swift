import AppCore
import AppKit
import DesignSystem
import FeatureSupport
import PDFKit
import SwiftUI

/// Reads pages of an attached deck: a PDF, or a folder of numbered images.
@MainActor
final class SlideSource {
    let attachment: Attachment
    private let location: URL
    private var document: PDFDocument?
    private var cache: [Int: NSImage] = [:]

    init(attachment: Attachment, location: URL) {
        self.attachment = attachment
        self.location = location
        if attachment.kind == .pdf { document = PDFDocument(url: location) }
    }

    var pageCount: Int { attachment.kind == .pdf ? (document?.pageCount ?? 0) : imageFiles.count }

    private var imageFiles: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A rendered page no larger than `size` (points), cached per page.
    func image(at index: Int, size: CGSize) -> NSImage? {
        if let cached = cache[index], cached.size.width >= size.width * 0.9 { return cached }
        let image: NSImage?
        if attachment.kind == .pdf {
            guard let page = document?.page(at: index) else { return nil }
            let box = page.bounds(for: .cropBox)
            let scale = min(size.width / max(box.width, 1), size.height / max(box.height, 1))
            image = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
        } else {
            let files = imageFiles
            image = files.indices.contains(index) ? NSImage(contentsOf: files[index]) : nil
        }
        if let image { cache[index] = image }
        return image
    }
}

/// The player area when it shows slides: the slide, a thumbnail strip, paging with the arrow keys, and "Slide changes here".
struct SlideStageView: View {
    let workspace: WorkspaceModel
    let showsVideoSwitch: Bool
    @State private var source: SlideSource?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                DSColor.paper
                if let source, workspace.page < source.pageCount {
                    SlideImage(source: source, page: workspace.page)
                        .padding(DSSpacing.md)
                } else {
                    ProgressView()
                }
            }
            if let source { ThumbnailStrip(source: source, workspace: workspace) }
        }
        .background(DSColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { workspace.previous(); return .handled }
        .onKeyPress(.rightArrow) { workspace.next(); return .handled }
        .task(id: workspace.deck?.id) { await loadSource() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slides")
        .accessibilityIdentifier("slides.stage")
    }

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            if showsVideoSwitch {
                DSSegmentedControl(
                    selection: Binding(get: { workspace.stage }, set: { $0 == .slides ? workspace.showSlides() : workspace.showVideo() }),
                    options: [.init("Video", value: WorkspaceModel.Stage.video), .init("Slides", value: WorkspaceModel.Stage.slides)],
                    identifier: "stage.switch")
                    .frame(height: 28)
            }
            if workspace.files.slideDecks.count > 1 {
                Menu(workspace.deck?.title ?? "Deck") {
                    ForEach(workspace.files.slideDecks) { deck in Button(deck.title) { Task { await workspace.select(deck: deck) } } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text("Slide \(workspace.page + 1) of \(workspace.deck?.pageCount ?? 0)")
                .font(DSTypography.caption).monospacedDigit().foregroundStyle(DSColor.secondaryText)
                .accessibilityIdentifier("slides.position")
            Spacer()
            Button("Previous slide", systemImage: "chevron.left") { workspace.previous() }  // stock-chrome: slide paging
                .labelStyle(.iconOnly).buttonStyle(.dsHoverIcon).disabled(workspace.page == 0).accessibilityIdentifier("slides.previous")
            Button("Next slide", systemImage: "chevron.right") { workspace.next() }  // stock-chrome: slide paging
                .labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)
                .disabled(workspace.page >= (workspace.deck?.pageCount ?? 1) - 1).accessibilityIdentifier("slides.next")
            Menu {
                Button("Slide changes here") { Task { await workspace.linkCurrentSlide() } }
                    .disabled(workspace.currentTime() == nil)
                Toggle("Follow the recording", isOn: Binding(get: { workspace.followsPlayback }, set: { workspace.followsPlayback = $0 }))
                    .disabled(workspace.links.isEmpty)
                Divider()
                Button("Clear slide timings", role: .destructive) { Task { await workspace.clearLinks() } }.disabled(workspace.links.isEmpty)
            } label: { Label("Timing", systemImage: "timer") }  // stock-chrome: slide timing
                .menuStyle(.borderlessButton).fixedSize()
                .help("Link slides to moments in the recording so playback follows the deck")
                .accessibilityIdentifier("slides.timing")
        }
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs)
        .background(DSColor.solidChrome)
    }

    private func loadSource() async {
        guard let deck = workspace.deck, let location = await workspace.files.location(of: deck) else {
            source = nil
            return
        }
        source = SlideSource(attachment: deck, location: location)
    }
}

private struct SlideImage: View {
    let source: SlideSource
    let page: Int

    var body: some View {
        GeometryReader { proxy in
            if let image = source.image(at: page, size: CGSize(width: proxy.size.width * 2, height: proxy.size.height * 2)) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .shadow(color: DSColor.shadow.opacity(0.2), radius: 8, y: 2)
                    .accessibilityLabel("Slide \(page + 1)")
            }
        }
    }
}

private struct ThumbnailStrip: View {
    let source: SlideSource
    let workspace: WorkspaceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: DSSpacing.xs) {
                    ForEach(0..<source.pageCount, id: \.self) { index in
                        Button { workspace.goTo(page: index) } label: {
                            Group {
                                if let image = source.image(at: index, size: CGSize(width: 160, height: 100)) {
                                    Image(nsImage: image).resizable().scaledToFit()
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 72, height: 46)
                            .padding(2)
                            .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(index == workspace.page ? DSColor.accent : DSColor.hairline, lineWidth: index == workspace.page ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("Slide \(index + 1)")
                        .accessibilityAddTraits(index == workspace.page ? .isSelected : [])
                        .accessibilityIdentifier("slides.thumb.\(index)")
                    }
                }
                .padding(DSSpacing.xs)
            }
            .scrollIndicators(.hidden)
            .background(DSColor.solidChrome)
            .onChange(of: workspace.page) { withAnimation { proxy.scrollTo(workspace.page, anchor: .center) } }
        }
        .frame(height: 62)
    }
}
