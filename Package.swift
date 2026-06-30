// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HuaweiNotesNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "HuaweiNotesNative",
            targets: ["HuaweiNotesNative"]
        )
    ],
    targets: [
        .target(
            name: "HuaweiNotesCore"
        ),
        .executableTarget(
            name: "HuaweiNotesNative",
            dependencies: ["HuaweiNotesCore"]
        ),
        .testTarget(
            name: "HuaweiNotesCoreTests",
            dependencies: ["HuaweiNotesCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework",
                    "Testing",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
