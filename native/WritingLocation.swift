import Foundation
import CryptoKit

// A filesystem bookmark follows a chosen folder when it is renamed or moved.
// The WebKit identity is retained separately so unsent recovery follows it too.
enum WritingLocation {
    static let bookmarkKey = "Still.writingFolderBookmark"
    static let profileKey = "Still.writingFolderProfile"

    struct Unavailable: LocalizedError {
        let errorDescription: String? = "Still could not find its remembered writing folder. Reconnect its drive or choose the folder containing your still.db."
    }

    static func resolve(override: String?, bookmark: Data?, legacyPath: String?, fallback: URL) throws -> URL {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        if let bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                    options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                  isDirectory(resolved) else { throw Unavailable() }
            return resolved
        }
        if let legacyPath, !legacyPath.isEmpty {
            let legacy = URL(fileURLWithPath: legacyPath, isDirectory: true)
            guard isDirectory(legacy), FileManager.default.fileExists(atPath: legacy.appendingPathComponent("still.db").path)
            else { throw Unavailable() }
            return legacy
        }
        return fallback
    }

    static func bookmark(for directory: URL) throws -> Data {
        guard isDirectory(directory) else { throw Unavailable() }
        return try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func profile(for directory: URL, remembered: String? = nil) -> UUID {
        if let remembered, let profile = UUID(uuidString: remembered) { return profile }
        var bytes = Array(SHA256.hash(data: Data(directory.resolvingSymlinksInPath().path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
