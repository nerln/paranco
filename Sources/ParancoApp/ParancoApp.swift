import SwiftUI
import ParancoCore

/// The window, and the agent mode that shares its binary.
///
/// One executable for both so that Full Disk Access is granted once, to this
/// bundle, and used by the window and by launchd alike. `--agent` runs every
/// enabled route once and exits; it is what the launch agent calls.
@main
struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--agent") {
            // Everything printed here lands in the agent log. Names pass through
            // Agent.sanitised so a file called something with a newline in it
            // cannot forge a line, and the log is trimmed first so a route that
            // fails every five minutes does not fill the disk one line at a time.
            Agent.trimLog()
            let stamp = ISO8601DateFormatter().string(from: Date())
            let loaded = (try? Routes.loadReporting()) ?? (routes: [], notes: [])
            for note in loaded.notes {
                print("\(stamp) routes.json: \(Agent.sanitised(note))")
            }
            for route in loaded.routes where route.enabled {
                let name = Agent.sanitised(route.name)
                var failures: [String] = []
                let report = Lift.run(route) { event in
                    if case .failed(let file, let reason) = event {
                        failures.append("\(Agent.sanitised(file)): \(Agent.sanitised(reason))")
                    }
                }
                if let why = report.refused {
                    print("\(stamp) \(name): \(Agent.sanitised(why))")
                } else if report.copied > 0 || report.failed > 0 {
                    print("\(stamp) \(name): \(report.copied) copied, \(report.failed) failed")
                    for line in failures.prefix(20) { print("\(stamp)   \(line)") }
                }
            }
            exit(0)
        }
        ParancoApp.main()
    }
}

struct ParancoApp: App {
    var body: some Scene {
        WindowGroup("Paranco") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 600)
        .commands {
            // The menu items post and the window listens. The menu does not
            // need to know which route is selected or whether one is lifting;
            // the window does, and it applies the same rules as its buttons.
            CommandGroup(replacing: .newItem) {
                Button("Add route…") {
                    NotificationCenter.default.post(name: .parancoAddRoute, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Route") {
                Button("Lift now") {
                    NotificationCenter.default.post(name: .parancoLift, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Check again") {
                    NotificationCenter.default.post(name: .parancoCheck, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Delete route…") {
                    NotificationCenter.default.post(name: .parancoDelete, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the menu commands. The window listens.
    static let parancoAddRoute = Notification.Name("dev.nerelli.paranco.add-route")
    static let parancoLift = Notification.Name("dev.nerelli.paranco.lift")
    static let parancoCheck = Notification.Name("dev.nerelli.paranco.check")
    static let parancoDelete = Notification.Name("dev.nerelli.paranco.delete")
}
