// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OPTCGAltArtSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AltArtCore", targets: ["AltArtCore"]),
        .executable(name: "OPTCGAltArtSwitcher", targets: ["OPTCGAltArtSwitcher"]),
        .executable(name: "AltArtCoreValidation", targets: ["AltArtCoreValidation"])
    ],
    targets: [
        .target(name: "AltArtCore"),
        .executableTarget(name: "OPTCGAltArtSwitcher", dependencies: ["AltArtCore"]),
        .executableTarget(name: "AltArtCoreValidation", dependencies: ["AltArtCore"])
    ]
)
