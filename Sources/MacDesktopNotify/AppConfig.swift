import Foundation

enum AppConfig {
    static let appName = "MacDesktopNotify"
    static let apiHost = "127.0.0.1"
    static let apiPort: UInt16 = {
        guard let raw = ProcessInfo.processInfo.environment["MAC_DESKTOP_NOTIFY_PORT"],
              let port = UInt16(raw)
        else { return 18080 }
        return port
    }()

    static let apiToken: String? = {
        let token = ProcessInfo.processInfo.environment["MAC_DESKTOP_NOTIFY_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }()

    static var apiBaseURL: String {
        "http://\(apiHost):\(apiPort)"
    }

    static var notifyEndpoint: String {
        "\(apiBaseURL)/notify"
    }

    static var notificationsEndpoint: String {
        "\(apiBaseURL)/notifications"
    }

    static var healthEndpoint: String {
        "\(apiBaseURL)/health"
    }

    static var websocketEndpoint: String {
        "ws://\(apiHost):\(apiPort)/ws"
    }
}
