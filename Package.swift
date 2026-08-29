// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StemBouncer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StemBouncer", targets: ["StemBouncer"])
    ],
    targets: [
        .executableTarget(
            name: "StemBouncer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StemBouncerTests",
            dependencies: ["StemBouncer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
