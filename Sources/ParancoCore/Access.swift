import Foundation

/// Whether a folder can be read, told apart from whether it is empty.
///
/// This distinction is the reason the module exists. macOS answers a protected
/// folder in two ways, depending on who asks. Asked directly, it refuses with a
/// permission error. Asked through System Events or Finder from a process that
/// lacks the permission, it reports the folder as empty: a control on a folder
/// with sixteen files returned sixteen, and the Voice Memos library returned
/// nothing. A program that only checks `exists()` then tells somebody with two
/// hundred recordings that they have none.
///
/// So every answer here says which of the three it is, and a refusal carries the
/// sentence a person needs, because they have usually just granted a permission
/// and want to know whether it took.
public enum Access {
    public enum Verdict: Equatable, Sendable {
        case readable(files: Int)
        case refused(String)
        case missing
    }

    public static func check(_ folder: URL) -> Verdict {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        // exists() itself is allowed on a protected folder: it is the listing
        // that is refused. That is what makes the two cases separable.
        guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        do {
            let entries = try manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            let files = entries.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            return .readable(files: files.count)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError
                                            || error.code == EPERM || error.code == EACCES {
            return .refused(
                "macOS is not letting this process read \(folder.path). "
                + "Grant Full Disk Access to Paranco.app in System Settings > Privacy & "
                + "Security > Full Disk Access, then try again. Nothing else needs it.")
        } catch {
            return .refused("\(folder.path) cannot be read: \(error.localizedDescription)")
        }
    }

    /// The reason a permission cannot be borrowed, for anyone who tries.
    ///
    /// macOS charges an access to the process that asked for it. A terminal that
    /// drives Finder gets the terminal's permission tested, not Finder's. The only
    /// holder that counts is a program with its own identity, started by launchd
    /// or by a person, which is why Paranco is an application and not a script.
    public static let whyAnApplication = """
        macOS charges an access to the process that asked for it, so a permission \
        cannot be borrowed from Finder or from System Events by driving them. \
        It can only be held by an application with its own identity, started by \
        launchd or by a person. That is what Paranco.app is.
        """
}
