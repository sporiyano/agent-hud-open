// swift-tools-version: 6.0
import PackageDescription

// The data libraries (Support and Core) build on macOS and Windows. The desktop interface and the application are
// AppKit and SwiftUI, so they exist only on macOS; the Windows interface is a separate shell over Core.

/// Off Apple platforms CryptoKit and the system SQLite are not there; these packages stand in for them.
let portable: TargetDependencyCondition = .when(platforms: [.windows, .linux])
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: portable)
let sqlite: Target.Dependency = .product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite",
                                         condition: portable)

var products: [Product] = [
    .library(name: "AgentHUDSupport", targets: ["AgentHUDSupport"]),
    .library(name: "AgentHUDCore", targets: ["AgentHUDCore"]),
]

var targets: [Target] = [
    .target(name: "AgentHUDSupport", dependencies: [crypto], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "AgentHUDCore", dependencies: ["AgentHUDSupport", crypto, sqlite], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "AgentHUDSupportTests", dependencies: ["AgentHUDSupport"]),
    .testTarget(name: "AgentHUDCoreTests", dependencies: ["AgentHUDCore", "AgentHUDSupport"],
                resources: [.copy("Providers/Kit/Zstandard/Fixtures")]),
]

#if os(macOS)
products += [
    .library(name: "AgentHUDDesktop", targets: ["AgentHUDDesktop"]),
    .executable(name: "AgentHUDOpen", targets: ["AgentHUDOpenApp"]),
]
targets += [
    .target(name: "AgentHUDDesktop", dependencies: ["AgentHUDCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "AgentHUDOpenApp", dependencies: ["AgentHUDDesktop", "AgentHUDCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "AgentHUDDesktopTests", dependencies: ["AgentHUDDesktop"]),
]
#endif

let package = Package(
    name: "AgentHUDOpen",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite.git", from: "1.0.0"),
    ],
    targets: targets
)
