import Foundation

/// The launchd agent that runs the routes on its own.
///
/// It runs the application bundle's own executable with `--agent`, not a
/// separate binary, so Full Disk Access is granted to one thing and used by
/// both the window and the agent. Started by launchd it has its own identity,
/// which is the whole reason it works: started from a terminal it would be the
/// terminal's permission being tested.
///
/// The plist lives in a folder the user can write, so another process running
/// as the user can rewrite it. What that gains them is a persistence foothold
/// they already had, not the permission: with an ad-hoc signature the grant is
/// bound to the hash of this binary, and a substituted binary runs without it.
public enum Agent {
    public static let label = "dev.nerelli.paranco"

    public static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var log: URL {
        Routes.directory.appendingPathComponent("agent.log")
    }

    /// Kept under this many bytes. A route that fails every five minutes for a
    /// month would otherwise fill the disk one line at a time.
    public static let logLimit = 1_000_000

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plist.path)
    }

    /// Anything that ends up in the log passes through here. A file name or a
    /// route name with a newline in it could otherwise forge a line, and a
    /// terminal escape could repaint whatever shows the log.
    public static func sanitised(_ text: String) -> String {
        let cleaned = text.unicodeScalars.map { scalar -> String in
            let v = scalar.value
            // C0 and C1 controls, and the two Unicode line separators, which
            // some readers treat as a line break even though they are not one.
            if v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 { return " " }
            return String(scalar)
        }.joined()
        return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Drop the oldest part of the log once it is past the limit.
    public static func trimLog() {
        guard let data = try? Data(contentsOf: log), data.count > logLimit else { return }
        let tail = data.suffix(logLimit / 2)
        if let cut = tail.firstIndex(of: UInt8(ascii: "\n")) {
            try? tail[tail.index(after: cut)...].write(to: log)
        }
    }

    public static func install(executable: URL, interval: Int = 300) throws {
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Routes.directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(executable.path)</string><string>--agent</string></array>
            <key>StartInterval</key><integer>\(interval)</integer>
            <key>RunAtLoad</key><true/>
            <key>StandardOutPath</key><string>\(log.path)</string>
            <key>StandardErrorPath</key><string>\(log.path)</string>
        </dict>
        </plist>
        """
        try xml.write(to: plist, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        // Read it back. A plist that does not say what was just written is not
        // one to hand to launchd.
        guard (try? String(contentsOf: plist, encoding: .utf8)) == xml else {
            throw AgentError.launchctl("the agent file did not read back as written")
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        guard result.status == 0 else {
            throw AgentError.launchctl(result.output)
        }
    }

    public static func remove() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public enum AgentError: LocalizedError {
        case launchctl(String)
        public var errorDescription: String? {
            switch self {
            case .launchctl(let out):
                return "launchctl refused: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
