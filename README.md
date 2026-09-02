<div align="center">

<img src="docs/img/mark.svg" width="72" alt="The paranco mark: a wheel, a rope and a load">

# paranco

**A small macOS application that holds Full Disk Access so that nothing else has to.**

It copies files one way, along routes you write down, from a folder macOS protects into an ordinary
folder that any program can read: one allowlisted source, a validated destination, nothing written back.

<a href="#install-and-the-first-route"><img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white" alt="macOS 14 or newer"></a>
<a href="#licence"><img src="https://img.shields.io/badge/licence-MIT-green" alt="MIT licence"></a>

</div>

---

```bash
./build.sh                       # makes Paranco.app
open Paranco.app                 # after adding it to Full Disk Access
paranco add voice-memos ~/Recordings   # a route, from the command line
```

## Why it exists

macOS keeps some folders closed to every process that has not been granted Full Disk Access.
The Voice Memos library is one of them: the recordings are yours and they sit on your own disk,
but a program that wants to read them cannot list the folder. The obvious fix is to grant Full
Disk Access to that program directly. For most programs that means granting it to an interpreter
or a runtime, and through it to every package installed beside it, none of which asked for it.

paranco is the other fix. It is a separate application whose only job is to hold that one
permission and to copy new files out along routes, each of which names one allowlisted source
and one destination folder of your choosing. Whatever reads the destination reads an ordinary
folder and is granted nothing. It is a controlled lift.

Two things were measured while building it, and they decide the shape of the tool.

**An access is charged to the process that asked for it.** Driving Finder or System Events from a
terminal tests the terminal's permission, not theirs, so a permission cannot be borrowed by
scripting an application that has one. The holder has to be an application with its own identity,
started by launchd or by a person. That is why paranco is an application bundle rather than a
script, and why its agent runs the bundle's own executable.

**Asked through System Events, a protected folder reports itself as empty rather than refused.**
A control on a folder with sixteen files returned sixteen; the Voice Memos library returned zero.
A program that looks for files and finds none would tell somebody with a library full of
recordings that there is nothing to do, and would go on saying so. Asked directly through the
filesystem, the same folder refuses with a permission error, and that difference is what
[`Access.check`](Sources/ParancoCore/Access.swift) is built on: it asks directly and answers with
one of three verdicts, readable with a file count, refused with the sentence a person needs, or
missing. Empty and refused are never the same answer.

## The security model

A route does not carry a path to the folder it reads. It carries an identifier, `sourceID`, and
the identifier is resolved only against [`Source.builtIn`](Sources/ParancoCore/Source.swift), a
list compiled into the binary. Today that list has one entry, `voice-memos`. Nothing on the
machine can add a source to it: not a file, not the window, not the command line. Adding one
means editing the source file and rebuilding, and because the bundle carries an ad-hoc signature,
a rebuild also means granting Full Disk Access again. That cost is deliberate: a reviewer sees
the folder being added, and a person consents to it again.

The reason this exists at all: `routes.json` lives in a folder any process running as the user
can write. An earlier version of paranco named a route's source by path in that file, which meant
any such process could point the privileged agent at Messages, Mail or Safari and have it copy
that data into a folder the attacker could then read. Naming sources by identifier, resolved only
against a compiled-in list, closes that: writing to `routes.json` can select among the folders
the binary already allows, and nothing else.

A destination is checked before a single byte is written
([`Destination.validate`](Sources/ParancoCore/Destination.swift)): it must be a real folder inside
your home directory, outside `~/Library`, not inside any source, on this Mac's own disk rather
than a network or removable volume, with no symbolic link anywhere along its path and no `.` or
`..` component. The copy itself
([`Lift.copySafely`](Sources/ParancoCore/Lift.swift)) writes into a fresh file created with
`O_EXCL` and `O_NOFOLLOW`, mode 0600, no execute bit, no extended attributes carried over, then
renames it into place; anything already sitting at the target name, symlink included, is replaced
by the rename and never followed. Folders are created 0700, one component at a time, refusing to
pass through a symlink. `routes.json` itself is written 0600 inside a 0700 folder.

Say the honest part plainly: a program running as you can still write `routes.json`. What it
cannot do is use that write to name a folder the binary does not already allow. The list is the
boundary, not the file.

## How it works

### Sources

A source is an entry on the compiled-in list: an identifier, a name, the folder it points at, and
the extensions it carries by default. `paranco sources` prints the list this build has. There is
no way to add one from outside the source code, and there will not be.

### Routes

A route names one source by identifier, one destination, and which files count. It is
deliberately narrow. There is no way to express "everything under Library" and there will not be:
the point of the program is that it holds a permission that could read anything and uses it to
read one thing.

```
name          what the route is called
sourceID      an identifier from the compiled-in list, e.g. "voice-memos"
destination   an ordinary folder, created if it is not there
extensions    lower-case, without the dot; empty means the source's own list
enabled       a disabled route is kept but never run
```

A route carries the regular files at the top level of its source, skipping hidden files and not
descending into subfolders. The destination is created if it does not exist.

### A lift

Running a route once is a lift. For each file the source holds and the route carries:

- Same name and same size in the destination means already there, and the file is left alone.
- A different size means the copy is stale, and the file is copied again. That is what happens
  when a recording that was still being written the first time is seen again, finished.
- A file whose size changes between two looks, two seconds apart, is still being written. It is
  skipped and picked up next time. Copying it now would deliver half of it, and by name the half
  would then be "already there".
- Nothing is written to the source. Not a marker, not a ledger, nothing. The program holds a
  permission that could write anywhere and writes only into a validated destination.

The bookkeeping is the destination itself: what is there is what has been lifted. There is no
database to fall out of step with the folder.

### The agent

A launchd agent runs every enabled route on a timer, every five minutes by default, and once
when it is loaded, which is at install and at every login. It is what makes the whole thing
unattended: a recording that reaches the library is lifted on the next run, with no window open.

It runs the application bundle's own executable, `Paranco.app/Contents/MacOS/Paranco`, with
`--agent`, not a separate binary. That is the first measured fact applied: Full Disk Access is
granted to one thing, and used by the window and by the agent alike. Started by launchd the
process has its own identity; started from a terminal it would be the terminal's permission being
tested, which is why the CLI cannot install it and the window can.

In `--agent` mode the executable runs every enabled route once and exits. It prints a timestamped
line only when a route was refused or when something was copied or failed, so the log stays quiet
when nothing happened. Every name that reaches the log is sanitised of control characters first,
so a file or route name cannot forge a line or repaint the terminal, and the log is trimmed once
it passes one megabyte. launchd sends that output to
`~/Library/Application Support/paranco/agent.log`.

## Install and the first route

macOS 14 or newer, and a Swift 6 toolchain (Xcode 16 or the matching command line tools), which is
what `Package.swift` asks for. There is no Xcode project: SwiftPM builds the executable and
`build.sh` assembles the bundle around it, so the whole thing stays in git as text.

```bash
git clone https://github.com/nerln/paranco
cd paranco
./build.sh
```

That leaves `Paranco.app` in the repository folder, built for release; `./build.sh debug` builds
the debug configuration instead. The first build also generates the icon, through `make-icon.sh`,
which needs `swiftc` and `iconutil`. Then:

1. Open System Settings > Privacy & Security > Full Disk Access and add `Paranco.app` to the
   list. Nothing else needs it.
2. `open Paranco.app`.
3. Add a route: pick a source from the list and a destination folder, for example
   `~/Recordings`.
4. Install the agent from the window.

The command line can do part of this. Build it with `swift build -c release --product paranco`,
which leaves the binary at `.build/release/paranco`. `paranco add voice-memos ~/Recordings` makes
the same route, and `paranco agent status` says whether the agent is installed. Installing the
agent is the one step that has no command-line equivalent, on purpose: the agent must run the
bundle's executable and the bundle must be the thing that was granted access, so the window,
which is that bundle, is where it is installed from.

`swift test` runs the core's tests, which cover the copy, the "already there" rule, the untouched
source, the destination checks, and the difference between a refused folder and an empty one.

## The command line

`paranco` is a second door into the same core the window uses. Every subcommand:

```
paranco sources                       the folders this build may read
paranco routes                        the routes on disk
paranco add <source-id> <folder> [--name N] [--ext a,b]
                                       a route from a source identifier and a destination
paranco remove <name>                 removes every route with that name
paranco check [<folder>]              readable, refused or missing (defaults to every route)
paranco lift [<name>]                 run one route, or all of them, once
paranco watch [seconds]                run every route every N seconds (default 300)
paranco agent status|remove           the launchd agent (install it from Paranco.app)
```

Worth knowing before scripting it: run from a terminal, this binary is charged the terminal's
permissions. `paranco check` on a protected folder therefore says refused even after Paranco.app
has been granted access, because the grant belongs to the application, not to this process. That
is not a bug in either. Use the application or the agent for routes out of protected folders, and
the command line for routes into folders the terminal can already read, or for editing the route
list. `check` prints the reason after its verdicts, so nobody has to go looking for it.

## The route file

Routes live in `~/Library/Application Support/paranco/routes.json`. It is a JSON file rather than
a preference so it can be read, diffed and edited with anything, and so that a route added from
the window is the same route the agent and the command line see. It is written through a rename
of a `.part` file, so a reader never sees half of it, kept at mode 0600 inside a 0700 folder.
`paranco` with no arguments prints the path at the end of its usage text.

The file is an array of routes. One, as `paranco add voice-memos ~/Recordings` writes it:

```json
[
  {
    "destination" : "file:\/\/\/Users\/you\/Recordings\/",
    "enabled" : true,
    "extensions" : [
      "m4a",
      "aiff",
      "aifc",
      "wav",
      "caf",
      "mp3"
    ],
    "id" : "56D40FCE-23CC-42A4-9C4E-DF7D31CAE3CE",
    "name" : "Voice Memos → Recordings",
    "sourceID" : "voice-memos"
  }
]
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | a UUID; `paranco add` makes one for you |
| `name` | string | what `lift` and `remove` match on |
| `sourceID` | string | an identifier from the compiled-in list; resolved through `Source.resolve`, never a path |
| `destination` | string | the ordinary folder, as a `file://` URL |
| `extensions` | array of strings | lower-case, no dot; `[]` means the source's own list; the order carries no meaning |
| `enabled` | boolean | `false` keeps the route on disk and out of every run |

An older file that named its source by path is still read: an entry whose path matches one of the
folders on the compiled-in list is migrated to that identifier, and any other is dropped, with a
note printed to say which route and why (`Routes.loadReporting`).

Two things to know when editing it by hand. `destination` is a `file://` URL, so a space is
written `%20`, and the encoder escapes each `/` as `\/`, which JSON permits and which you need not
reproduce. And `enabled` has no command-line switch today: the window has a toggle for it, and
from the command line the file is the only way to turn a route off without removing it.

## Limits

- macOS only, by nature. The permission and the protected folders are macOS's.
- One source on the compiled-in list today, the Voice Memos library. Any other route to it can be
  written with `paranco add` or in the file, and the copy is the same; a new source is a code
  change.
- The bundle carries an ad-hoc signature. That identifies the binary by its hash, so every rebuild
  is a new application to the privacy database and the grant has to be given again: after each
  `./build.sh`, add `Paranco.app` to Full Disk Access again. That is the price of not having a
  Developer ID.
- No Developer ID yet, so no notarised download either. It is built from the repository.

## Licence

MIT. See [LICENSE](LICENSE).
