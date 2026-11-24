// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotoSimPhysics",
    platforms: [.macOS(.v13), .iOS("18.0")],
    targets: [
        .target(
            name: "MotoSimPhysics",
            path: "MotoSim",
            exclude: [
                "App", "Audio", "UI",
                "Input/RideControls.swift",
                "Online/FreeRideSession.swift", "Online/TrackTransfer.swift",
                "Rendering/BikeRenderer.swift", "Rendering/GameScene.swift", "Rendering/GrassRenderer.swift",
                "Rendering/TerrainRenderer.swift", "Rendering/TireVectorRenderer.swift",
                "Rendering/TrackGroundArt+Image.swift"
            ],
            sources: ["Diagnostics", "Input/RideInput.swift", "Online/FreeRideWire.swift", "Physics", "Rendering/TerrainCamera.swift", "Terrain"]
        ),
        .testTarget(name: "MotoSimPhysicsTests", dependencies: ["MotoSimPhysics"], path: "Tests")
    ]
)
