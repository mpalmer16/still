import Foundation

@main
struct WritingLocationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("still-location-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("renamed")
        let fallback = root.appendingPathComponent("fallback")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("untouched database placeholder".utf8).write(to: original.appendingPathComponent("still.db"))
        let bookmark = try WritingLocation.bookmark(for: original)
        let initial = try WritingLocation.resolve(override: nil, bookmark: bookmark, legacyPath: nil, fallback: fallback)
        precondition(initial.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
        let profile = WritingLocation.profile(for: original)
        precondition(profile == WritingLocation.profile(for: original))
        let legacy = try WritingLocation.resolve(override: nil, bookmark: nil, legacyPath: original.path, fallback: fallback)
        precondition(legacy.path == original.path)
        try fm.moveItem(at: original, to: moved)
        let relocated = try WritingLocation.resolve(override: nil, bookmark: bookmark, legacyPath: original.path, fallback: fallback)
        precondition(relocated.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        precondition(WritingLocation.profile(for: moved, remembered: profile.uuidString) == profile)
        let words = try Data(contentsOf: relocated.appendingPathComponent("still.db"))
        precondition(words == Data("untouched database placeholder".utf8))
        let explicit = try WritingLocation.resolve(override: fallback.path, bookmark: bookmark, legacyPath: original.path, fallback: root)
        precondition(explicit.path == fallback.path)
        let fresh = try WritingLocation.resolve(override: nil, bookmark: nil, legacyPath: nil, fallback: fallback)
        precondition(fresh == fallback)
        do {
            _ = try WritingLocation.resolve(override: nil, bookmark: Data("invalid bookmark".utf8), legacyPath: moved.path, fallback: fallback)
            fatalError("An unavailable chosen folder must not silently open a different collection")
        } catch is WritingLocation.Unavailable {}
        do {
            _ = try WritingLocation.resolve(override: nil, bookmark: nil, legacyPath: original.path, fallback: fallback)
            fatalError("A missing legacy collection must not silently become empty")
        } catch is WritingLocation.Unavailable {}
        print("Writing folder checks passed: explicit override, legacy adoption, rename recovery, stable profile, missing-folder refusal, and unchanged words.")
    }
}
