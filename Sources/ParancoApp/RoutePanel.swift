import AppKit
import SwiftUI
import ParancoCore

/// The pane for one route.
///
/// Top to bottom, in the order somebody reads it: the name and whether the
/// source can be read; what is stopping it, if anything; the button; the
/// report of the run in progress or of the last one; and then the two paths
/// and what travels between them.
struct RoutePanel: View {
    let route: Route
    let verdict: Access.Verdict?
    let checking: Bool
    @ObservedObject var lifter: Lifter
    let onLift: () -> Void
    let onCheck: () -> Void
    let onToggle: (Bool) -> Void

    private var isLifting: Bool { lifter.running == route.id }

    /// Whether the button should be live. One rule for the button, the menu
    /// and the context menu, so none of them can offer what another refuses.
    static func canLift(_ route: Route, verdict: Access.Verdict?, running: UUID?) -> Bool {
        guard route.enabled, running == nil else { return false }
        if case .readable = verdict { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                switch verdict {
                case .refused(let why):
                    RefusedBox(why: why, checking: checking, onCheck: onCheck)
                case .missing:
                    missing
                default:
                    EmptyView()
                }

                liftControls

                if isLifting {
                    LiveReport(live: lifter.live)
                } else if let done = lifter.reports[route.id] {
                    FinishedReport(done: done)
                }

                // The paths last. They are reference, and the box holding
                // them is tall: with it first, the report of a run that has
                // just been started sat below the bottom of a window of the
                // default size, which is the one moment somebody is looking.
                GroupBox { paths.padding(6) }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.name).font(.title2).bold().textSelection(.enabled)
            HStack(spacing: 8) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.callout)
                    .foregroundStyle(statusTint)
                if checking {
                    ProgressView().controlSize(.mini)
                }
            }
            if case .readable(let n) = verdict, n == 0 {
                // The sentence this module exists for. Asked the wrong way,
                // macOS reports a protected folder as empty; this one was
                // asked the right way and answered.
                Text("Zero is an answer, not a refusal: macOS let this process list "
                     + "the folder, and there is nothing in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch verdict {
        case .readable(let n):
            return n == 0 ? "Readable, and empty"
                 : n == 1 ? "Readable, 1 file in the source"
                 : "Readable, \(n) files in the source"
        case .refused: return "Refused: macOS is not letting this process read the source"
        case .missing: return "Missing: there is no folder at the source path"
        case nil: return checking ? "Checking whether the source can be read…" : "Not checked"
        }
    }

    private var statusSymbol: String {
        switch verdict {
        case .readable: return "checkmark.circle.fill"
        case .refused: return "lock.fill"
        case .missing: return "questionmark.folder"
        case nil: return "circle.dotted"
        }
    }

    private var statusTint: Color {
        switch verdict {
        case .readable: return .green
        case .refused: return .orange
        case .missing: return .orange
        case nil: return .secondary
        }
    }

    // MARK: - paths

    private var paths: some View {
        VStack(alignment: .leading, spacing: 12) {
            PathField(title: "Source", url: route.source,
                      note: "The folder the permission is for. Read, never written.",
                      reveal: false)
            Divider()
            PathField(title: "Destination", url: route.destination,
                      note: "An ordinary folder. Whatever reads it needs nothing.",
                      reveal: true)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Carries").font(.headline)
                Text(route.extensions.isEmpty
                     ? "Every file"
                     : route.extensions.sorted().map { "." + $0 }.joined(separator: "  "))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("Files in the source itself, not in folders inside it. The count "
                     + "above is every file there, whatever its extension.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Enabled", isOn: Binding(get: { route.enabled }, set: onToggle))
                .disabled(isLifting)
            Text("A route that is off is skipped by the agent and cannot be lifted from here. "
                 + "Nothing it already delivered is touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var missing: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("There is no folder at \(route.source?.tilde ?? route.sourceID)",
                      systemImage: "questionmark.folder")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Nothing is lifted from a folder that is not there. If the path is "
                     + "wrong, delete the route and add it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again", action: onCheck).disabled(checking)
            }
            .padding(6)
        }
    }

    // MARK: - lifting

    private var canLift: Bool {
        Self.canLift(route, verdict: verdict, running: lifter.running)
    }

    private var liftControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onLift) {
                Label(isLifting ? "Lifting…" : "Lift now", systemImage: "arrow.up.to.line")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!canLift)
            Text(liftCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Say why the button is off before it is pressed, not after.
    private var liftCaption: String {
        if isLifting {
            return "Each new file is watched for two seconds before it is copied, so a "
                 + "first run over a large library takes a while. The window stays usable."
        }
        if !route.enabled {
            return "Turn the route on to lift it."
        }
        if lifter.running != nil {
            return "Another route is lifting. One at a time."
        }
        switch verdict {
        case .refused:
            return "The source cannot be read until Full Disk Access is granted."
        case .missing:
            return "There is nothing to lift from a folder that is not there."
        case nil:
            return "Waiting for the check on the source."
        case .readable:
            return "Copies what is new. A file already at the destination with the same "
                 + "size is left alone, and a file still being written is skipped until "
                 + "it stops growing. Nothing is written to the source."
        }
    }
}

// MARK: - pieces

/// A titled path with the full one as a tooltip, and a Finder button where
/// there is something worth looking at.
struct PathField: View {
    let title: String
    /// nil for a source this build does not know, which is shown as such rather
    /// than as an empty path.
    let url: URL?
    let note: String
    let reveal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if reveal, let url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open \(url.tilde) in the Finder")
                }
            }
            Text(url?.tilde ?? "Not on the list of folders this build may read")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(url == nil ? .orange : .primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(url?.path ?? "")
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// What to show when macOS said no.
///
/// The text is Access's own sentence, because it names the folder and the
/// pane and was written for exactly this moment: somebody has usually just
/// granted a permission and wants to know whether it took.
struct RefusedBox: View {
    let why: String
    let checking: Bool
    let onCheck: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("macOS refused to list the source", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(why)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button {
                        FullDiskAccess.open()
                    } label: {
                        Label("Open Full Disk Access", systemImage: "gear")
                    }
                    Button("Check again", action: onCheck)
                        .disabled(checking)
                    if checking {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Coming back to this window after granting it checks again on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

/// The report while a lift runs. Observes LiftProgress and nothing else, so
/// the ten updates a second redraw these four numbers and not the pane.
struct LiveReport: View {
    @ObservedObject var live: LiftProgress

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lifting").font(.headline)
                }
                ReportGrid(copied: live.copied, unchanged: live.unchanged,
                           skipped: live.skipped, failed: live.failed,
                           notHere: live.notHere, bytes: live.bytes)
                if !live.lastLine.isEmpty {
                    Text(live.lastLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(6)
        }
    }
}

/// The report of a run that has ended, kept until the next one.
struct FinishedReport: View {
    let done: Lifter.Finished

    private var report: LiftReport { done.report }

    private var wentWrong: Bool {
        report.refused != nil || report.failed > 0
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: wentWrong ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(wentWrong ? Color.orange : Color.green)
                    Text(report.refused == nil
                         ? "Finished at \(done.when.formatted(date: .omitted, time: .shortened)) "
                           + "in \(elapsedText(done.seconds))"
                         : "Did not run")
                        .font(.headline)
                }
                if let why = report.refused {
                    Text(why)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    // The refusal from the lift is the same sentence Access
                    // writes, and it names the pane when the pane is the fix.
                    // A destination that could not be created is a refusal
                    // too, and the pane is no help with that one.
                    if why.contains("Full Disk Access") {
                        Button {
                            FullDiskAccess.open()
                        } label: {
                            Label("Open Full Disk Access", systemImage: "gear")
                        }
                    }
                } else {
                    ReportGrid(copied: report.copied, unchanged: report.unchanged,
                               skipped: report.skipped, failed: report.failed,
                               notHere: report.notHere, bytes: report.bytes)
                    if let advice = report.notHereAdvice {
                        // Not in the failures list and not in warning colour: it is
                        // a fact about where the bytes live, and the sentence says
                        // what a person can do about it.
                        Text(advice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !done.failures.isEmpty {
                        // Named here and nowhere else. The agent logs a count,
                        // and a count is not something anybody can act on.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(done.failures.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            if report.failed > done.failures.count {
                                Text("and \(report.failed - done.failures.count) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}

/// Five numbers and the bytes, laid out the same way live and finished, so
/// the eye does not have to find them again when the run ends.
struct ReportGrid: View {
    let copied: Int
    let unchanged: Int
    let skipped: Int
    let failed: Int
    var notHere: Int = 0
    let bytes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                figure(copied, "copied")
                figure(unchanged, "already there")
                figure(skipped, "skipped")
                figure(failed, "failed", warn: failed > 0)
                if notHere > 0 {
                    figure(notHere, "not on this Mac")
                }
            }
            Text(bytes == 0 ? "Nothing copied" : "\(bytesText(bytes)) copied")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func figure(_ n: Int, _ label: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)")
                .font(.system(.title2, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
