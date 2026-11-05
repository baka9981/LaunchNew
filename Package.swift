// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchNew",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "LaunchNew",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LaunchNew",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in LaunchNew.app/Contents/Frameworks by scripts/build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LaunchNewTests",
            dependencies: ["LaunchNew"],
            path: "Tests/LaunchNewTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
