import Foundation

/// Where a privileged process is allowed to write, and where it is not.
///
/// The destination is the second half of the security model. A program with
/// Full Disk Access that writes wherever a file tells it to is an arbitrary-write
/// tool for whoever can write that file: point it at a symlink and it writes
/// through; give it `..` and it climbs out; name a synced folder and the data
/// leaves the machine. So a destination is accepted only if it is exactly the
/// folder it looks like, and only inside the places a person's own files live.
public enum Destination {

    /// The canonical folder, or the reason it was refused.
    ///
    /// `avoiding` is the list of source folders; a destination inside one of
    /// them would make the privileged process write into the protected library
    /// it is supposed to only read.
    public static func validate(_ url: URL,
                                avoiding sources: [URL] = Source.all.map(\.folder)) -> Result<URL, Refusal> {
        let manager = FileManager.default
        let raw = url.path

        guard url.isFileURL, raw.hasPrefix("/") else {
            return .failure(Refusal("the destination has to be a folder on this Mac"))
        }
        // Refused rather than normalised. A path that says ".." was written by
        // something trying to get out of the folder it was given.
        if url.pathComponents.contains("..") || url.pathComponents.contains(".") {
            return .failure(Refusal("the destination path must not contain . or .. components"))
        }
        // A newline or an escape in a folder name is never a folder somebody
        // typed; it is a name built to forge a line in whatever prints it.
        if url.pathComponents.contains(where: { component in
            component.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
        }) {
            return .failure(Refusal("the destination path contains control characters"))
        }

        let home = URL(fileURLWithPath: manager.homeDirectoryForCurrentUser.path).resolvingSymlinksInPath()
        guard isInside(url, home) else {
            return .failure(Refusal("the destination has to be inside your home folder; "
                                    + "anywhere else is readable by other users or leaves the machine"))
        }

        // ~/Library holds every other application's data, including the folders
        // this program exists to read. A privileged write into another
        // application's container is exactly the amplification to refuse.
        let library = home.appendingPathComponent("Library")
        if isInside(url, library) || canonical(url).path.lowercased() == canonical(library).path.lowercased() {
            return .failure(Refusal("the destination cannot be inside ~/Library: that is where "
                                    + "other applications keep their data"))
        }
        for source in sources {
            if isInside(url, source) || canonical(url).path.lowercased() == canonical(source).path.lowercased() {
                return .failure(Refusal("the destination cannot be inside a source"))
            }
        }

        // Every component that already exists must be a real directory: a
        // symlink at any level would send the write somewhere the person did
        // not name.
        if let link = symlinkComponent(in: url) {
            return .failure(Refusal("\(link) is a symbolic link; the destination must be a "
                                    + "real folder all the way down"))
        }
        if let file = fileComponent(in: url) {
            return .failure(Refusal("\(file) is a file, not a folder"))
        }

        // The nearest existing ancestor decides which volume this lands on.
        var probe = url
        while !manager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        if let values = try? probe.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey,
                                                              .volumeIsLocalKey]) {
            if values.volumeIsLocal == false {
                return .failure(Refusal("the destination is on a network volume"))
            }
            if values.volumeIsRemovable == true {
                return .failure(Refusal("the destination is on a removable volume"))
            }
        }
        return .success(url)
    }

    /// Whether `url` sits strictly under `ancestor`.
    ///
    /// Compared without regard to case. The default volume on a Mac is case
    /// insensitive, so "~/library" is ~/Library to the filesystem, and a check
    /// that only knew the capital L let a write into it through. On a case
    /// sensitive volume this refuses a little more than it has to, which is the
    /// right direction to be wrong in.
    static func isInside(_ url: URL, _ ancestor: URL) -> Bool {
        let a = canonical(ancestor).pathComponents.map { $0.lowercased() }
        let u = canonical(url).pathComponents.map { $0.lowercased() }
        return u.count > a.count && Array(u.prefix(a.count)) == a
    }

    /// The path with its existing part resolved through realpath, which also
    /// returns the on-disk spelling, and the rest appended as written.
    static func canonical(_ url: URL) -> URL {
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(existing.path, &buffer) != nil else { return url }
        var out = URL(fileURLWithPath: String(cString: buffer))
        for component in tail { out.appendPathComponent(component) }
        return out
    }

    /// The first existing component of `url` that is a symbolic link, if any.
    /// Walked from the root, one component at a time, with lstat.
    static func symlinkComponent(in url: URL) -> String? {
        var cursor = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            cursor = cursor.appendingPathComponent(component)
            var st = stat()
            guard lstat(cursor.path, &st) == 0 else { return nil }
            if (st.st_mode & S_IFMT) == S_IFLNK { return cursor.path }
        }
        return nil
    }

    /// The first existing component of `url` that is not a directory, if any.
    static func fileComponent(in url: URL) -> String? {
        var cursor = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            cursor = cursor.appendingPathComponent(component)
            var st = stat()
            guard lstat(cursor.path, &st) == 0 else { return nil }
            if (st.st_mode & S_IFMT) != S_IFDIR { return cursor.path }
        }
        return nil
    }
}
