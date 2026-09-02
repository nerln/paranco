import SwiftUI
import ParancoCore

/// The window.
///
/// The sidebar lists the routes on disk and, under each name, whether macOS
/// is letting this process read the source. The detail pane shows one route:
/// where it goes, whether it can run, and what the last run did.
///
/// Nothing runs on its own here. A route is lifted when a person presses the
/// button, or by the launch agent on its timer. Opening the window to look at
/// a refusal copies nothing.
struct ContentView: View {
    @StateObject private var store = RouteStore()
    @StateObject private var lifter = Lifter()

    @State private var selection: UUID?
    @State private var deleting: Route?
    @State private var adding: Source?
    @State private var showingAgent = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 880, minHeight: 540)
        .onAppear {
            store.reload()
            if selection == nil { selection = store.routes.first?.id }
        }
        // Coming back to the window is the moment to look again, twice over.
        // The reason somebody left was most likely to grant the permission
        // in System Settings, and a row still saying refused after they had
        // done that would be the wrong answer at the one moment it matters.
        // And the route file is shared with the command line on purpose, so
        // a route added with `paranco add` in a terminal belongs in the list
        // when the window comes back, not after a relaunch. Reloading reads
        // the file and then checks every source.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
        // A finished lift is a reason to look at the source again. A refusal
        // in the report under a row that still says readable would be two
        // answers to one question.
        .onChange(of: lifter.running) { previous, current in
            if let previous, current == nil,
               let route = store.routes.first(where: { $0.id == previous }) {
                store.check(route)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parancoAddRoute)) { _ in
            if !store.unreadable { adding = Source.builtIn.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parancoLift)) { _ in
            if let route = selected { lift(route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parancoCheck)) { _ in
            store.checkAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parancoDelete)) { _ in
            askToDelete(selected)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAgent.toggle()
                } label: {
                    Label("Agent", systemImage: "clock.arrow.circlepath")
                }
                .help("The launch agent that runs the routes on a timer")
                .popover(isPresented: $showingAgent, arrowEdge: .bottom) {
                    AgentPanel()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // One entry per folder this build may read. There is no
                    // "any folder" entry and there will not be: the list is
                    // compiled in, and that is the security model.
                    ForEach(Source.builtIn) { source in
                        Button("From \(source.name)…") { adding = source }
                    }
                } label: {
                    Label("Add route", systemImage: "plus")
                }
                .disabled(store.unreadable)
                .help("A route from one of the folders this program may read")
            }
        }
        .sheet(item: $adding) { source in
            NewRouteSheet(taken: Set(store.routes.map(\.name)), preselected: source) { route in
                store.add(route)
                selection = route.id
            }
        }
        .confirmationDialog(
            deleting.map { "Delete the route \($0.name)?" } ?? "",
            isPresented: Binding(get: { deleting != nil },
                                 set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete the route", role: .destructive) {
                if let route = deleting { remove(route) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let route = deleting {
                Text("Only the route is removed. Nothing is deleted from the source "
                     + "or from \(route.destination.tilde): what was already lifted "
                     + "stays where it landed.")
            }
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if let problem = store.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section(store.routes.isEmpty ? "Routes" : "Routes (\(store.routes.count))") {
                if store.routes.isEmpty {
                    Text("None yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.routes) { route in
                    RouteRow(route: route,
                             verdict: store.verdicts[route.id],
                             checking: store.checking.contains(route.id),
                             lifting: lifter.running == route.id)
                        .tag(route.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                askToDelete(route)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(lifter.running == route.id)
                        }
                        .contextMenu {
                            Button("Lift now") { lift(route) }
                                .disabled(!canLift(route))
                            Button("Check again") { store.check(route) }
                            Divider()
                            Button("Delete route…", role: .destructive) { askToDelete(route) }
                                .disabled(lifter.running == route.id)
                        }
                }
            }
        }
        .onDeleteCommand { askToDelete(selected) }
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        if let route = selected {
            RoutePanel(route: route,
                       verdict: store.verdicts[route.id],
                       checking: store.checking.contains(route.id),
                       lifter: lifter,
                       onLift: { lift(route) },
                       onCheck: { store.check(route) },
                       onToggle: { store.setEnabled(route.id, $0) })
        } else if store.unreadable {
            UnreadableRoutes(problem: store.problem ?? "", onReload: store.reload)
        } else if store.routes.isEmpty {
            Welcome(onAdd: { adding = Source.builtIn.first })
        } else {
            Text("Select a route")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selected: Route? {
        guard let id = selection else { return nil }
        return store.routes.first { $0.id == id }
    }

    // MARK: - actions

    private func canLift(_ route: Route) -> Bool {
        RoutePanel.canLift(route, verdict: store.verdicts[route.id], running: lifter.running)
    }

    private func lift(_ route: Route) {
        guard canLift(route) else { return }
        lifter.lift(route)
    }

    /// Never the one that is running: the run cannot be called off, and a
    /// report for a route that is no longer in the list has nowhere to go.
    private func askToDelete(_ route: Route?) {
        guard let route, lifter.running != route.id else { return }
        deleting = route
    }

    private func remove(_ route: Route) {
        deleting = nil
        store.remove(route.id)
        if selection == route.id {
            selection = store.routes.first?.id
        }
    }
}

// MARK: - rows

/// One route in the sidebar: its name, and what macOS said about the source.
struct RouteRow: View {
    let route: Route
    let verdict: Access.Verdict?
    let checking: Bool
    let lifting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if lifting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(route.enabled ? .primary : .secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Without this the longest name in the list decides how wide the
            // column wants to be.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help((route.source?.tilde ?? "(\(route.sourceID): not on this build's list)")
              + "\n" + route.destination.tilde)
    }

    private var symbol: String {
        switch verdict {
        case .readable: return "checkmark.circle"
        case .refused: return "lock.fill"
        case .missing: return "questionmark.folder"
        case nil: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch verdict {
        case .readable: return route.enabled ? .green : .secondary
        case .refused: return .orange
        case .missing, nil: return .secondary
        }
    }

    /// The three answers, in the words the sidebar has room for. "0 files"
    /// is written out rather than folded into "empty", because a folder that
    /// answered zero and a folder that refused to answer are the two cases
    /// this program exists to keep apart.
    private var status: String {
        let access: String
        if lifting {
            access = "lifting…"
        } else {
            switch verdict {
            case .readable(let n): access = n == 1 ? "1 file" : "\(n) files"
            case .refused: access = "refused"
            case .missing: access = "missing"
            case nil: access = checking ? "checking…" : "not checked"
            }
        }
        return route.enabled ? access : "off, " + access
    }
}

// MARK: - welcome

/// The pane when there are no routes.
struct Welcome: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No routes yet").font(.title3).bold()
            Text("paranco copies files out of a folder macOS protects into an ordinary "
                 + "one, along routes you set up here. It is the one program that holds "
                 + "Full Disk Access; whatever reads the destination needs no permission "
                 + "at all. Files travel one way, and nothing is ever written back to "
                 + "the source.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Divider().frame(width: 260).padding(.vertical, 4)

            Button(action: onAdd) {
                Label("Add a route from \(Source.builtIn.first?.name ?? "a source")",
                      systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("The folders this program may read are compiled into it. Adding one "
                 + "is a code change, on purpose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The pane when the route file is there and cannot be read.
///
/// Not the welcome pane. That one offers to add a route, and adding a route
/// to an empty list saves the list, which would write over the file that
/// could not be read: a hand edit with one bad comma would cost every route
/// in it. This pane offers the two things that help and nothing that writes.
struct UnreadableRoutes: View {
    let problem: String
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("The route list could not be read").font(.title3).bold()
            Text(problem)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            Text("Nothing is written to the file until it can be read again. Fix it, "
                 + "or move it aside, then read it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Routes.file])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button("Read again", action: onReload)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
