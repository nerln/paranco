import Foundation

/// The folders this program is allowed to read. All of them. Compiled in.
///
/// This list is the whole security model. A program holding Full Disk Access
/// that takes its sources from a configuration file is a bypass of the
/// protection it claims to respect: any process running as the same user can
/// write that file and have the privileged agent copy Messages, Mail or Safari
/// into a folder it can read. So a route never carries a path to its source. It
/// carries an identifier, and the identifier resolves here or nowhere.
///
/// Adding a source means editing this file and rebuilding, which with an ad-hoc
/// signature also means granting the permission again. That is the intended
/// cost: a reviewer sees the folder being added, and a person consents to it.
///
/// Every entry is a folder under the user's own home holding the user's own
/// data, protected by macOS against other software rather than against the
/// user. Mail, Messages and Safari are not here and will not be added.
public struct Source: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let folder: URL
    public let extensions: Set<String>
    public let note: String

    static let home = FileManager.default.homeDirectoryForCurrentUser

    public static let voiceMemos = Source(
        id: "voice-memos", name: "Voice Memos",
        folder: home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
        extensions: ["m4a", "mp3", "wav", "aiff", "aifc", "caf"],
        note: "Everything recorded with the Voice Memos app, on this Mac or synced to it.")

    /// The allowlist. Order is the order the window shows.
    public static let builtIn: [Source] = [voiceMemos]

    public static var all: [Source] { builtIn + testing }

    /// The only way to resolve an identifier, used by every lift.
    public static func resolve(_ id: String) -> Source? {
        all.first { $0.id == id }
    }

    // A registration hook that exists only in debug builds, so the tests can
    // exercise the allowlist against a throwaway folder. A release build, which
    // is the only kind that ever holds the permission, has no such door.
    #if DEBUG
    // Tests run in parallel, so the registry is guarded; without the lock two
    // tests registering at once tore the array and a route resolved to the
    // other test's folder.
    nonisolated(unsafe) private static var registry: [Source] = []
    private static let registryLock = NSLock()
    private static var testing: [Source] {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry
    }
    public static func registerForTesting(id: String, folder: URL) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry.removeAll { $0.id == id }
        registry.append(Source(id: id, name: id, folder: folder, extensions: [], note: "test"))
    }
    #else
    private static let testing: [Source] = []
    #endif
}
