// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "JarvisCore"),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .executableTarget(
            name: "Jarvis",
            dependencies: ["JarvisCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "Sources/Jarvis/Info.plist",
                ])
            ]
        ),
    ]
)
