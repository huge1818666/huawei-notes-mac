// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HuaweiNotesNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "HuaweiNotesNative",
            targets: ["HuaweiNotesNative"]
        )
    ],
    targets: [
        .executableTarget(
            name: "HuaweiNotesNative"
        )
    ]
)
