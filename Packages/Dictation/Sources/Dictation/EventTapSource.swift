import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Production ``HotkeyEventSource`` backed by a listen-only `CGEventTap` on the main run loop.
///
/// Listen-only taps need Input Monitoring; they never modify or swallow events, so a stuck handler cannot freeze
/// the user's keyboard. If the OS refuses to create the tap, `start` throws and callers degrade gracefully.
/// Unverified without real TCC grants (see the T19 report).
public final class CGEventTapHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RawKeyEvent) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tap == nil else {
            self.handler = handler
            return
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info { Unmanaged<CGEventTapHotkeySource>.fromOpaque(info).takeUnretainedValue().receive(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
        handler = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        let kind: RawKeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.unlock()
            return
        default: return
        }
        let raw = RawKeyEvent(
            kind: kind, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: Int(truncatingIfNeeded: event.flags.rawValue),
            isAutorepeat: kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        lock.lock()
        let h = handler
        lock.unlock()
        h?(raw)
    }
}

/// Fallback ``HotkeyEventSource`` using `NSEvent` global monitors (also gated by Input Monitoring).
public final class NSEventHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: Any?

    public init() {}

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Void) throws {
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
            handler(
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

/// Tries each source in order and keeps the first that starts (CGEventTap first, NSEvent monitor second).
public final class FallbackHotkeySource: HotkeyEventSource, @unchecked Sendable {
    private let sources: [any HotkeyEventSource]
    private let lock = NSLock()
    private var active: (any HotkeyEventSource)?

    public init(sources: [any HotkeyEventSource] = [CGEventTapHotkeySource(), NSEventHotkeySource()]) { self.sources = sources }

    public func start(handler: @escaping @Sendable (RawKeyEvent) -> Void) throws {
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
