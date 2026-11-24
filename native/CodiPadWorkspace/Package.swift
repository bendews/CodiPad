// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodiPadWorkspace",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CodiPadWorkspace", targets: ["CodiPadWorkspace"])
    ],
    targets: [
        .target(name: "CodiPadWorkspace"),
        .testTarget(name: "CodiPadWorkspaceTests", dependencies: ["CodiPadWorkspace"])
    ]
)
