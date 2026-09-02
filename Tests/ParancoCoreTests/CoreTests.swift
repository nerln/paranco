import Foundation
import Testing

@testable import ParancoCore

/// Tests for the lines that move a file, and the ones that decide whether a
/// folder is empty or closed.
///
/// The second question is the one worth the most. macOS reports a protected
/// folder as empty when asked the wrong way, and a program built on "no files
/// here" then does nothing, for ever, for somebody with two hundred recordings.
struct Fixtures {
    static func folder(_ name: String = "f") -> URL {
        // Under the home folder, not the system temp directory: a destination
        // outside home is refused by design, and that is one of the tests.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".paranco-tests/\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func file(_ folder: URL, _ name: String, bytes: Int = 128) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        return url
    }

    /// A route whose source is the given folder, registered under a test id so
    /// the allowlist can be exercised without a real protected folder.
    static func route(from: URL, to: URL, extensions: Set<String> = []) -> Route {
        Source.registerForTesting(id: "fixture-\(from.lastPathComponent)", folder: from)
        return Route(name: "test", sourceID: "fixture-\(from.lastPathComponent)",
                     destination: to, extensions: extensions)
    }
}

struct AccessTests {
    @Test("a readable folder reports how many files it has")
    func readable() {
        let f = Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        Fixtures.file(f, "a.m4a"); Fixtures.file(f, "b.m4a")
        #expect(Access.check(f) == .readable(files: 2))
    }

    @Test("a folder that is not there is missing, not refused")
    func missing() {
        #expect(Access.check(Fixtures.folder().appendingPathComponent("nowhere")) == .missing)
    }

    @Test("a folder we cannot list is refused, with the sentence a person needs")
    func refused() throws {
        let f = Fixtures.folder("locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
                try? FileManager.default.removeItem(at: f) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        guard case .refused(let why) = Access.check(f) else { Issue.record("expected a refusal"); return }
        #expect(why.contains("Full Disk Access"))
        #expect(why.contains(f.path))
    }

    @Test("a folder with only subfolders in it counts zero files, not zero access")
    func subfoldersOnly() throws {
        let f = Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        try FileManager.default.createDirectory(at: f.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        #expect(Access.check(f) == .readable(files: 0))
    }
}

struct LiftTests {
    @Test("a new file is copied and reported")
    func copies() {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a", bytes: 1000)
        var events: [LiftEvent] = []
        let report = Lift.run(Fixtures.route(from: src, to: dst), settling: 0) { events.append($0) }
        #expect(report.copied == 1)
        #expect(report.bytes == 1000)
        #expect(events == [.copied("memo.m4a", bytes: 1000)])
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("memo.m4a").path))
    }

    @Test("the same file the second time is left alone")
    func idempotent() {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a")
        let route = Fixtures.route(from: src, to: dst)
        _ = Lift.run(route, settling: 0)
        let second = Lift.run(route, settling: 0)
        #expect(second.copied == 0)
        #expect(second.unchanged == 1)
    }

    @Test("a file that grew since it was copied is copied again")
    func recopiesWhenChanged() {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a", bytes: 100)
        let route = Fixtures.route(from: src, to: dst)
        _ = Lift.run(route, settling: 0)
        Fixtures.file(src, "memo.m4a", bytes: 5000)
        let again = Lift.run(route, settling: 0)
        #expect(again.copied == 1)
        let size = try? dst.appendingPathComponent("memo.m4a").resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 5000)
    }

    @Test("only the extensions the route carries come across")
    func filters() {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a"); Fixtures.file(src, "notes.txt"); Fixtures.file(src, "cover.PNG")
        let report = Lift.run(Fixtures.route(from: src, to: dst, extensions: ["m4a", "png"]), settling: 0)
        #expect(report.copied == 2)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("notes.txt").path))
    }

    @Test("the source is never written to")
    func sourceUntouched() throws {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a")
        let before = try FileManager.default.contentsOfDirectory(atPath: src.path).sorted()
        _ = Lift.run(Fixtures.route(from: src, to: dst), settling: 0)
        let after = try FileManager.default.contentsOfDirectory(atPath: src.path).sorted()
        #expect(before == after)
    }

    @Test("a refused source comes back as a refusal, not as nothing to do")
    func refusedSource() throws {
        let src = Fixtures.folder("locked"), dst = Fixtures.folder("dst")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: src.path)
                try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        Fixtures.file(src, "memo.m4a")
        let route = Fixtures.route(from: src, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        let report = Lift.run(route, settling: 0)
        #expect(report.refused?.contains("Full Disk Access") == true)
        #expect(report.copied == 0)
    }

    @Test("the destination is created if it is not there")
    func makesDestination() {
        let src = Fixtures.folder("src")
        let parent = Fixtures.folder("parent")
        let dst = parent.appendingPathComponent("deeper/inbox")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: parent) }
        Fixtures.file(src, "memo.m4a")
        let report = Lift.run(Fixtures.route(from: src, to: dst), settling: 0)
        #expect(report.copied == 1)
    }

    @Test("a symlink inside the source is not copied")
    func skipsSymlinkedSources() throws {
        let src = Fixtures.folder("src"), dst = Fixtures.folder("dst"), other = Fixtures.folder("other")
        defer { for u in [src, dst, other] { try? FileManager.default.removeItem(at: u) } }
        Fixtures.file(src, "plain.m4a")
        let secret = Fixtures.file(other, "secret.m4a")
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("link.m4a"), withDestinationURL: secret)
        let report = Lift.run(Fixtures.route(from: src, to: dst), settling: 0)
        #expect(report.copied == 1)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("link.m4a").path))
    }
}

struct RoutesTests {
    @Test("routes survive a round trip through the file")
    func roundTrip() throws {
        let dir = Fixtures.folder("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        let route = Route(name: "Voice Memos → Recordings", sourceID: "voice-memos",
                          destination: URL(fileURLWithPath: "/Users/nobody/Recordings"),
                          extensions: ["M4A", "wav"])
        try Routes.save([route], to: file)
        let back = try Routes.load(from: file)
        #expect(back == [route])
        #expect(back[0].extensions == ["m4a", "wav"])
    }

    @Test("the file is private to the user, even when it replaces a readable one")
    func privateFile() throws {
        let dir = Fixtures.folder("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        // Start from a world-readable file, which is what an earlier version left.
        FileManager.default.createFile(atPath: file.path, contents: Data("[]".utf8),
                                       attributes: [.posixPermissions: 0o644])
        try Routes.save([], to: file)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o077 == 0)
    }

    @Test("no file means no routes, not an error")
    func none() throws {
        #expect(try Routes.load(from: Fixtures.folder().appendingPathComponent("routes.json")) == [])
    }

    @Test("a route with no extensions of its own uses the source's")
    func inheritsExtensions() {
        let r = Route(name: "x", sourceID: "voice-memos", destination: URL(fileURLWithPath: "/a"))
        #expect(r.effectiveExtensions == Source.voiceMemos.extensions)
        #expect(r.carries(URL(fileURLWithPath: "/x/memo.m4a")))
        #expect(!r.carries(URL(fileURLWithPath: "/x/notes.txt")))
    }
}

struct SourceTests {
    @Test("the voice memos source points where macOS keeps them")
    func voiceMemos() {
        #expect(Source.voiceMemos.folder.path.contains("group.com.apple.VoiceMemos.shared/Recordings"))
        #expect(Source.resolve("voice-memos") == Source.voiceMemos)
    }

    @Test("an identifier that is not on the list resolves to nothing")
    func unknown() {
        #expect(Source.resolve("messages") == nil)
        #expect(Source.resolve("/Users/nobody/Library/Messages") == nil)
    }
}

struct MigrationTests {
    @Test("an old-format route naming an allowlisted folder by path becomes that route")
    func migratesKnownPath() throws {
        let dir = Fixtures.folder("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        let old = """
        [{"id":"5E1A2C3B-0000-4000-8000-000000000000","name":"Memos","enabled":true,
          "extensions":[],"source":"\(Source.voiceMemos.folder.absoluteString)",
          "destination":"file:///Users/nobody/Recordings/"}]
        """
        try old.write(to: file, atomically: true, encoding: .utf8)
        let (routes, notes) = try Routes.loadReporting(from: file)
        #expect(routes.count == 1)
        #expect(routes[0].sourceID == "voice-memos")
        #expect(notes.isEmpty)
    }

    @Test("an old-format route naming any other folder is dropped and named")
    func dropsUnknownPath() throws {
        let dir = Fixtures.folder("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        let old = """
        [{"id":"5E1A2C3B-0000-4000-8000-000000000001","name":"Messages","enabled":true,
          "extensions":[],"source":"file:///Users/nobody/Library/Messages/",
          "destination":"file:///tmp/exfil/"}]
        """
        try old.write(to: file, atomically: true, encoding: .utf8)
        let (routes, notes) = try Routes.loadReporting(from: file)
        #expect(routes.isEmpty)
        #expect(notes.count == 1)
        #expect(notes[0].contains("Messages"))
    }

    @Test("one bad entry does not take the others down")
    func skipsBadEntry() throws {
        let dir = Fixtures.folder("routes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        let mixed = """
        [{"nonsense": true},
         {"id":"5E1A2C3B-0000-4000-8000-000000000002","name":"Good","enabled":true,
          "extensions":[],"sourceID":"voice-memos","destination":"file:///Users/nobody/Recordings/"}]
        """
        try mixed.write(to: file, atomically: true, encoding: .utf8)
        let (routes, notes) = try Routes.loadReporting(from: file)
        #expect(routes.count == 1)
        #expect(notes.count == 1)
    }
}
