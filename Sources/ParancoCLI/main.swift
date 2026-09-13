// paranco: the command-line door into the same core the window uses.
//
// Worth knowing before scripting it: run from a terminal, this binary is charged
// the terminal's permissions. `paranco check` therefore says "refused" on a
// protected folder even after Paranco.app has been granted access, because the
// grant belongs to the application, not to this process. That is macOS
// attributing access to whoever asked, and it is the reason the agent runs the
// application's own binary rather than this one.
//
// A route names its source by identifier, never by path. `paranco sources` lists
// the identifiers that exist; there is no command that adds one, because adding
// a folder this program may read is a code change, on purpose.

import Foundation
import ParancoCore

func usage() -> Never {
    print("""
    paranco: lifts files out of the folders macOS protects, along routes you define.

      paranco sources                       the folders this build may read
      paranco routes                        the routes on disk
      paranco add <source-id> <folder> [--name N] [--ext a,b]
      paranco remove <name>
      paranco check [<folder>]              readable, refused or missing (defaults to every route)
      paranco lift [<name>]                 run one route, or all of them, once
      paranco watch [seconds]               run every route every N seconds (default 300)
      paranco agent status|remove           the launchd agent (install it from Paranco.app)

    Routes live in \(Routes.file.path). A destination must be a real folder inside
    your home, outside ~/Library, on this Mac's own disk.
    """)
    exit(2)
}

func describe(_ verdict: Access.Verdict) -> String {
    switch verdict {
    case .readable(let n): return "readable, \(n) files"
    case .refused(let why): return "refused: \(why)"
    case .missing: return "missing"
    }
}

func lift(_ route: Route) {
    print("── \(Agent.sanitised(route.name))")
    let report = Lift.run(route) { event in
        switch event {
        case .copied(let name, let bytes): print("   copied \(Agent.sanitised(name)) (\(bytes / 1024) KB)")
        case .unchanged: break
        case .skipped(let name, let reason): print("   skipped \(Agent.sanitised(name)): \(reason)")
        case .failed(let name, let reason): print("   failed \(Agent.sanitised(name)): \(reason)")
        case .notHere(let name, let reason): print("   not here \(Agent.sanitised(name)): \(reason)")
        }
    }
    if let why = report.refused {
        print("   \(why)")
        return
    }
    print("   \(report.copied) copied, \(report.unchanged) already there, "
          + "\(report.skipped) skipped, \(report.failed) failed, \(report.notHere) not on this Mac")
    if let advice = report.notHereAdvice { print("   \(advice)") }
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

do {
    let loaded = try Routes.loadReporting()
    var routes = loaded.routes
    for note in loaded.notes { print("note: \(note)") }
    switch command {
    case "sources":
        for s in Source.builtIn {
            print("\(s.id)\n    \(s.folder.path)\n    \(s.note)")
        }

    case "check":
        let folders = args.isEmpty ? routes.compactMap(\.source) : args.map { URL(fileURLWithPath: $0) }
        if folders.isEmpty { print("no routes yet. `paranco add voice-memos ~/Recordings` makes one.") }
        for folder in folders {
            print("\(Agent.sanitised(folder.path)): \(Agent.sanitised(describe(Access.check(folder))))")
        }
        print("\n\(Access.whyAnApplication)")

    case "routes":
        if routes.isEmpty { print("no routes. `paranco add voice-memos ~/Recordings` makes one.") }
        for r in routes {
            let ext = r.effectiveExtensions.isEmpty ? "every file" : r.effectiveExtensions.sorted().joined(separator: ",")
            let from = r.source?.path ?? "(\(r.sourceID): not on this build's list)"
            print("\(r.enabled ? "•" : "○") \(Agent.sanitised(r.name))\n    \(Agent.sanitised(from))"
                  + "\n  → \(Agent.sanitised(r.destination.path))   [\(ext)]")
        }

    case "add":
        let name = option("--name", in: &args)
        let ext = option("--ext", in: &args).map { Set($0.split(separator: ",").map(String.init)) } ?? []
        guard args.count == 2 else { usage() }
        guard let source = Source.resolve(args[0]) else {
            print("\"\(args[0])\" is not a source this build may read. `paranco sources` lists them.")
            exit(1)
        }
        let destination = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        if case .failure(let why) = Destination.validate(destination) {
            print(why.message); exit(1)
        }
        let route = Route(name: name ?? "\(source.name) → \(destination.lastPathComponent)",
                          sourceID: source.id, destination: destination, extensions: ext)
        routes.append(route)
        try Routes.save(routes)
        print("added \(Agent.sanitised(route.name))\n  \(source.folder.path)\n→ \(Agent.sanitised(destination.path))")

    case "remove":
        guard let name = args.first else { usage() }
        let before = routes.count
        routes.removeAll { $0.name == name }
        guard routes.count < before else { print("no route called \(name)"); exit(1) }
        try Routes.save(routes)
        print("removed \(name)")

    case "lift":
        let chosen = args.first.map { name in routes.filter { $0.name == name } } ?? routes
        if chosen.isEmpty { print("nothing to lift"); exit(1) }
        chosen.filter(\.enabled).forEach(lift)

    case "watch":
        let seconds = args.first.flatMap(Double.init) ?? 300
        print("every \(Int(seconds)) s, ctrl-c to stop")
        while true {
            (try? Routes.load())?.filter(\.enabled).forEach(lift)
            Thread.sleep(forTimeInterval: seconds)
        }

    case "agent":
        switch args.first {
        case "status":
            print(Agent.isInstalled ? "installed: \(Agent.plist.path)\nlog: \(Agent.log.path)" : "not installed")
        case "remove":
            try Agent.remove(); print("removed")
        default:
            print("install it from Paranco.app, so the permission is granted to one thing.\n  paranco agent status | remove")
        }

    default:
        usage()
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
