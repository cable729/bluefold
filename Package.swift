// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "pdf-app",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .library(name: "ReaderPersistence", targets: ["ReaderPersistence"]),
        .library(name: "CalibreKit", targets: ["CalibreKit"]),
        .library(name: "SearchIndexKit", targets: ["SearchIndexKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .library(name: "ReaderUI", targets: ["ReaderUI"]),
        .executable(name: "calibre-ls", targets: ["calibre-ls"]),
        .executable(name: "pdfindex", targets: ["pdfindex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Test-only: TestClock for deterministic testing of time-based code
        // (the autosave debounce). Production uses the stdlib `Clock` protocol.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
        // Dependency injection for the cross-cutting leaves (clock, date,
        // logger, filesystem, PDF rendering) — see docs/TESTING.md. ReaderCore
        // stays dependency-free; the DependencyValues keys live in ReaderUI.
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
    ],
    targets: [
        // Pure data models: tabs, navigation history, session snapshots, themes.
        .target(name: "ReaderCore"),

        // Overlay library database: tags, collections, bookmarks, reading state.
        .target(
            name: "ReaderPersistence",
            dependencies: [
                "ReaderCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Read-only access to Calibre's metadata.db.
        .target(
            name: "CalibreKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),

        // Full-text search indexing (FTS5) over PDF text.
        .target(
            name: "SearchIndexKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),

        // CloudKit sync engine behind a transport protocol.
        .target(
            name: "SyncKit",
            dependencies: ["ReaderPersistence"]
        ),

        // SwiftUI views, view models, and PDFView wrappers shared by macOS/iOS apps.
        .target(
            name: "ReaderUI",
            dependencies: [
                "ReaderCore",
                "ReaderPersistence",
                "CalibreKit",
                "SearchIndexKit",
                "SyncKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),

        .executableTarget(name: "calibre-ls", dependencies: ["CalibreKit"]),
        .executableTarget(name: "pdfindex", dependencies: ["SearchIndexKit"]),

        .testTarget(
            name: "ReaderCoreTests",
            dependencies: [
                "ReaderCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        .testTarget(name: "ReaderPersistenceTests", dependencies: ["ReaderPersistence"]),
        .testTarget(name: "CalibreKitTests", dependencies: ["CalibreKit"]),
        .testTarget(name: "SearchIndexKitTests", dependencies: ["SearchIndexKit"]),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit", "ReaderPersistence"]),
        .testTarget(
            name: "ReaderUITests",
            dependencies: [
                "ReaderUI",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
    ]
)
