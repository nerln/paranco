import Foundation

/// What happened to one file during a lift.
public enum LiftEvent: Sendable, Equatable {
    case copied(String, bytes: Int)
    case unchanged(String)
    case skipped(String, reason: String)
    case failed(String, reason: String)
    /// The name is in the folder and the bytes are somewhere else. Not a
    /// failure of this program and not something a retry fixes, so it gets a
    /// category of its own rather than swelling the failed count with a
    /// message about a bad address.
    case notHere(String, reason: String)
}

/// The outcome of running one route once.
public struct LiftReport: Sendable, Equatable {
    public var route: UUID
    public var copied: Int = 0
    public var unchanged: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    /// Placeholders: listed in the source with their bytes held by a cloud
    /// service and not on this Mac.
    public var notHere: Int = 0
    public var bytes: Int = 0
    public var refused: String?
    /// One line about the process, for the report: the read policy, mainly.
    public var note: String = ""

    public init(route: UUID) { self.route = route }

    /// One sentence for the person reading the report, when placeholders were
    /// found. Deliberately about the filesystem and not about any application:
    /// the flag it rests on is the same for a voice memo, a photo, a document
    /// in iCloud Drive and anything else a sync service evicts.
    public var notHereAdvice: String? {
        guard notHere > 0 else { return nil }
        return "\(notHere) of the files are placeholders: the name is here and the "
             + "contents are held by a cloud service, not on this Mac. Nothing in "
             + "this program can fetch them. Open them in the application they "
             + "belong to, or turn off the setting that keeps this Mac's copy small, "
             + "and they will be copied on a later pass."
    }
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

    /// Whether the bytes of a file are on this disk, from the filesystem alone.
    ///
    /// Two signs, both independent of which application owns the file. APFS marks
    /// a file whose contents have been evicted by a sync service with SF_DATALESS,
    /// and reading such a file asks the service to bring the bytes back; when no
    /// service answers, the read fails with EFAULT, which strerror renders as
    /// "Bad address" and which reads as nonsense to a person. The second sign is
    /// a file that claims a size and has no blocks allocated to it, which is the
    /// same condition on a filesystem that does not set the flag.
    ///
    /// Measured on a library of 176 recordings: 103 of them were this, and the
    /// program reported every one as a failed write.
    public static func isPlaceholder(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        if UInt32(st.st_flags) & UInt32(SF_DATALESS) != 0 { return true }
        return st.st_size > 0 && st.st_blocks == 0
    }

    /// What the filesystem says about a file, in one line, for a report.
    ///
    /// Size, blocks actually allocated, every flag by name, and whether a sync
    /// service claims it. This is what to read when a copy fails for a reason
    /// strerror cannot express: a file with blocks and no flag that still cannot
    /// be read is a different animal from a placeholder, and the line says which.
    public static func describe(_ url: URL) -> String {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "cannot stat: \(String(cString: strerror(errno)))" }
        let flags = UInt32(st.st_flags)
        let names: [(UInt32, String)] = [
            (UInt32(SF_DATALESS), "dataless"), (UInt32(UF_DATAVAULT), "datavault"),
            (UInt32(UF_COMPRESSED), "compressed"), (UInt32(UF_TRACKED), "tracked"),
            (UInt32(UF_HIDDEN), "hidden"), (UInt32(SF_RESTRICTED), "restricted"),
            (UInt32(UF_IMMUTABLE), "uchg"), (UInt32(SF_IMMUTABLE), "schg"),
        ]
        var set = names.filter { flags & $0.0 != 0 }.map(\.1)
        let known = names.reduce(UInt32(0)) { $0 | $1.0 }
        if flags & ~known != 0 { set.append(String(format: "0x%08x", flags & ~known)) }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        var cloud = ""
        if values?.isUbiquitousItem == true {
            cloud = ", iCloud item, status \(values?.ubiquitousItemDownloadingStatus?.rawValue ?? "?")"
        }
        return "\(st.st_size) bytes, \(st.st_blocks) blocks, flags [\(set.joined(separator: " "))]\(cloud)"
    }

    /// Ask the kernel to bring dataless files back when they are read.
    ///
    /// macOS has a per-process policy for this and its default is not
    /// documented to be on. A process that reads a dataless file with the policy
    /// off gets an error instead of a download. Setting it costs nothing where
    /// nothing is dataless, and where something is, it is the difference between
    /// copying the file and reporting that it could not be read. Returns what
    /// the policy was before, for the report.
    @discardableResult
    public static func materialiseOnRead() -> String {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
        let ok = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                                IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0
        let name = ["default", "off", "on", "?", "orig"]
        return "materialise-on-read was \(before >= 0 && before < name.count ? name[Int(before)] : "\(before)")"
             + (ok ? ", now on" : ", could not be set: \(String(cString: strerror(errno)))")
    }

    /// Ask the system to bring a placeholder's bytes back, where there is a
    /// public way to ask. There is one for iCloud Drive; for anything else the
    /// owning application is the only thing that can, and this returns false.
    static func requestContents(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard values?.isUbiquitousItem == true else { return false }
        return (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil
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
        report.note = materialiseOnRead()

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
            if isPlaceholder(source) {
                report.notHere += 1
                let asked = requestContents(source)
                progress(.notHere(name, reason: asked
                    ? "in iCloud Drive; download requested, will copy once it has arrived"
                    : "contents held by a cloud service, not on this Mac"))
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
                try copySafely(from: source, named: name, into: dirfd, expecting: theirs)
                report.copied += 1
                report.bytes += theirs
                progress(.copied(name, bytes: theirs))
            } catch CopyError.read(_, let code) where code == EFAULT || code == EDEADLK {
                // The flags said nothing and the read said everything: these two
                // errors on a regular file with a valid buffer mean the kernel
                // could not produce the bytes, which is a placeholder by another
                // name. Counted with them, and described so the next person does
                // not have to guess what the filesystem saw.
                report.notHere += 1
                progress(.notHere(name, reason: "could not be read (\(String(cString: strerror(code))))"
                                  + "; \(describe(source))"))
            } catch {
                report.failed += 1
                progress(.failed(name, reason: "\(error.localizedDescription); \(describe(source))"))
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
        case read(String, Int32)
        case write(String, Int32)
        case short(String, got: Int, expected: Int)
        var errorDescription: String? {
            switch self {
            case .open(let p, let e): return "cannot open \(p): \(String(cString: strerror(e)))"
            case .read(let p, let e):
                // EFAULT on a read is what a placeholder looks like when the flag
                // was not set. Say that, because "Bad address" says nothing.
                if e == EFAULT {
                    return "cannot read \(p): its contents are not on this Mac"
                }
                return "cannot read \(p): \(String(cString: strerror(e)))"
            case .write(let p, let e): return "cannot write \(p): \(String(cString: strerror(e)))"
            case .short(let p, let got, let expected):
                return "\(p) came out at \(got) bytes of \(expected); not kept"
            }
        }
    }

    /// Bytes into a fresh, private, non-executable file inside an open directory,
    /// then a rename into place. Every name is resolved relative to `dirfd`, so
    /// what the destination path means to the filesystem by now is irrelevant.
    static func copySafely(from source: URL, named name: String, into dirfd: Int32,
                           expecting expected: Int? = nil) throws {
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
        var written = 0
        while true {
            let got = read(input, &buffer, buffer.count)
            if got == 0 { break }
            // A failed read used to be reported as a failed write of the scratch
            // file, which sent the diagnosis to the wrong side of the copy.
            if got < 0 { throw CopyError.read(source.lastPathComponent, errno) }
            var offset = 0
            while offset < got {
                let put = write(output, &buffer[offset], got - offset)
                if put < 0 { throw CopyError.write(scratch, errno) }
                offset += put
            }
            written += got
        }
        fsync(output)

        // A copy that stopped early is not a copy, and renaming it into place
        // would make it one as far as the next pass could tell: same name, and
        // from then on the size the destination has is the size it compares.
        if let expected, written != expected {
            throw CopyError.short(name, got: written, expected: expected)
        }

        // If something is sitting at the target name it is replaced by the
        // rename, whatever it is. A symlink planted there is replaced as a link
        // and never followed; what it pointed at is untouched.
        guard renameat(dirfd, scratch, dirfd, name) == 0 else {
            throw CopyError.write(name, errno)
        }
        finished = true
    }
}
