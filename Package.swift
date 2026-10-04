// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQuota",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIQuota", targets: ["AIQuota"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "AIQuota", exclude: ["Resources/Info.plist"]),
        .testTarget(
            name: "AIQuotaTests",
            dependencies: ["AIQuota"]
        )
    ]
)
