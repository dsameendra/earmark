import AppCore
import Foundation
import Synchronization

@testable import AudioCapture

/// Records everything a stream yields so tests can wait for conditions with a timeout (never an unbounded wait).
final class Recorder<Element: Sendable>: Sendable {
    private final class Store: Sendable {
        let lock = Mutex<[Element]>([])
    }

    private let store = Store()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Element>) {
        let store = self.store
        let created = Task {
            for await element in stream { store.lock.withLock { $0.append(element) } }
        }
        task.withLock { $0 = created }
    }

    var values: [Element] { store.lock.withLock { $0 } }

    /// Polls until `predicate` holds for the recorded values or `timeout` elapses. Returns whether it held.
    @discardableResult
    func wait(timeout: Duration = .seconds(3), until predicate: @Sendable ([Element]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(values) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate(values)
    }

    /// Waits for the stream to finish.
    func waitForFinish(timeout: Duration = .seconds(3)) async -> Bool {
        guard let task = task.withLock({ $0 }) else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

final class FakeDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private struct State {
        var devices: [AudioDevice]
        var defaultInputID: String?
        var continuations: [AsyncStream<Void>.Continuation] = []
    }

    private let state: Mutex<State>

    init(devices: [AudioDevice], defaultInputID: String?) {
        state = Mutex(State(devices: devices, defaultInputID: defaultInputID))
    }

    func devices() async -> [AudioDevice] { state.withLock { $0.devices } }

    func defaultInput() async -> AudioDevice? {
        state.withLock { state in state.devices.first { $0.id == state.defaultInputID } }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }

    /// Updates the fake hardware and fires a change notification, like a Core Audio property listener.
    func update(devices: [AudioDevice]? = nil, defaultInputID: String?? = nil) {
        let targets = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            if let devices { state.devices = devices }
            if let defaultInputID { state.defaultInputID = defaultInputID }
            return state.continuations
        }
        for continuation in targets { continuation.yield() }
    }
}

final class StubPermissions: PermissionsServicing, @unchecked Sendable {
    private let state: Mutex<(status: PermissionStatus, requests: Int, grantOnRequest: Bool)>
    init(status: PermissionStatus, grantOnRequest: Bool = true) { state = Mutex((status, 0, grantOnRequest)) }
    var requestCount: Int { state.withLock { $0.requests } }
    func status(_ kind: PermissionKind) async -> PermissionStatus { state.withLock { $0.status } }
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        state.withLock {
            $0.requests += 1
            if $0.status == .notDetermined { $0.status = $0.grantOnRequest ? .granted : .denied }
            return $0.status
        }
    }
    func settingsURL(for kind: PermissionKind) -> URL { URL(string: "x-apple.systempreferences:")! }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { $0.finish() } }
}

enum TestDevices {
    static let builtIn = AudioDevice(id: "builtin", name: "MacBook Pro Microphone", isInput: true, isOutput: false)
    static let usb = AudioDevice(id: "usb", name: "USB Mic", isInput: true, isOutput: false)
    static let airpods = AudioDevice(id: "airpods", name: "AirPods", isInput: true, isOutput: true, isBluetooth: true)
}

/// Fast configuration for tests: short silence window, tight polling.
func testConfiguration(silenceWindow: Double = 0.3) -> CaptureConfiguration {
    CaptureConfiguration(chunkSeconds: 0.1, silenceWindowSeconds: silenceWindow, pollInterval: .milliseconds(2))
}

func sine(count: Int, rate: Double, frequency: Double = 440, amplitude: Float = 0.5, startIndex: Int = 0) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double(startIndex + $0) / rate)) }
}
