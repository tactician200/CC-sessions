// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessions",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeSessions",
            path: "Sources/ClaudeSessions",
            // en/es string tables: copied into Contents/Resources by build-app.sh
            // and read through Bundle.main (L10n.swift), not a SwiftPM resource bundle.
            exclude: ["Localization"]
        )
    ]
)
