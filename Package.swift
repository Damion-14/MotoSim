// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotoSimPhysics",
    platforms: [.macOS(.v13), .iOS("18.0")],
    targets: [
        .target(name: "MotoSimPhysics", path: "MotoSim/Physics"),
        .testTarget(name: "MotoSimPhysicsTests", dependencies: ["MotoSimPhysics"], path: "Tests")
    ]
)
