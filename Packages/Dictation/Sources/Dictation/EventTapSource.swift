import AppCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Production ``HotkeyEventSource`` backed by a `CGEventTap` on the main run loop.
///
/// With `swallowing: true` the tap is an active (`.defaultTap`) filter: events the handler claims (the registered
/// shortcut's key-down, auto-repeat and key-up, or the Fn key's flag change) are dropped so they never reach the focused
/// app; everything else passes through untouched. Active taps need Accessibility, so `start` throws without it and
/// ``FallbackHotkeySource`` degrades to a listen-only tap (Input Monitoring) that cannot swallow. A tap the OS disables
/// (callback timeout, user input) is re-enabled and the matcher state is reset so a held key cannot stay "down".
public final class CGEventTapHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let swallowing: Bool
    private let isTrusted: @Sendable () -> Bool
    private var handler: (@Sendable (RawKeyEvent) -> Bool)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(swallowing: Bool = false, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.swallowing = swallowing
        self.isTrusted = isTrusted
    }

    public var capture: HotkeyCapture { swallowing ? .swallowing : .listenOnly }

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tap == nil else {
            self.handler = handler
            return
        }
        if swallowing, !isTrusted() { throw HotkeyError.eventSourceUnavailable }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let consumed = Unmanaged<CGEventTapHotkeySource>.fromOpaque(info).takeUnretainedValue().receive(type: type, event: event)
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: swallowing ? .defaultTap : .listenOnly,
                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw HotkeyError.eventSourceUnavailable }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
        self.handler = handler
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        handler = nil
    }

    /// Returns `true` when the event must be swallowed.
    fileprivate func receive(type: CGEventType, event: CGEvent) -> Bool {
        let raw: RawKeyEvent
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            let kind: RawKeyEvent.Kind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
            raw = RawKeyEvent(
                kind: kind, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: Int(truncatingIfNeeded: event.flags.rawValue),
                isAutorepeat: kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let h = handler
            lock.unlock()
            // Events were lost while disabled; release anything held so push-to-talk cannot get stuck.
            _ = h?(RawKeyEvent(kind: .reset, keyCode: 0, modifiers: 0))
            return false
        default: return false
        }
        lock.lock()
        let h = handler
        lock.unlock()
        let consumed = h?(raw) ?? false
        return consumed && swallowing
    }
}

/// Fallback ``HotkeyEventSource`` using `NSEvent` global monitors (also gated by Input Monitoring). Cannot swallow.
public final class NSEventHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: Any?
    public var capture: HotkeyCapture { .listenOnly }

    public init() {}

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let kind: RawKeyEvent.Kind =
                switch event.type {
                case .keyDown: .keyDown
                case .keyUp: .keyUp
                default: .flagsChanged
                }
            let isRepeat = event.type == .keyDown && event.isARepeat
            _ = handler(
                RawKeyEvent(
                    kind: kind, keyCode: event.keyCode, modifiers: Int(event.modifierFlags.rawValue), isAutorepeat: isRepeat))
        }
        guard let m else { throw HotkeyError.eventSourceUnavailable }
        monitor = m
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Tries each source in order and keeps the first that starts: active CGEventTap (swallows the shortcut), listen-only
/// CGEventTap, then an NSEvent monitor.
public final class FallbackHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let sources: [any HotkeyEventSource]
    private let lock = NSLock()
    private var active: (any HotkeyEventSource)?

    public init(
        sources: [any HotkeyEventSource] = [
            CGEventTapHotkeySource(swallowing: true), CGEventTapHotkeySource(), NSEventHotkeySource(),
        ]
    ) { self.sources = sources }

    public var capture: HotkeyCapture {
        lock.lock()
        defer { lock.unlock() }
        return active?.capture ?? .unavailable
    }

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        for s in sources {
            if (try? s.start(handler: handler)) != nil {
                active = s
                return
            }
        }
        throw HotkeyError.eventSourceUnavailable
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        active?.stop()
        active = nil
    }
}
