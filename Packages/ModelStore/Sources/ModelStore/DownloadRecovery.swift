import Foundation

/// How many times, and how patiently, a failed model request is retried (SCR-011).
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts including the first. `1` disables retrying.
    public var maxAttempts: Int
    /// Delay before the first retry; doubles for each further retry (capped at 30 s).
    public var baseDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .seconds(1)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
    }

    public static let standard = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: .zero)

    /// Backoff before retry number `attempt` (1 = the first retry).
    public func delay(afterAttempt attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 1, 0), 5)
        return min(baseDelay * factor, .seconds(30))
    }
}

/// What went wrong with a download or manifest request, in terms the UI and the retry logic care about.
public enum DownloadFailureKind: Sendable, Equatable {
    /// No usable internet connection. Not retried automatically: it needs the user.
    case offline
    /// Connection dropped or timed out. Retried with backoff.
    case network
    /// HTTP 429 or 5xx. Retried with backoff.
    case server(status: Int)
    /// Any other HTTP refusal (401/403/404/410...). On a resumed transfer this means the signed CDN link expired.
    case refused(status: Int)
    case other(String)

    public init(classifying error: any Error) {
        let error = (error as? DownloadFailedError)?.underlying ?? error
        if let http = error as? DownloadHTTPError {
            self = (http.status == 429 || http.status >= 500) ? .server(status: http.status) : .refused(status: http.status)
        } else if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: self = .offline
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                .secureConnectionFailed:
                self = .network
            default: self = .other(url.localizedDescription)
            }
        } else {
            self = .other(error.localizedDescription)
        }
    }

    /// Worth retrying automatically.
    public var isTransient: Bool {
        switch self {
        case .network, .server: true
        case .offline, .refused, .other: false
        }
    }

    /// Resume data is still valid after this failure (the file is fine, the network was not).
    var preservesResumeData: Bool {
        switch self {
        case .offline, .network, .server: true
        case .refused, .other: false
        }
    }

    /// Clear, user-facing text (stable strings; shown in the failed row).
    public var message: String {
        switch self {
        case .offline: DownloadMessage.offline
        case .network: "The connection was lost or timed out. Check your connection and retry."
        case .server(let status): "The model server is temporarily unavailable (HTTP \(status)). Try again in a few minutes."
        case .refused(let status): "The server refused the download (HTTP \(status)). Retry to start the file again."
        case .other(let text): text
        }
    }
}

public enum DownloadMessage {
    /// Shown when a download cannot start or continue because there is no internet connection.
    public static let offline = "You appear to be offline. Connect to the internet and retry the download."
}
