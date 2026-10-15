// swift-tools-version:5.9
import PackageDescription

// The core library (parsers, firmware inspection, newflasher prompt handling)
// is plain Foundation so it builds and tests on Linux too. The SwiftUI app
// target only exists when the package is resolved on macOS.
var products: [Product] = [
    .library(name: "XperiaRescueCore", targets: ["XperiaRescueCore"]),
]

var targets: [Target] = [
    .target(name: "XperiaRescueCore"),
    .testTarget(name: "XperiaRescueCoreTests", dependencies: ["XperiaRescueCore"]),
]

#if os(macOS)
products.append(.executable(name: "XperiaRescue", targets: ["XperiaRescue"]))
targets.append(
    .executableTarget(
        name: "XperiaRescue",
        dependencies: ["XperiaRescueCore"],
        linkerSettings: [.linkedFramework("IOKit")]
    )
)
#endif

let package = Package(
    name: "XperiaRescue",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
