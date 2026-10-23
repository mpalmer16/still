import Foundation

enum CorrespondenceNavigationPolicy {
    enum Decision: Equatable {
        case allowInApp
        case openExternal
        case cancel
    }

    static func decide(_ url: URL?, localPort: Int, userInitiated: Bool) -> Decision {
        guard let url else { return .cancel }
        if isLocalRoom(url, port: localPort) {
            return .allowInApp
        }
        guard userInitiated, isExternalWebURL(url) else { return .cancel }
        return .openExternal
    }

    static func isLocalRoom(_ url: URL, port: Int) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1"].contains(host),
              url.port == port,
              url.user == nil,
              url.password == nil else { return false }
        return true
    }

    static func isManuscriptExport(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count == 5 && parts[0] == "correspondence" && parts[1] == "packets" &&
            !parts[2].isEmpty && parts[3] == "export" && ["txt", "docx"].contains(parts[4])
    }

    static func shouldDownloadResponse(url: URL?, localPort: Int, statusCode: Int?,
                                       contentDisposition: String?) -> Bool {
        guard let url, isLocalRoom(url, port: localPort), isManuscriptExport(url),
              let statusCode, (200..<300).contains(statusCode),
              contentDisposition?.lowercased().contains("attachment") == true else { return false }
        return true
    }

    private static func isExternalWebURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              !isLoopbackHost(host),
              url.user == nil,
              url.password == nil else { return false }
        return true
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        let host = value.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") ||
            host == "::1" || host == "[::1]" || host == "127.0.0.1" || host.hasPrefix("127.")
    }
}
