import Foundation
import Testing

@testable import ParancoCore

/// Tests written from a security review, one per finding.
///
/// The review's headline: a program holding Full Disk Access that takes its
/// instructions from a file any same-user process can write is a universal
/// bypass of the protection it was meant to respect. Every test here pins one
/// of the ways that was true, so that it cannot quietly become true again.
struct Scratch {
    static func dir(_ name: String = "d") -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".paranco-tests/sec-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func file(_ folder: URL, _ name: String, bytes: Int = 64, mode: Int = 0o644) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes),
                                       attributes: [.posixPermissions: mode])
        return url
    }
    /// A route whose source is the test folder, registered under a test id so the
    /// allowlist can be exercised without touching a real protected folder.
    static func route(source: URL, destination: URL) -> Route {
        // One identifier per folder: the tests run in parallel and would
        // otherwise resolve each other's sources.
        let id = "test-\(source.lastPathComponent)"
        Source.registerForTesting(id: id, folder: source)
        return Route(name: "t", sourceID: id, destination: destination)
    }
}

/// Finding 1: the source must resolve through the allowlist compiled into the
/// binary, never through a path in the config file.
struct AllowlistTests {
    @Test("a route naming an unknown source lifts nothing and says why")
    func unknownSourceIsRefused() {
        let dst = Scratch.dir("dst")
        defer { try? FileManager.default.removeItem(at: dst) }
        let route = Route(name: "x", sourceID: "not-a-real-source", destination: dst)
        let report = Lift.run(route, settling: 0)
        #expect(report.copied == 0)
        #expect(report.refused?.contains("not on the list") == true)
    }

    @Test("a route file cannot carry a source path at all")
    func fileCarriesIdsOnly() throws {
        // The attack was: write routes.json with "source": "file:///Users/x/Library/Messages".
        // The model has no such field now, so decoding must ignore or reject it.
        let dir = Scratch.dir("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostile = """
        [{"id":"5E1A2C3B-0000-4000-8000-000000000000","name":"x","enabled":true,
          "extensions":[],"sourceID":"voice-memos",
          "source":"file:///Users/nobody/Library/Messages/",
          "destination":"file:///tmp/exfil/"}]
        """
        let file = dir.appendingPathComponent("routes.json")
        try hostile.write(to: file, atomically: true, encoding: .utf8)
        let routes = try Routes.load(from: file)
        #expect(routes.count == 1)
        #expect(routes[0].source?.path.contains("Messages") == false)
        #expect(routes[0].source == Source.voiceMemos.folder)
    }

    @Test("every allowlisted source is a folder under the user's home")
    func allowlistIsBounded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for source in Source.builtIn {
            #expect(source.folder.path.hasPrefix(home))
        }
    }
}

/// Finding 2: the destination is where a privileged process writes, so it must be
/// exactly the folder the person chose and nothing it could be made to point at.
struct DestinationTests {
    @Test("a destination with .. in it is refused")
    func dotDot() {
        let src = Scratch.dir("src"), base = Scratch.dir("base")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: base) }
        Scratch.file(src, "a.m4a")
        let escaping = base.appendingPathComponent("inner/../../escaped")
        let report = Lift.run(Scratch.route(source: src, destination: escaping), settling: 0)
        #expect(report.copied == 0)
        #expect(report.refused != nil)
    }

    @Test("a destination that is a symlink is refused, so nothing is written through it")
    func symlinkDestination() throws {
        let src = Scratch.dir("src"), real = Scratch.dir("real"), link = Scratch.dir("holder").appendingPathComponent("link")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: real)
                try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }
        Scratch.file(src, "a.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let report = Lift.run(Scratch.route(source: src, destination: link), settling: 0)
        #expect(report.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("a.m4a").path))
    }

    @Test("a symlink anywhere in the destination's path is refused")
    func symlinkParent() throws {
        let src = Scratch.dir("src"), real = Scratch.dir("real"), holder = Scratch.dir("holder")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: real)
                try? FileManager.default.removeItem(at: holder) }
        Scratch.file(src, "a.m4a")
        let link = holder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let report = Lift.run(Scratch.route(source: src, destination: link.appendingPathComponent("deeper")), settling: 0)
        #expect(report.copied == 0)
    }

    @Test("a destination outside the home folder is refused")
    func outsideHome() {
        let src = Scratch.dir("src")
        defer { try? FileManager.default.removeItem(at: src) }
        Scratch.file(src, "a.m4a")
        // /tmp is world-readable and outside home; the report used it as the exfil example.
        let report = Lift.run(Scratch.route(source: src, destination: URL(fileURLWithPath: "/tmp/paranco-exfil")), settling: 0)
        #expect(report.copied == 0)
        #expect(report.refused?.contains("home") == true)
    }

    @Test("a destination inside the source is refused")
    func insideSource() {
        let src = Scratch.dir("src")
        defer { try? FileManager.default.removeItem(at: src) }
        Scratch.file(src, "a.m4a")
        let report = Lift.run(Scratch.route(source: src, destination: src.appendingPathComponent("copies")), settling: 0)
        #expect(report.copied == 0)
    }

    @Test("iCloud Drive is refused as a destination")
    func iCloud() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/paranco-test")
        guard case .failure = Destination.validate(icloud) else {
            Issue.record("iCloud Drive was accepted as a destination"); return
        }
    }
}

/// Findings 5 and 8: what a copied file looks like, and the swap in the gap.
struct CopyTests {
    @Test("a copied file is not executable and is private to the user")
    func permissions() throws {
        let src = Scratch.dir("src"), dst = Scratch.dir("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Scratch.file(src, "run.m4a", mode: 0o755)
        _ = Lift.run(Scratch.route(source: src, destination: dst), settling: 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: dst.appendingPathComponent("run.m4a").path)
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o111 == 0, "no execute bit survives the copy")
        #expect(mode & 0o077 == 0, "nobody but the user can read it")
    }

    @Test("the destination folder is created private to the user")
    func folderPermissions() throws {
        let src = Scratch.dir("src")
        let dst = Scratch.dir("parent").appendingPathComponent("inbox")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst.deletingLastPathComponent()) }
        Scratch.file(src, "a.m4a")
        _ = Lift.run(Scratch.route(source: src, destination: dst), settling: 0)
        let mode = (try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o077 == 0)
    }

    @Test("an existing target that is a symlink is not written through")
    func symlinkTarget() throws {
        // The race in finding 8: between the size check and the write, the target
        // name is turned into a symlink. The write must land in a fresh file that
        // replaces the link, never inside what the link points at.
        let src = Scratch.dir("src"), dst = Scratch.dir("dst"), elsewhere = Scratch.dir("elsewhere")
        defer { for u in [src, dst, elsewhere] { try? FileManager.default.removeItem(at: u) } }
        Scratch.file(src, "a.m4a", bytes: 500)
        let victim = elsewhere.appendingPathComponent("a.m4a")
        Scratch.file(elsewhere, "a.m4a", bytes: 1)
        try FileManager.default.createSymbolicLink(at: dst.appendingPathComponent("a.m4a"), withDestinationURL: victim)

        let report = Lift.run(Scratch.route(source: src, destination: dst), settling: 0)
        #expect(report.copied == 1)
        let victimSize = try victim.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(victimSize == 1, "the file behind the link is untouched")
        let landed = dst.appendingPathComponent("a.m4a")
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: landed.path)) != nil
        #expect(!isLink, "the link was replaced by a real file")
    }

    @Test("extended attributes are not carried across")
    func noXattrs() throws {
        let src = Scratch.dir("src"), dst = Scratch.dir("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let file = Scratch.file(src, "a.m4a")
        _ = "x".withCString { setxattr(file.path, "user.paranco.test", $0, 1, 0, 0) }
        _ = Lift.run(Scratch.route(source: src, destination: dst), settling: 0)
        let size = getxattr(dst.appendingPathComponent("a.m4a").path, "user.paranco.test", nil, 0, 0, 0)
        #expect(size < 0, "the copy carries no attributes from the source")
    }
}

/// Finding 7: what goes into the log.
struct LogTests {
    @Test("control characters are stripped from anything logged")
    func sanitised() {
        // The escape byte goes; the printable text after it stays and is harmless.
        #expect(Agent.sanitised("memo\nFAKE LINE\r\u{1B}[0m.m4a") == "memo FAKE LINE [0m.m4a")
    }
}

/// Findings from the second review: the ones that survived the first fix.
struct SecondReviewTests {
    @Test("a destination renamed away and replaced by a symlink is not written through")
    func pinnedDirectorySurvivesRename() throws {
        // The demonstrated attack, in the form that keeps the folder alive:
        // rename the validated folder aside during the settle wait and put a
        // link in its place. The copy goes through the descriptor opened before
        // the wait, so it lands in the folder that was checked, wherever that
        // folder has been moved to, and never where the link points.
        let src = Scratch.dir("src"), dst = Scratch.dir("dst"), elsewhere = Scratch.dir("elsewhere")
        let aside = dst.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString)")
        defer { for u in [src, dst, elsewhere, aside] { try? FileManager.default.removeItem(at: u) } }
        let source = Scratch.file(src, "memo.m4a", bytes: 300)

        let dirfd = open(dst.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(dirfd >= 0)
        defer { close(dirfd) }

        try FileManager.default.moveItem(at: dst, to: aside)
        try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: elsewhere)

        try Lift.copySafely(from: source, named: "memo.m4a", into: dirfd)

        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("memo.m4a").path),
                "nothing landed where the link points")
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("memo.m4a").path),
                "the file landed in the folder that was opened")
    }

    @Test("a destination deleted and replaced by a symlink makes the copy fail, not follow")
    func pinnedDirectorySurvivesDelete() throws {
        // The other form: delete the folder outright. A directory that is gone
        // from the namespace refuses new entries, so the copy fails and nothing
        // is written anywhere. Failing is the right outcome; following is not.
        let src = Scratch.dir("src"), dst = Scratch.dir("dst"), elsewhere = Scratch.dir("elsewhere")
        defer { for u in [src, dst, elsewhere] { try? FileManager.default.removeItem(at: u) } }
        let source = Scratch.file(src, "memo.m4a", bytes: 300)

        let dirfd = open(dst.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(dirfd >= 0)
        defer { close(dirfd) }

        try FileManager.default.removeItem(at: dst)
        try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: elsewhere)

        #expect(throws: (any Error).self) {
            try Lift.copySafely(from: source, named: "memo.m4a", into: dirfd)
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("memo.m4a").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("a different spelling of ~/Library is still ~/Library")
    func caseInsensitiveLibrary() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for spelling in ["library", "LIBRARY", "LiBrArY"] {
            let url = home.appendingPathComponent("\(spelling)/Caches/paranco-test")
            guard case .failure(let why) = Destination.validate(url) else {
                Issue.record("\(spelling) was accepted as a destination"); continue
            }
            #expect(why.message.contains("Library"))
        }
    }

    @Test("a source reached through a symbolic link is refused")
    func symlinkedSource() throws {
        let real = Scratch.dir("real-src"), holder = Scratch.dir("holder"), dst = Scratch.dir("dst")
        defer { for u in [real, holder, dst] { try? FileManager.default.removeItem(at: u) } }
        Scratch.file(real, "memo.m4a")
        let link = holder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let report = Lift.run(Scratch.route(source: link, destination: dst), settling: 0)
        #expect(report.copied == 0)
        #expect(report.refused?.contains("symbolic link") == true)
    }

    @Test("a destination with a control character in a component is refused")
    func controlCharacters() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for bad in ["memos\nfake", "memos\u{1B}[0m", "memos\u{85}x"] {
            guard case .failure = Destination.validate(home.appendingPathComponent(bad)) else {
                Issue.record("\(bad.debugDescription) was accepted"); continue
            }
        }
    }

    @Test("C1 controls and the Unicode line separators are stripped too")
    func c1Sanitised() {
        #expect(Agent.sanitised("a\u{85}b\u{2028}c\u{2029}d") == "a b c d")
    }
}
