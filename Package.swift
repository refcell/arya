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
        .target(
            name: "AryaEval",
            dependencies: ["AryaAdapters", "AryaCore", "AryaLedger", "AryaMemory", "AryaRuntime"]),
        .target(
            name: "Arya",
            dependencies: [
                "AryaCore", "AryaLedger", "AryaAdapters", "AryaMemory", "AryaRuntime", "AryaEval",
            ]),
        .target(name: "AryaDesign"),

        // `arya` CLI. The target is not named `arya` because it would collide with the
        // `Arya` library on case-insensitive file systems; the product keeps the name.
        .executableTarget(name: "AryaCLI", dependencies: ["Arya"]),
        .executableTarget(name: "AryaApp", dependencies: ["Arya", "AryaDesign"]),
        .executableTarget(name: "AryaFakeAdapter", dependencies: ["AryaAdapters"]),
        .executableTarget(name: "AryaExecAdapter", dependencies: ["AryaAdapters"]),
        // Test helper that appends to a ledger from a child process (AryaLedgerTests).
        .executableTarget(name: "AryaLedgerWriter", dependencies: ["AryaCore", "AryaLedger"]),

        .testTarget(name: "AryaCoreTests", dependencies: ["AryaCore"], exclude: ["Fixtures"]),
        .testTarget(
            name: "AryaLedgerTests", dependencies: ["AryaCore", "AryaLedger", "AryaLedgerWriter"],
            exclude: ["Fixtures"]),
        .testTarget(
            name: "AryaAdaptersTests",
            dependencies: ["AryaAdapters", "AryaFakeAdapter", "AryaExecAdapter"],
            exclude: ["Fixtures"]),
        .testTarget(
            name: "AryaMemoryTests", dependencies: ["AryaCore", "AryaLedger", "AryaMemory"],
            exclude: ["Fixtures"]),
        .testTarget(name: "AryaRuntimeTests", dependencies: ["AryaRuntime"]),
        .testTarget(
            name: "AryaEvalTests",
            dependencies: [
                "AryaAdapters", "AryaCore", "AryaLedger", "AryaMemory", "AryaRuntime", "AryaEval",
            ],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "AryaTests",
            dependencies: [
                "Arya", "AryaCore", "AryaLedger", "AryaAdapters", "AryaRuntime", "AryaEval",
            ]),
        .testTarget(name: "AryaDesignTests", dependencies: ["AryaDesign"]),
        .testTarget(
            name: "AryaCLITests", dependencies: ["AryaCLI", "Arya", "AryaAdapters", "AryaCore"]),
        // Tests the app's feature view models; executable targets are testable on macOS.
        .testTarget(name: "AryaAppTests", dependencies: ["AryaApp"]),
    ]
)
