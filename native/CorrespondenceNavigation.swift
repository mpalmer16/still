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

    static func isJSONSchemaDownload(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count == 3 && parts[0] == "correspondence" &&
            ["calendar", "funding"].contains(parts[1]) && parts[2] == "schema"
    }

    static func isAllowedDownload(_ url: URL) -> Bool {
        isManuscriptExport(url) || isJSONSchemaDownload(url)
    }

    static func importPanelCopy(for url: URL) -> (title: String, message: String) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "correspondence" else {
            return ("Import JSON", "Choose a JSON file to review before adding anything in Still.")
        }

        switch parts[1] {
        case "funding":
            return ("Import Funding", "Choose a funding JSON file to review. No funding records are added until you confirm in Still.")
        case "calendar":
            return ("Import Calendar Events", "Choose a calendar JSON file to review. No events are added until you confirm in Still.")
        case "journals":
            return ("Import Places", "Choose a JSON file to review. No places are added until you confirm in Still.")
        default:
            return ("Import JSON", "Choose a JSON file to review before adding anything in Still.")
        }
    }

    static func shouldDownloadResponse(url: URL?, localPort: Int, statusCode: Int?,
                                       contentDisposition: String?) -> Bool {
        guard let url, isLocalRoom(url, port: localPort), isAllowedDownload(url),
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
