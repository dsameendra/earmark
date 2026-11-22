import Foundation

/// The 24 duotone symbols of the M8 `Icons` board plus the listening ear (T33).
///
/// Each case maps to a custom symbol (`assetName`, authored on the SF Symbols 7 template with nine weights and three
/// scales, ink layer plus one Ember accent layer, see `Tools/generate-symbols.swift`) and to a stock SF Symbol
/// (`systemImageName`) used when the custom asset cannot be resolved. Generic chrome glyphs (chevrons, xmark,
/// checkmark, ellipsis, plus, minus) are deliberately not covered and stay stock.
public enum DSSymbol: String, CaseIterable, Sendable, Hashable, Identifiable {
    case home, queue, meetings, liveCaptions, library, recentlyDeleted
    case dictation, record, speaker, translate, export, hidden
    case earmark, find, models, settings, play, waveform
    case folder, language, download, systemAudio, video, retry
    case ear, search, replace

    public var id: String { assetName }

    /// Name of the custom symbol in `Symbols.xcassets` (the `Icons` board's asset name).
    public var assetName: String {
        switch self {
        case .home: "earmark.home"
        case .queue: "earmark.queue"
        case .meetings: "earmark.meetings"
        case .liveCaptions: "earmark.live.captions"
        case .library: "earmark.library"
        case .recentlyDeleted: "earmark.recently.deleted"
        case .dictation: "earmark.dictation"
        case .record: "earmark.record"
        case .speaker: "earmark.speaker"
        case .translate: "earmark.translate"
        case .export: "earmark.export"
        case .hidden: "earmark.hidden"
        case .earmark: "earmark.earmark"
        case .find: "earmark.find"
        case .search: "earmark.search"
        case .replace: "earmark.replace"
        case .models: "earmark.models"
        case .settings: "earmark.settings"
        case .play: "earmark.play"
        case .waveform: "earmark.waveform"
        case .folder: "earmark.folder"
        case .language: "earmark.language"
        case .download: "earmark.download"
        case .systemAudio: "earmark.system.audio"
        case .video: "earmark.video"
        case .retry: "earmark.retry"
        case .ear: "earmark.ear"
        }
    }

    /// Stock SF Symbol shown when the custom asset is missing. This is the glyph the custom symbol replaces.
    public var systemImageName: String {
        switch self {
        case .home: "house"
        case .queue: "tray.full"
        case .meetings: "person.2.wave.2"
        case .liveCaptions: "captions.bubble"
        case .library: "books.vertical"
        case .recentlyDeleted: "trash"
        case .dictation: "mic"
        case .record: "record.circle"
        case .speaker: "person.2"
        case .translate: "translate"
        case .export: "square.and.arrow.up"
        case .hidden: "eye.slash"
        case .earmark: "bookmark"
        case .find: "doc.text.magnifyingglass"
        case .search: "magnifyingglass"
        case .replace: "arrow.triangle.2.circlepath"
        case .models: "cpu"
        case .settings: "gearshape"
        case .play: "play.circle"
        case .waveform: "waveform"
        case .folder: "folder"
        case .language: "globe"
        case .download: "arrow.down.circle"
        case .systemAudio: "speaker.wave.2"
        case .video: "video"
        case .retry: "arrow.clockwise"
        case .ear: "ear"
        }
    }

    /// VoiceOver label when the symbol is used standalone (an icon-only control or a lone indicator).
    public var accessibilityLabel: String {
        switch self {
        case .home: "Home"
        case .queue: "Queue"
        case .meetings: "Meetings"
        case .liveCaptions: "Live captions"
        case .library: "Library"
        case .recentlyDeleted: "Recently deleted"
        case .dictation: "Dictation"
        case .record: "Record"
        case .speaker: "Speaker"
        case .translate: "Translate"
        case .export: "Export"
        case .hidden: "Hidden"
        case .earmark: "Earmark"
        case .find: "Find in transcript"
        case .search: "Search transcripts"
        case .replace: "Replace text"
        case .models: "Models"
        case .settings: "Settings"
        case .play: "Play"
        case .waveform: "Waveform"
        case .folder: "Folder"
        case .language: "Language"
        case .download: "Download"
        case .systemAudio: "System audio"
        case .video: "Video"
        case .retry: "Retry"
        case .ear: "Earmark"
        }
    }

    /// Stock SF Symbol names that the codemod replaced with this symbol (used by `init(replacingStock:)` and by the
    /// coverage test, which fails when one of them reappears as an inline string in a Features source file).
    public var replacedStockNames: [String] {
        switch self {
        case .home: ["house"]
        case .queue: ["tray.full"]
        case .meetings: ["person.2.wave.2"]
        case .liveCaptions: ["captions.bubble", "captions.bubble.fill"]
        case .library: ["books.vertical", "doc.text"]
        case .recentlyDeleted: ["trash"]
        case .dictation: ["mic", "mic.fill"]
        case .record: ["record.circle", "record.circle.fill"]
        case .speaker: ["person.2", "waveform.circle"]
        case .translate: ["translate", "character.bubble"]
        case .export: ["square.and.arrow.up"]
        case .hidden: ["eye.slash"]
        case .earmark: ["bookmark"]
        case .find: ["doc.text.magnifyingglass"]
        case .search: ["magnifyingglass"]
        case .replace: []
        case .models: ["cpu"]
        case .settings: ["gearshape", "slider.horizontal.3"]
        case .play: ["play.circle"]
        case .waveform: ["waveform"]
        case .folder: ["folder"]
        case .language: ["globe"]
        case .download: ["arrow.down.circle"]
        case .systemAudio: ["speaker.wave.2"]
        case .video: ["video"]
        case .retry: ["arrow.clockwise"]
        case .ear: []
        }
    }

    /// The symbol that replaces a stock SF Symbol name, if that glyph is one of the covered ones.
    public init?(replacingStock name: String) {
        guard let match = Self.allCases.first(where: { $0.replacedStockNames.contains(name) }) else { return nil }
        self = match
    }
}
