import Foundation

/// One path data is allowed to travel: from one allowlisted source to one
/// ordinary folder of the person's choosing.
///
/// The source is an identifier, not a path. See Source for why: a route file
/// that could name any folder would turn the privileged agent into a copier for
/// whoever can write that file, and any process running as the user can.
public struct Route: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Resolved through Source.resolve, or the route lifts nothing.
    public var sourceID: String
    /// An ordinary folder under the home directory. Checked by Destination before
    /// a single byte is written.
    public var destination: URL
    /// Lower-case extensions without the dot. Empty means the source's own list.
    public var extensions: Set<String>
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, sourceID: String, destination: URL,
                extensions: Set<String> = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.destination = destination
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.enabled = enabled
    }

    /// The folder this route reads, if the identifier is on the list.
    public var source: URL? { Source.resolve(sourceID)?.folder }

    /// The extensions in force: the route's own, or the source's.
    public var effectiveExtensions: Set<String> {
        if !extensions.isEmpty { return extensions }
        return Source.resolve(sourceID)?.extensions ?? []
    }

    public func carries(_ url: URL) -> Bool {
        let ext = effectiveExtensions
        return ext.isEmpty || ext.contains(url.pathExtension.lowercased())
    }

    // Only these keys are read. A "source" key in the file, which an earlier
    // version and any attacker would write, is ignored by construction.
    enum CodingKeys: String, CodingKey {
        case id, name, sourceID, destination, extensions, enabled
    }
}

/// The routes on disk, and where they live.
public enum Routes {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/paranco")
    }
    public static var file: URL { directory.appendingPathComponent("routes.json") }

    /// The routes in the file, and a note for each entry that could not be one.
    ///
    /// Decoded one entry at a time. A file that decodes as a whole or not at all
    /// made every command die on one bad line, and the earliest format of this
    /// file named its source by path, which is exactly the thing the current
    /// one refuses to do. An old entry whose path is one of the allowlisted
    /// folders becomes that route; any other is dropped, and the note says so.
    public static func loadReporting(from url: URL = file) throws -> (routes: [Route], notes: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let entries = raw as? [Any] else {
            throw RoutesError.notAList
        }
        let decoder = JSONDecoder()
        var routes: [Route] = []
        var notes: [String] = []
        for (index, entry) in entries.enumerated() {
            guard var object = entry as? [String: Any] else {
                notes.append("entry \(index + 1) is not a route and was skipped")
                continue
            }
            if object["sourceID"] == nil, let path = object["source"] as? String,
               let sourceURL = URL(string: path) ?? URL(string: "file://" + path) {
                // The old format. Keep it only if it names a folder on the list.
                let wanted = sourceURL.standardizedFileURL.path
                if let match = Source.builtIn.first(where: { $0.folder.standardizedFileURL.path == wanted }) {
                    object["sourceID"] = match.id
                } else {
                    let name = (object["name"] as? String) ?? "entry \(index + 1)"
                    notes.append("\"\(name)\" named its source by path, which this version "
                                 + "does not allow, and it is not one of the listed folders; dropped")
                    continue
                }
            }
            object["source"] = nil
            do {
                let bytes = try JSONSerialization.data(withJSONObject: object)
                routes.append(try decoder.decode(Route.self, from: bytes))
            } catch {
                let name = (object["name"] as? String) ?? "entry \(index + 1)"
                notes.append("\"\(name)\" could not be read (\(error.localizedDescription)) and was skipped")
            }
        }
        return (routes, notes)
    }

    public static func load(from url: URL = file) throws -> [Route] {
        try loadReporting(from: url).routes
    }

    public enum RoutesError: LocalizedError {
        case notAList
        public var errorDescription: String? {
            switch self {
            case .notAList: return "routes.json is not a list of routes"
            }
        }
    }

    /// Written through a rename, so a reader never sees half a file, and kept
    /// private to the user. That does not stop a process running as the user,
    /// nothing on the filesystem can; what stops that process is that the file
    /// cannot name a folder the binary does not already allow.
    public static func save(_ routes: [Route], to url: URL = file) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(routes)
        let scratch = url.appendingPathExtension("part")
        try data.write(to: scratch, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        // The replacement keeps the mode of the file it replaced, so a file
        // that started out world-readable stayed that way. Set it after.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
