import Foundation
import SwiftUI
import ParancoCore

/// The routes on disk, and what macOS said about each source.
///
/// Two things live here and both change rarely. The routes change when a
/// person adds or removes one. The verdicts change when a check comes back,
/// which happens a handful of times per session: on launch, after a lift, and
/// every time the window comes to the front, because coming back to it is what
/// somebody does after granting the permission in System Settings. Neither
/// rate needs the split a recorder makes for its level meter; a lift's counters
/// do, and they have an object of their own in Lifter.swift.
@MainActor final class RouteStore: ObservableObject {
    @Published private(set) var routes: [Route] = []

    /// What Access.check said about each source, by route. Absent means not
    /// asked yet, and the row says so rather than guessing either way.
    @Published private(set) var verdicts: [UUID: Access.Verdict] = [:]

    /// Checks in flight. Published because the buttons that start one should
    /// show it running, and because a second press while the first is out
    /// must not start a third.
    @Published private(set) var checking: Set<UUID> = []

    /// Something the route file could not do: be read, or be written.
    @Published var problem: String?

    /// True while the file on disk is one this store could not read. Nothing
    /// is written while it is. A save would replace a file somebody may have
    /// edited by hand and broken with one comma with the empty list that
    /// came out of the failed read, and every route in it would be gone.
    @Published private(set) var unreadable = false

    func reload() {
        do {
            routes = try Routes.load()
            problem = nil
            unreadable = false
        } catch {
            // A file that cannot be decoded is not the same as no file, and
            // showing an empty list for it would invite adding routes on top
            // of the broken one, which the next save would then overwrite.
            // The window keeps the welcome pane and the add menu away while
            // this is set; the guards below are the same rule at the store.
            routes = []
            unreadable = true
            problem = "The route list at \(Routes.file.tilde) could not be read: "
                    + error.localizedDescription
        }
        checkAll()
    }

    func add(_ route: Route) {
        guard !unreadable else { return }
        routes.append(route)
        persist()
        check(route)
    }

    /// Takes the route out of the list and nothing else. The source is never
    /// written to and the destination is left as it is: what was lifted stays
    /// where it landed.
    func remove(_ id: UUID) {
        guard !unreadable else { return }
        routes.removeAll { $0.id == id }
        verdicts[id] = nil
        persist()
    }

    func setEnabled(_ id: UUID, _ value: Bool) {
        guard !unreadable,
              let i = routes.firstIndex(where: { $0.id == id }),
              routes[i].enabled != value else { return }
        routes[i].enabled = value
        persist()
    }

    private func persist() {
        do {
            try Routes.save(routes)
            problem = nil
        } catch {
            problem = "The route list could not be written to \(Routes.file.tilde): "
                    + error.localizedDescription
        }
    }

    // MARK: - access

    func checkAll() {
        for route in routes { check(route) }
    }

    /// Ask macOS about one source, off the main thread.
    ///
    /// Access.check lists the folder. One listing is quick; the window asks
    /// for every route at once on launch and again each time it comes to the
    /// front, and a list that draws after the filesystem answers is a list
    /// that stalls on every activation. The old verdict stays on screen until
    /// the new one lands, so a check that changes nothing changes nothing.
    func check(_ route: Route) {
        guard !checking.contains(route.id) else { return }
        checking.insert(route.id)
        let id = route.id
        let source = route.source
        let sourceID = route.sourceID
        Task.detached(priority: .userInitiated) {
            // A route whose source is not on this build's list cannot be read,
            // and the reason belongs on screen rather than behind "missing".
            let verdict: Access.Verdict = source.map(Access.check)
                ?? .refused("\"\(sourceID)\" is not on the list of folders this build may read.")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checking.remove(id)
                // The route may have been deleted while the check was out.
                guard self.routes.contains(where: { $0.id == id }) else { return }
                self.verdicts[id] = verdict
            }
        }
    }
}
