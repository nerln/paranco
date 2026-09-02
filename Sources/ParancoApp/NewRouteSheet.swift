import AppKit
import SwiftUI
import ParancoCore

/// A route from one of the folders this build may read to a folder of your own.
///
/// The source is chosen from a list, not from a panel. The list is compiled
/// into the program, and that is the whole security model: a program holding
/// Full Disk Access that would read any folder it was pointed at is a way for
/// any other process running as you to read what macOS protects. Adding a
/// folder to the list is a code change, on purpose.
///
/// The destination does come from a panel, and is then checked by the same
/// rule the agent applies before writing: a real folder inside your home,
/// outside ~/Library, on this Mac's own disk, with no symbolic link anywhere
/// on the way. A path typed with one wrong character would be a route that
/// reports "missing" for ever, which is why it is a panel and not a field.
struct NewRouteSheet: View {
    /// Names already in use. Two routes with one name would be one route to
    /// the command line, which addresses them by name.
    let taken: Set<String>
    /// A source to start from, when the menu already chose one.
    var preselected: Source? = nil
    let onAdd: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source?
    @State private var destination: URL?
    @State private var destinationProblem: String?
    @State private var name = ""
    @State private var extensions = ""
    @State private var suggested = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New route").font(.title2).bold()
                Text("From a folder macOS protects to one of your own, one way. Files are "
                     + "copied out of the source, and nothing is ever written back to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Source")
                        .font(.headline)
                        .frame(width: 90, alignment: .leading)
                    Picker("Source", selection: $source) {
                        Text("Choose a folder").tag(Source?.none)
                        ForEach(Source.builtIn) { s in
                            Text(s.name).tag(Source?.some(s))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: source) { _, _ in propose() }
                }
                Text(source?.note
                     ?? "Only the folders compiled into this build can be read. That list "
                        + "is short on purpose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 102)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FolderField(title: "Destination", url: destination,
                        note: "A folder of your own, inside your home and outside ~/Library. "
                            + "Whatever reads it needs no permission.",
                        action: chooseDestination)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Name")
                    .font(.headline)
                    .frame(width: 90, alignment: .leading)
                TextField("Name", text: $name, prompt: Text("Voice Memos → Recordings"))
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Extensions")
                        .font(.headline)
                        .frame(width: 90, alignment: .leading)
                    TextField("Extensions", text: $extensions,
                              prompt: Text(source?.extensions.sorted().joined(separator: ", ")
                                           ?? "m4a, wav, caf"))
                        .labelsHidden()
                }
                Text("Without the dot, separated by commas. Leave it empty to use the "
                     + "source's own list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 102)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add route", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { if source == nil { source = preselected } }
    }

    // MARK: - rules

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one thing that is wrong, if anything is, in the order it can be
    /// noticed: the destination first, the name once everything is chosen.
    private var problem: String? {
        if let destinationProblem { return destinationProblem }
        if !trimmedName.isEmpty, taken.contains(trimmedName) {
            return "There is already a route called \(trimmedName)."
        }
        return nil
    }

    private var ready: Bool {
        source != nil && destination != nil && !trimmedName.isEmpty && problem == nil
    }

    private var parsedExtensions: Set<String> {
        Set(extensions
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() })
    }

    // MARK: - choosing

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination ?? FileManager.default.homeDirectoryForCurrentUser
        panel.message = "The folder to copy into. Inside your home, outside ~/Library."
        panel.prompt = "Use as destination"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The same check the agent makes before writing a byte. Failing it here,
        // with the reason in front of the person, beats a route that refuses
        // silently every five minutes for a month.
        switch Destination.validate(url) {
        case .success(let ok):
            destination = ok
            destinationProblem = nil
        case .failure(let why):
            destination = nil
            destinationProblem = why.message
        }
        propose()
    }

    /// A name from the source and the folder, unless somebody typed one.
    private func propose() {
        guard let source, let destination else { return }
        let next = "\(source.name) → \(destination.lastPathComponent)"
        if name.isEmpty || name == suggested { name = next }
        suggested = next
    }

    private func add() {
        guard let source, let destination, ready else { return }
        onAdd(Route(name: trimmedName, sourceID: source.id, destination: destination,
                    extensions: parsedExtensions))
        dismiss()
    }
}

/// A folder that has been chosen, or has not, and the button that chooses it.
struct FolderField: View {
    let title: String
    let url: URL?
    let note: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .frame(width: 90, alignment: .leading)
                Text(url?.tilde ?? "Not chosen")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url?.path ?? "")
                Spacer()
                Button("Choose…", action: action)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 102)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
