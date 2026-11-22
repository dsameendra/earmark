import AVFoundation
import AppCore
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import UserNotifications

/// The production `PermissionProbing`, backed by the real OS APIs. Not unit-tested (it prompts); the logic lives in
/// `PermissionsService`, which is tested through a fake probe.
public struct SystemPermissionProbe: PermissionProbing {
    public init() {}

    public func rawState(_ kind: PermissionKind) async -> RawPermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .systemAudioRecording:
            return Self.audioCapturePreflight()
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    public func performRequest(_ kind: PermissionKind) async -> RawPermissionState {
        switch kind {
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            // The literal avoids touching the non-Sendable global `kAXTrustedCheckOptionPrompt` under strict concurrency.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        case .systemAudioRecording:
            return await Task.detached { Self.probeAudioTap() }.value
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .granted : .denied
        }
    }

    public func inputMonitoringGranted() -> Bool { CGPreflightListenEventAccess() }
    public func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    // MARK: System Audio Recording (kTCCServiceAudioCapture)

    /// There is no public status API for process taps. Creating a tap prompts the first time and fails once denied,
    /// so a tap create-and-destroy is the request probe. A tap can also be created while denied and then deliver
    /// silence; that case is reported through `PermissionsService.reportSilentDenial`.
    static func probeAudioTap() -> RawPermissionState {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Earmark permission probe"
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return .denied }
        AudioHardwareDestroyProcessTap(tapID)
        return .granted
    }

    /// Non-prompting preflight through the system TCC library when it exposes the symbol (it is not public API,
    /// so a missing symbol degrades to `.indeterminate` and the service falls back to the last observed outcome).
    static func audioCapturePreflight() -> RawPermissionState {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
            let symbol = dlsym(handle, "TCCAccessPreflight")
        else { return .indeterminate }
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .indeterminate
        }
    }
}
