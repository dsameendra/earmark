import AppKit
import Foundation
import Testing

@testable import FeatureEditor

/// Pinch and View menu resize the popup player window and the mini-player, not the video or the waveform inside them.
@Suite @MainActor struct PlayerSizingTests {
    private let sizing = PlayerWindowSizing()

    @Test func scalingKeepsTheAspectRatio() {
        let size = sizing.scaled(CGSize(width: 640, height: 400), by: 1.25)
        #expect(size == CGSize(width: 800, height: 500))
    }

    @Test func scalingClampsToMinimumAndMaximumWithoutDistortion() {
        let small = sizing.scaled(CGSize(width: 640, height: 400), by: 0.1)
        #expect(small.width >= sizing.minSize.width && small.height >= sizing.minSize.height)
        #expect(abs(small.width / small.height - 1.6) < 0.01)
        let big = sizing.scaled(CGSize(width: 640, height: 400), by: 50)
        #expect(big.width <= sizing.maxSize.width && big.height <= sizing.maxSize.height)
        #expect(abs(big.width / big.height - 1.6) < 0.01)
    }

    @Test func scalingRespectsTheScreen() {
        let size = sizing.scaled(CGSize(width: 640, height: 400), by: 10, available: CGSize(width: 1000, height: 700))
        #expect(size.width <= 1000 && size.height <= 700)
    }

    @Test func degenerateInputIsIgnored() {
        let size = CGSize(width: 640, height: 400)
        #expect(sizing.scaled(.zero, by: 2) == .zero)
        #expect(sizing.scaled(size, by: .nan) == size)
        #expect(sizing.scaled(size, by: -1) == size)
    }

    @Test func frameStaysCenteredAndOnScreen() {
        let old = CGRect(x: 100, y: 100, width: 640, height: 428)
        let centered = PlayerWindowSizing.frame(centeredOn: old, size: CGSize(width: 800, height: 500), extra: CGSize(width: 0, height: 28))
        #expect(centered.midX == old.midX && centered.midY == old.midY)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let nudged = PlayerWindowSizing.frame(
            centeredOn: CGRect(x: 0, y: 0, width: 100, height: 100), size: CGSize(width: 800, height: 500), within: bounds)
        #expect(bounds.contains(nudged))
    }

    @Test func windowControllerScalesTheWindowAndPersistsItsFrame() async {
        let (model, _) = await Fixtures.model(segments: Fixtures.segments())
        let name = "EarmarkPlayerWindowTest-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let registry = PlayerSizeRegistry()
        let controller = PlayerWindowController(model: model, onRelink: {}, autosaveName: name, registry: registry)
        controller.show()
        let start = controller.currentFrame
        #expect(start != nil)
        controller.scale(by: 1.25, animated: false)
        let larger = controller.currentFrame
        #expect((larger?.width ?? 0) > (start?.width ?? 0))
        controller.scale(by: 0.01, animated: false)
        let smallest = controller.currentFrame
        #expect((smallest?.width ?? 0) >= controller.sizing.minSize.width)
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != nil)
        controller.close()
        #expect(registry.active == nil)
    }

    @Test func menuCommandsTargetTheRegisteredPlayer() throws {
        let registry = PlayerSizeRegistry()
        let suite = "mini-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mini = MiniPlayerSizeModel(defaults: defaults)
        #expect(registry.active == nil)
        registry.activate(mini)
        registry.active?.makeLarger()
        #expect(mini.preset == .large)
        registry.deactivate(mini)
        #expect(registry.active == nil)
    }

    @Test func miniPlayerPinchFollowsThenSnapsToPresetAndPersists() throws {
        let suite = "mini-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MiniPlayerSizeModel(defaults: defaults)
        #expect(model.preset == .regular && model.scale == 1)
        model.pinch(magnification: 1.2)
        #expect(model.scale == 1.2 && model.preset == .regular)  // continuous while pinching
        model.pinch(magnification: 1.4)
        model.endPinch()
        #expect(model.preset == .large && model.scale == MiniPlayerPreset.large.scale)
        #expect(MiniPlayerSizeModel(defaults: defaults).preset == .large)  // persisted
        model.pinch(magnification: 0.1)  // clamped
        #expect(model.scale == MiniPlayerSizeModel.scaleRange.lowerBound)
        model.endPinch()
        #expect(model.preset == .compact)
        model.makeSmaller()
        #expect(model.preset == .compact)
        model.makeLarger()
        #expect(model.preset == .regular)
    }

    @Test func playerSourceNoLongerPinchScalesTheVideoOrWaveform() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FeatureEditor")
        let views = try String(contentsOf: root.appendingPathComponent("PlayerViews.swift"), encoding: .utf8)
        #expect(!views.contains("MagnifyGesture()"), "pinch resizes the window, not the video")
        #expect(views.contains(".magnify"))
        let mini = try String(contentsOf: root.appendingPathComponent("MiniPlayerView.swift"), encoding: .utf8)
        #expect(!mini.contains("pinchZooms: true"))
    }
}
