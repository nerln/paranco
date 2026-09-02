import Foundation

/// What happened to one file during a lift.
public enum LiftEvent: Sendable, Equatable {
    case copied(String, bytes: Int)
    case unchanged(String)
    case skipped(String, reason: String)
    case failed(String, reason: String)
}

/// The outcome of running one route once.
public struct LiftReport: Sendable, Equatable {
    public var route: UUID
    public var copied: Int = 0
    public var unchanged: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    public var bytes: Int = 0
    public var refused: String?

    public init(route: UUID) { self.route = route }
}

/// A refusal carrying the sentence a person needs, rather than an error code.
public struct Refusal: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Moves files one way, and knows what it has already moved.
///
/// Same name and same size means already there. A file whose size differs from
/// the copy is copied again, which is what happens when a recording seen while
/// its application was still writing it is seen a second time, finished. A file
/// still growing between two looks is left alone until it stops.
///
/// Nothing is ever written to a source, and nothing is written to a destination
/// that Destination has not accepted. The copy itself is done the careful way:
/// into a fresh file created with O_EXCL and O_NOFOLLOW, private to the user,
/// with no execute bit and no attributes carried across, then renamed into
/// place. A symlink left at the target name between the size check and the
/// write is replaced by the rename, never followed.
public enum Lift {

    /// Files in the source that the route carries, or the reason none can be seen.
    static func candidates(for route: Route) -> Result<[URL], Refusal> {
        guard let source = route.source else {
            return .failure(Refusal(
                "\"\(route.sourceID)\" is not on the list of folders this program may read. "
                + "Sources are compiled into the binary and cannot be added from a file."))
        }
        // The same walk the destination gets. A source on the list sits inside
        // a container macOS protects, so nothing without the permission can
        // put a link there; this is for the case where that assumption is wrong.
        if let link = Destination.symlinkComponent(in: source) {
            return .failure(Refusal("\(link) is a symbolic link; refusing to read through it"))
        }
        switch Access.check(source) {
        case .missing:
            return .failure(Refusal("there is no folder at \(source.path)"))
        case .refused(let why):
            return .failure(Refusal(why))
        case .readable:
            do {
                let all = try FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
                return .success(all.filter { url in
                    let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    return v?.isRegularFile == true && v?.isSymbolicLink != true && route.carries(url)
                }.sorted { $0.lastPathComponent < $1.lastPathComponent })
            } catch {
                return .failure(Refusal(error.localizedDescription))
            }
        }
    }

    /// Size without following a link: a symlink at the target must never be
    /// mistaken for the file it points at.
    static func size(_ url: URL) -> Int? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int(st.st_size)
    }

    /// Run a route once. `settling` is how long a file must have kept the same
    /// size before it is trusted; the caller can pass zero for a test.
    public static func run(_ route: Route, settling: TimeInterval = 2.0,
                           progress: (LiftEvent) -> Void = { _ in }) -> LiftReport {
        var report = LiftReport(route: route.id)

        let destination: URL
        switch Destination.validate(route.destination) {
        case .failure(let why):
            report.refused = why.message
            return report
        case .success(let ok):
            destination = ok
        }

        let found: [URL]
        switch candidates(for: route) {
        case .failure(let why):
            report.refused = why.message
            return report
        case .success(let urls):
            found = urls
        }

        if let why = makeDirectory(destination) {
            report.refused = why
            return report
        }

        // The directory is opened once, here, and every write for the rest of
        // the run goes through this descriptor. A path is a name that can be
        // made to mean something else while a run sleeps; a descriptor is the
        // folder that was checked. This closed a demonstrated attack: delete the
        // validated destination during the settle wait, put a symbolic link in
        // its place, and every copy after that landed wherever the link said.
        let dirfd = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirfd >= 0 else {
            report.refused = "cannot open \(destination.path): \(String(cString: strerror(errno)))"
            return report
        }
        defer { close(dirfd) }
        // And it must be the folder that was just checked, not one swapped in
        // between the check and this open.
        var byPath = stat(), byFd = stat()
        guard lstat(destination.path, &byPath) == 0, fstat(dirfd, &byFd) == 0,
              byPath.st_dev == byFd.st_dev, byPath.st_ino == byFd.st_ino,
              (byFd.st_mode & S_IFMT) == S_IFDIR else {
            report.refused = "\(destination.path) changed while it was being opened"
            return report
        }

        for source in found {
            let name = source.lastPathComponent
            guard let theirs = size(source) else {
                report.skipped += 1
                progress(.skipped(name, reason: "no size"))
                continue
            }
            if let mine = size(name, in: dirfd), mine == theirs {
                report.unchanged += 1
                progress(.unchanged(name))
                continue
            }
            if settling > 0 {
                Thread.sleep(forTimeInterval: settling)
                if size(source) != theirs {
                    report.skipped += 1
                    progress(.skipped(name, reason: "still being written"))
                    continue
                }
            }
            do {
                try copySafely(from: source, named: name, into: dirfd)
                report.copied += 1
                report.bytes += theirs
                progress(.copied(name, bytes: theirs))
            } catch {
                report.failed += 1
                progress(.failed(name, reason: error.localizedDescription))
            }
        }
        return report
    }

    /// Size of a name inside an open directory, without following a link.
    static func size(_ name: String, in dirfd: Int32) -> Int? {
        var st = stat()
        guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int(st.st_size)
    }

    /// Create the destination one component at a time, private to the user,
    /// refusing to pass through anything that is not a real directory.
    static func makeDirectory(_ url: URL) -> String? {
        let manager = FileManager.default
        var cursor = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            cursor = cursor.appendingPathComponent(component)
            var st = stat()
            if lstat(cursor.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    return "\(cursor.path) is a symbolic link; refusing to write through it"
                }
                if (st.st_mode & S_IFMT) != S_IFDIR {
                    return "\(cursor.path) is not a folder"
                }
                continue
            }
            do {
                try manager.createDirectory(at: cursor, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            } catch {
                return "cannot create \(cursor.path): \(error.localizedDescription)"
            }
        }
        return nil
    }

    enum CopyError: LocalizedError {
        case open(String, Int32)
        case write(String, Int32)
        var errorDescription: String? {
            switch self {
            case .open(let p, let e): return "cannot open \(p): \(String(cString: strerror(e)))"
            case .write(let p, let e): return "cannot write \(p): \(String(cString: strerror(e)))"
            }
        }
    }

    /// Bytes into a fresh, private, non-executable file inside an open directory,
    /// then a rename into place. Every name is resolved relative to `dirfd`, so
    /// what the destination path means to the filesystem by now is irrelevant.
    static func copySafely(from source: URL, named name: String, into dirfd: Int32) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw CopyError.open(source.path, errno) }
        defer { close(input) }

        let scratch = ".paranco-\(UUID().uuidString).part"
        let output = openat(dirfd, scratch, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw CopyError.open(scratch, errno) }
        var finished = false
        defer {
            close(output)
            if !finished { unlinkat(dirfd, scratch, 0) }
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let got = read(input, &buffer, buffer.count)
            if got == 0 { break }
            if got < 0 { throw CopyError.write(scratch, errno) }
            var offset = 0
            while offset < got {
                let put = write(output, &buffer[offset], got - offset)
                if put < 0 { throw CopyError.write(scratch, errno) }
                offset += put
            }
        }
        fsync(output)

        // If something is sitting at the target name it is replaced by the
        // rename, whatever it is. A symlink planted there is replaced as a link
        // and never followed; what it pointed at is untouched.
        guard renameat(dirfd, scratch, dirfd, name) == 0 else {
            throw CopyError.write(name, errno)
        }
        finished = true
    }
}
