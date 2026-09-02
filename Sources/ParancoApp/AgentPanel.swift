import AppKit
import SwiftUI
import ParancoCore

/// What the window shows about the launch agent, read from disk each time
/// the panel opens. The plist and launchctl are the truth, and this window
/// is not the only thing that changes them: `paranco agent remove` does too.
struct AgentStatus: Equatable, Sendable {
    var installed = false
    /// Seconds between runs, as written in the plist.
    var interval: Int?
    /// What the plist points launchd at.
    var executable: String?
    var logTail: [String] = []

    static let tailLength = 12

    static func read() -> AgentStatus {
        var status = AgentStatus(installed: Agent.isInstalled)
        if status.installed,
           let data = try? Data(contentsOf: Agent.plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] {
            status.interval = dict["StartInterval"] as? Int
            status.executable = (dict["ProgramArguments"] as? [String])?.first
        }
        if let data = try? Data(contentsOf: Agent.log),
           let text = String(data: data, encoding: .utf8) {
            status.logTail = text.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(tailLength)
                .map(String.init)
        }
        return status
    }
}

/// The popover behind the Agent toolbar button.
struct AgentPanel: View {
    @State private var status: AgentStatus?
    @State private var minutes = 5
    @State private var busy = false
    @State private var problem: String?

    private let choices = [1, 5, 15]

    private var installed: Bool { status?.installed ?? false }

    /// Where this process is running from. A launch agent points at a path,
    /// and the path matters: Full Disk Access is granted to a bundle.
    private var executable: URL? { Bundle.main.executableURL }
    private var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch agent").font(.headline)
                Text("Runs every enabled route on a timer, whether or not this window is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS charges an access to the process that asks for it, and the "
                     + "agent is this application's own executable started by launchd, so "
                     + "the one grant to Paranco.app covers the window and the agent alike.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            statusLine

            HStack(spacing: 10) {
                Text("Every")
                Picker("Interval", selection: $minutes) {
                    ForEach(choices, id: \.self) { m in
                        Text("\(m) min").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            HStack(spacing: 10) {
                Button(installed ? "Reinstall" : "Install", action: install)
                    .disabled(busy || status == nil)
                if installed {
                    Button("Remove", role: .destructive, action: remove)
                        .disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            if !inBundle, let executable {
                Text("This window is not running from Paranco.app, so the agent would run "
                     + "\(executable.tilde). Build the bundle and install from there, so the "
                     + "permission and the agent belong to the same application.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            log
        }
        .padding(18)
        .frame(width: 440)
        .task { await refresh() }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let status {
            if status.installed {
                VStack(alignment: .leading, spacing: 3) {
                    Label(intervalText(status.interval), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let executable = status.executable {
                        Text("Runs " + (executable as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(executable)
                    }
                }
            } else {
                Label("Not installed", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading…").foregroundStyle(.secondary)
            }
        }
    }

    private func intervalText(_ seconds: Int?) -> String {
        guard let seconds else { return "Installed" }
        if seconds % 60 == 0 {
            let m = seconds / 60
            return m == 1 ? "Installed, runs every minute" : "Installed, runs every \(m) minutes"
        }
        return "Installed, runs every \(seconds) seconds"
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                    .disabled(busy)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Agent.log])
                }
                .disabled(status?.logTail.isEmpty ?? true)
            }
            if let tail = status?.logTail, !tail.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                Text("The last \(AgentStatus.tailLength) lines of \(Agent.log.tilde).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing logged yet. The agent writes a line only when it copies "
                     + "something, when a copy fails, or when it is refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - actions

    /// Read off the main thread. The log can be long, and launchctl is not
    /// involved: the plist on disk is what says whether the agent is there.
    private func refresh() async {
        let fresh = await Task.detached(priority: .userInitiated) { AgentStatus.read() }.value
        status = fresh
        if let seconds = fresh.interval, seconds % 60 == 0, choices.contains(seconds / 60) {
            minutes = seconds / 60
        }
    }

    private func install() {
        guard let executable else {
            problem = "This process has no executable path to hand to launchd."
            return
        }
        // Refused, not warned about. A plist pointing at a binary inside .build
        // is an agent that runs a file that changes on every compile and holds
        // no permission at all, and it would sit there failing every five
        // minutes with nothing on screen to say why.
        guard inBundle else {
            problem = "Not running from Paranco.app, so there is nothing to grant the "
                    + "permission to. Build the bundle with ./build.sh and install from there."
            return
        }
        busy = true
        problem = nil
        let seconds = minutes * 60
        Task {
            // launchctl is run and waited for. Quick, and still not something
            // to do on the thread that draws the button being pressed.
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try Agent.install(executable: executable, interval: seconds)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            problem = failure
            await refresh()
            busy = false
        }
    }

    private func remove() {
        busy = true
        problem = nil
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try Agent.remove()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            problem = failure
            await refresh()
            busy = false
        }
    }
}
