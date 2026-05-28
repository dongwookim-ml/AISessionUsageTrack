// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AISessionUsageTrack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AISessionUsageTrack",
            path: "Sources/AISessionUsageTrack"
        )
    ]
)
