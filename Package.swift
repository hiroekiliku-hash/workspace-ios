// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WorkspaceCore", platforms: [.iOS(.v17)],
    products: [.library(name: "WorkspaceCore", targets: ["WorkspaceCore"])],
    targets: [.target(name: "WorkspaceCore", path: "Shared/Core"),
              .testTarget(name: "WorkspaceCoreTests", dependencies: ["WorkspaceCore"], path: "Tests/CoreTests")])
