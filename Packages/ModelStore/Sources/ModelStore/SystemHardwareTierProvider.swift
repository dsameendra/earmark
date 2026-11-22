import AppCore
import Dispatch
import Foundation
import IOKit.ps

/// Real ``HardwareTierProviding``: chip and memory via `sysctl`, memory pressure via `DispatchSource`,
/// thermal state via `ProcessInfo`, power source via IOKit. All signals are event driven (no polling).
public struct SystemHardwareTierProvider: HardwareTierProviding {
    public let profile: HardwareProfile

    /// - Parameters:
    ///   - memoryBytes: override for tests; defaults to `ProcessInfo.physicalMemory`.
    ///   - chip: override of the CPU brand string.
    ///   - performanceCores: override of the performance-core count.
    public init(memoryBytes: UInt64? = nil, chip: String? = nil, performanceCores: Int? = nil) {
        let memory = memoryBytes ?? ProcessInfo.processInfo.physicalMemory
        self.profile = HardwareProfile(
            chip: chip ?? Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            memoryBytes: memory,
            performanceCores: performanceCores ?? Self.sysctlInt("hw.perflevel0.physicalcpu")
                ?? ProcessInfo.processInfo.activeProcessorCount,
            tier: HardwareProfile.tier(forMemoryBytes: memory))
    }

    public func memoryPressure() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { continuation.yield() }
            let box = SourceBox(source)
            continuation.onTermination = { _ in box.cancel() }
            source.resume()
        }
    }

    public func thermalPressure() -> AsyncStream<ThermalPressure> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
            ) { _ in
                continuation.yield(Self.pressure(for: ProcessInfo.processInfo.thermalState))
            }
            let box = ObserverBox(token)
            continuation.onTermination = { _ in box.remove() }
        }
    }

    public func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    /// Maps `ProcessInfo.ThermalState` onto ``ThermalPressure``.
    public static func pressure(for state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

private final class SourceBox: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure
    init(_ source: any DispatchSourceMemoryPressure) { self.source = source }
    func cancel() { source.cancel() }
}

private final class ObserverBox: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    func remove() { NotificationCenter.default.removeObserver(token) }
}
