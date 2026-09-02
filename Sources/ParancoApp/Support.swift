import AppKit
import Foundation

/// The System Settings pane where the permission is granted.
enum FullDiskAccess {
    /// The URL scheme System Settings answers to. It opens the pane; the
    /// person still has to find Paranco.app in the list, or drag it in.
    static let pane = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func open() {
        NSWorkspace.shared.open(pane)
    }
}

extension URL {
    /// The path with the home folder as a tilde, which is how a person reads
    /// it. The full path stays available as a tooltip wherever this is shown.
    var tilde: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Seconds, the way a person reads them: tenths under ten seconds, whole
/// seconds under a minute, minutes and seconds after that.
func elapsedText(_ seconds: Double) -> String {
    if seconds < 10 { return String(format: "%.1f s", seconds) }
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    let whole = Int(seconds.rounded())
    return "\(whole / 60) min \(whole % 60) s"
}

func bytesText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
