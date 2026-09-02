import Foundation
import SwiftUI
import ParancoCore

/// The counters that move while a lift runs.
///
/// Kept apart from Lifter for the reason a recorder keeps its level meter apart
/// from its recorder: SwiftUI redraws every view observing an object that
/// changed, and a library of a few hundred recordings produces a few hundred
/// events in the first second of a run while the ones already there are
/// counted. Only the report in the detail pane observes this object. The
/// sidebar and the toolbar observe Lifter, which changes twice per run.
@MainActor final class LiftProgress: ObservableObject {
    @Published private(set) var copied = 0
    @Published private(set) var unchanged = 0
    @Published private(set) var skipped = 0
    @Published private(set) var failed = 0
    @Published private(set) var bytes = 0
    /// The last file that was copied, skipped or failed, and why. A run that
    /// is sitting in the two-second settle on a large file would otherwise
    /// look stuck.
    @Published private(set) var lastLine = ""

    private var applied = 0
    /// The run whose snapshots are welcome. Anything from another run is not.
    private var run = UUID()

    /// Everything the report shows, carried across from the worker in one
    /// piece so the counters never disagree with each other mid-draw.
    struct Snapshot: Sendable {
        /// How many failed files are named. The report has room for a short
        /// list, and in a run where everything fails the reason is the same
        /// for every file.
        static let namedFailures = 20

        let run: UUID
        var sequence = 0
        var copied = 0
        var unchanged = 0
        var skipped = 0
        var failed = 0
        var bytes = 0
        var lastLine = ""
        /// Name and reason for the first failures. The agent prints only a
        /// count, so this window is the one place the names are seen.
        var failures: [String] = []

        mutating func take(_ event: LiftEvent) {
            sequence += 1
            switch event {
            case .copied(let name, let size):
                copied += 1
                bytes += size
                lastLine = "copied \(name)"
            case .unchanged:
                unchanged += 1
            case .skipped(let name, let reason):
                skipped += 1
                lastLine = "skipped \(name): \(reason)"
            case .failed(let name, let reason):
                failed += 1
                lastLine = "failed \(name): \(reason)"
                if failures.count < Self.namedFailures {
                    failures.append("\(name): \(reason)")
                }
            }
        }
    }

    func apply(_ snapshot: Snapshot) {
        // Each hop to the main actor is its own task, and two tasks queued
        // one after the other are not promised to run in that order. The
        // counters only ever grow, so an older snapshot arriving late would
        // show them shrinking for a frame. The sequence number drops it.
        //
        // The run token keeps two runs apart. A straggler from the previous
        // run landing after reset would pass the sequence guard with a
        // number the new run then has to climb past, and until it did every
        // snapshot of the new run would be dropped as stale.
        guard snapshot.run == run, snapshot.sequence >= applied else { return }
        applied = snapshot.sequence
        copied = snapshot.copied
        unchanged = snapshot.unchanged
        skipped = snapshot.skipped
        failed = snapshot.failed
        bytes = snapshot.bytes
        lastLine = snapshot.lastLine
    }

    func reset(for run: UUID) {
        self.run = run
        applied = 0
        copied = 0
        unchanged = 0
        skipped = 0
        failed = 0
        bytes = 0
        lastLine = ""
    }
}

/// Runs a route from the window.
///
/// Lift.run blocks: it lists the source, and for every new file it sleeps for
/// the settle time before copying. On the main thread that would freeze the
/// window for two seconds per new file, so it runs in a detached task and
/// reports back through LiftProgress.
@MainActor final class Lifter: ObservableObject {
    /// Live counters, observed only where they are drawn.
    let live = LiftProgress()

    /// The route being lifted, if any. Changes twice per run.
    @Published private(set) var running: UUID?

    /// The last finished run of each route, so the numbers are still there
    /// after selecting something else and coming back.
    @Published private(set) var reports: [UUID: Finished] = [:]

    struct Finished: Equatable {
        let report: LiftReport
        let when: Date
        let seconds: Double
        /// Name and reason for the first failures. The count is in the report.
        let failures: [String]
    }

    /// One run at a time. The pane has room for one report, and the second
    /// most likely press is the same button again, which would start a copy
    /// of the same route racing the first one into the same destination.
    func lift(_ route: Route) {
        guard running == nil else { return }
        running = route.id
        let run = UUID()
        live.reset(for: run)
        let live = self.live
        let started = Date()

        // Not a weak capture on the task itself: a weak reference is a
        // mutable capture, and the compiler is right that mutable state has
        // no place in a detached closure. The main-actor hop at the end holds
        // it weakly, which is where it is read.
        Task.detached(priority: .userInitiated) {
            var tally = LiftProgress.Snapshot(run: run)
            var lastSent = Date.distantPast
            let report = Lift.run(route) { event in
                tally.take(event)
                // Hand over at most ten times a second. The events for files
                // already there arrive as fast as the filesystem can answer,
                // and a hop to the main actor for each of them would queue up
                // hundreds of redraws that nobody could read.
                let now = Date()
                guard now.timeIntervalSince(lastSent) >= 0.1 else { return }
                lastSent = now
                let snapshot = tally
                Task { @MainActor in live.apply(snapshot) }
            }
            let final = tally
            let seconds = Date().timeIntervalSince(started)
            await MainActor.run { [weak self] in
                live.apply(final)
                guard let self else { return }
                self.reports[route.id] = Finished(report: report, when: Date(),
                                                  seconds: seconds, failures: final.failures)
                self.running = nil
            }
        }
    }
}
