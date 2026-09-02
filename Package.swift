// swift-tools-version: 6.0
import PackageDescription

// Three products from one core. The library is the thing; the two executables
// are two doors into it. The window is for a person, the command is for a script
// and for the launch agent, and both call the same forty lines that actually
// move a file.
let package = Package(
    name: "paranco",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParancoCore", targets: ["ParancoCore"]),
        // Two executables that must not share a name on a case-insensitive
        // filesystem, which is what a Mac has: "paranco" and "Paranco" would be
        // the same file in .build. The app binary is ParancoApp and build.sh
        // puts it inside Paranco.app under the name people see.
        .executable(name: "paranco", targets: ["ParancoCLI"]),
        .executable(name: "ParancoApp", targets: ["ParancoApp"]),
    ],
    targets: [
        .target(
            name: "ParancoCore",
            path: "Sources/ParancoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ParancoCLI",
            dependencies: ["ParancoCore"],
            path: "Sources/ParancoCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ParancoApp",
            dependencies: ["ParancoCore"],
            path: "Sources/ParancoApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParancoCoreTests",
            dependencies: ["ParancoCore"],
            path: "Tests/ParancoCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
