// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sundog",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sundog",
            dependencies: ["CFairPlay"]
        ),
        // Third-party FairPlay code from UxPlay. See THIRD_PARTY_NOTICES.md.
        .target(
            name: "CFairPlay",
            exclude: ["playfair/LICENSE.md"],
            cSettings: [.unsafeFlags(["-w"])]
        ),
    ]
)
