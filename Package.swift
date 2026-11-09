// swift-tools-version: 6.0
import PackageDescription

// Dependencies point down the stack:
// AryaCore <- AryaLedger <- {AryaAdapters, AryaMemory} <- AryaRuntime <- AryaEval <- Arya
// Arya <- {arya CLI, AryaApp}; AryaApp also uses AryaDesign.
// This package has no third-party dependencies; `just tidy` enforces that.
let package = Package(
    name: "arya",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Arya", targets: ["Arya"]),
        .library(name: "AryaDesign", targets: ["AryaDesign"]),
        .executable(name: "arya", targets: ["AryaCLI"]),
        .executable(name: "AryaApp", targets: ["AryaApp"]),
        .executable(name: "arya-fake-adapter", targets: ["AryaFakeAdapter"]),
        .executable(name: "arya-exec-adapter", targets: ["AryaExecAdapter"]),
    ],
    targets: [
        .target(name: "AryaCore"),
        .target(name: "AryaLedger", dependencies: ["AryaCore"]),
        .target(name: "AryaAdapters", dependencies: ["AryaCore", "AryaLedger"]),
        .target(name: "AryaMemory", dependencies: ["AryaCore", "AryaLedger"]),
        .target(
            name: "AryaRuntime",
            dependencies: ["AryaCore", "AryaLedger", "AryaAdapters", "AryaMemory"]
        ),
        .target(name: "AryaEval", dependencies: ["AryaCore", "AryaRuntime"]),
        .target(name: "Arya", dependencies: ["AryaCore", "AryaRuntime", "AryaEval"]),
        .target(name: "AryaDesign"),

        // `arya` CLI. The target is not named `arya` because it would collide with the
        // `Arya` library on case-insensitive file systems; the product keeps the name.
        .executableTarget(name: "AryaCLI", dependencies: ["Arya"]),
        .executableTarget(name: "AryaApp", dependencies: ["Arya", "AryaDesign"]),
        .executableTarget(name: "AryaFakeAdapter", dependencies: ["AryaAdapters"]),
        .executableTarget(name: "AryaExecAdapter", dependencies: ["AryaAdapters"]),

        .testTarget(name: "AryaCoreTests", dependencies: ["AryaCore"]),
        .testTarget(name: "AryaLedgerTests", dependencies: ["AryaLedger"]),
        .testTarget(name: "AryaAdaptersTests", dependencies: ["AryaAdapters"]),
        .testTarget(name: "AryaMemoryTests", dependencies: ["AryaMemory"]),
        .testTarget(name: "AryaRuntimeTests", dependencies: ["AryaRuntime"]),
        .testTarget(name: "AryaEvalTests", dependencies: ["AryaEval"]),
        .testTarget(name: "AryaTests", dependencies: ["Arya"]),
        .testTarget(name: "AryaDesignTests", dependencies: ["AryaDesign"]),
        .testTarget(name: "AryaCLITests", dependencies: ["AryaCLI"]),
    ]
)
