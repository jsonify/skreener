// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Skreener",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Skreener",
            path: "Sources/Skreener",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        )
    ]
)
