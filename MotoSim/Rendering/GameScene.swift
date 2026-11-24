import Combine
import SwiftUI
import RealityKit
import UIKit

@MainActor
final class GameScene: ObservableObject {
    enum Startup: Equatable {
        case terrain(Double)
        case bike
        case camera
        case ready
        case failed
    }

    struct PerformanceReadout: Equatable {
        let fps: Int
        let online: Bool
        let latencyMS: Int?
    }

    @Published private(set) var startup = Startup.terrain(0)
    @Published private(set) var speed = 0
    @Published private(set) var rpm = 2200
    @Published private(set) var gear = 1
    @Published private(set) var airborne = false
    @Published private(set) var error: String?
    @Published private(set) var soundEnabled = false
    @Published private(set) var tireDebug: TireDebugReadout?
    @Published private(set) var performanceDebug: PerformanceReadout?
    var active = true {
        didSet { if oldValue != active { resetPerformanceWindow() } }
    }
    var showingMenu = false {
        didSet { if oldValue != showingMenu { resetPerformanceWindow() } }
    }
    weak var freeRide: FreeRideSession?
    private(set) var track = Track()

    private var audio: EngineAudio?

    let controls = RideControls()
    private var simulation = Motorcycle()
    private let sceneRoot = Entity()
    private let camera = PerspectiveCamera()
    private var currentWorld: Entity?
    private var terrainDetail: TerrainRenderer.TileDetail?
    private var grassRenderer: GrassRenderer?
    private var subscription: EventSubscription?
    private var bike: BikeRenderer?
    private var remoteBikes: [String: BikeRenderer] = [:]
    private var cameraPosition: SIMD3<Float>?
    private var tireVectors: TireVectorRenderer?
    private var tireReadoutElapsed: Float = 0
    private var measuresPerformance = false
    private var performanceWindowStart: TimeInterval?
    private var performanceFrames = 0

    var touchdownCSV: String { simulation.suspensionTrace.csv }

    func applyTuning(_ tuning: RideTuning) {
        simulation.tuning = tuning
    }

    func applyPhysicsMode(_ mode: RidePhysicsMode) {
        simulation.setPhysicsMode(mode)
    }

    func setTireDebug(_ enabled: Bool) {
        simulation.collectsTireTrace = enabled
        if enabled, tireVectors == nil {
            let vectors = TireVectorRenderer()
            sceneRoot.addChild(vectors.root)
            tireVectors = vectors
        }
        tireVectors?.root.isEnabled = enabled
        if !enabled { tireDebug = nil }
    }

    func setPerformanceDebug(_ enabled: Bool) {
        measuresPerformance = enabled
        resetPerformanceWindow()
        performanceDebug = nil
    }

    func selectTrack(_ track: Track) {
        controls.releaseTouch()
        clearRemoteBikes()
        terrainDetail?.cancel()
        terrainDetail = nil
        grassRenderer?.cancel()
        grassRenderer = nil
        self.track = track
        let debugEnabled = simulation.collectsTireTrace
        simulation = Motorcycle(configuration: simulation.configuration, track: track, tuning: simulation.tuning,
                                physicsMode: simulation.physicsMode)
        simulation.collectsTireTrace = debugEnabled
        tireDebug = nil
        resetPerformanceWindow()
        performanceDebug = nil
        tireVectors?.update(front: simulation.frontTrace, rear: simulation.rearTrace)
        bike = nil
        cameraPosition = nil
        startup = .terrain(0)
    }

    func install(in content: inout RealityViewCameraContent) {
        subscription?.cancel()
        content.camera = .virtual
        if camera.parent !== sceneRoot { sceneRoot.addChild(camera) }
        content.add(sceneRoot)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            if self.startup == .camera {
                self.startup = .ready
                self.freeRide?.terrainReady()
            }
            self.update(elapsed: Float(event.deltaTime))
        }
    }

    func loadTrack() async {
        startup = .terrain(0)
        error = nil
        let loadingTrack = track
        let world = Entity()
        var sky = UnlitMaterial(color: .init(red: 0.61, green: 0.76, blue: 0.84, alpha: 1))
        sky.faceCulling = .front
        let dimensions = loadingTrack.heightField.map { max($0.width, $0.length) } ?? 100
        let skyDome = ModelEntity(mesh: .generateSphere(radius: max(160, dimensions * 1.2)), materials: [sky])
        skyDome.components.set(DynamicLightShadowComponent(castsShadow: false))
        world.addChild(skyDome)
        let terrain: TerrainRenderer.Surface
        do {
            terrain = try await TerrainRenderer.make(loadingTrack) { [weak self] fraction in
                if !Task.isCancelled { self?.startup = .terrain(fraction) }
            }
            world.addChild(terrain.entity)
        } catch is CancellationError {
            return
        } catch {
            startup = .failed
            freeRide?.terrainFailed()
            return
        }
        var grassRenderer: GrassRenderer?
        if let field = loadingTrack.heightField, let grass = loadingTrack.grass {
            grassRenderer = try? await GrassRenderer.make(field: field, grass: grass)
            if let grassRenderer { world.addChild(grassRenderer.root) }
        }
        guard !Task.isCancelled else { return }
        startup = .bike
        if loadingTrack.heightField == nil {
            TerrainRenderer.addMarkers(to: world, track: loadingTrack)
        }

        let sun = DirectionalLight()
        sun.light.color = .init(red: 1, green: 0.91, blue: 0.77, alpha: 1)
        sun.light.intensity = 2500
        sun.shadow = DirectionalLightComponent.Shadow()
        sun.look(at: .zero, from: [-9, 14, 6], relativeTo: nil)
        world.addChild(sun)

        let bike = BikeRenderer(configuration: simulation.configuration)
        if let url = Bundle.main.url(forResource: "DirtBikeChassis", withExtension: "usdz") {
            do {
                bike.replaceBody(with: try await Entity(contentsOf: url))
            } catch {
                self.error = "The custom chassis couldn’t load."
            }
        }
        guard !Task.isCancelled else { return }
        self.bike = bike
        terrainDetail = terrain.detail
        self.grassRenderer = grassRenderer
        world.addChild(bike.root)
        // Keep the virtual camera attached to the same RealityKit scene across imports.
        currentWorld?.removeFromParent()
        sceneRoot.addChild(world)
        currentWorld = world
        update(elapsed: 0)
        startup = .camera
    }

    func toggleSound() {
        if soundEnabled {
            stopSound()
        } else if let audio = EngineAudio(), audio.start() {
            self.audio = audio
            soundEnabled = true
        }
    }

    func pauseSound() {
        audio?.pause()
    }

    func resumeSound() {
        if soundEnabled, audio?.start() == false { stopSound() }
    }

    private func stopSound() {
        guard soundEnabled else { return }
        audio?.stop()
        audio = nil
        soundEnabled = false
    }

    func reset() {
        controls.releaseTouch()
        simulation.reset()
        freeRide?.respawned()
        cameraPosition = nil
        update(elapsed: 0)
    }

    private func update(elapsed: Float) {
        guard let bike else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if elapsed > 0 { updateRemoteBikes(at: time) }
        let canRide = active && !showingMenu && freeRide?.blocksRiding != true
        if measuresPerformance, elapsed > 0, canRide {
            updatePerformanceDebug(at: time)
        }
        if elapsed > 0 && !canRide {
            freeRide?.sendPose(simulation.pose, at: time)
            return
        }
        let input = controls.input
        if simulation.advance(elapsed, input: input) {
            cameraPosition = nil
            freeRide?.respawned()
        }
        let pose = simulation.pose
        terrainDetail?.update(near: pose.position)
        grassRenderer?.update(near: pose.position)
        freeRide?.sendPose(pose, at: time)
        bike.update(pose)
        if simulation.collectsTireTrace {
            updateTireDebug(brake: input.brake, elapsed: elapsed)
        }
        audio?.update(rpm: pose.rpm, throttle: input.throttle, ignitionCut: pose.ignitionCut)
        let forward = SIMD3<Float>(sin(pose.heading), 0, cos(pose.heading))
        let desired = pose.position - 4.8 * forward + [0, 2.1, 0]
        let previous = cameraPosition ?? desired
        var position = previous + (desired - previous) * (1 - exp(-8 * min(elapsed, 0.1)))
        var focus = pose.position + 2.1 * forward + [0, 0.46, 0]
        focus.y = max(focus.y, simulation.track.height(focus.x, focus.z) + 0.40)
        position.y = max(position.y, simulation.track.minimumCameraHeight(from: position, lookingAt: focus))
        cameraPosition = position
        camera.look(at: focus, from: position, relativeTo: nil)

        let currentSpeed = Int(simd_length(SIMD2(pose.velocity.x, pose.velocity.z)) * 3.6)
        let currentRPM = Int(pose.rpm / 100) * 100
        if speed != currentSpeed { speed = currentSpeed }
        if rpm != currentRPM { rpm = currentRPM }
        if gear != pose.gear { gear = pose.gear }
        if airborne != (pose.contacts == 0) { airborne = pose.contacts == 0 }
    }

    func clearRemoteBikes() {
        for bike in remoteBikes.values { bike.root.removeFromParent() }
        remoteBikes.removeAll()
    }

    private func updatePerformanceDebug(at time: TimeInterval) {
        guard let start = performanceWindowStart else {
            performanceWindowStart = time
            return
        }
        performanceFrames += 1
        let duration = time - start
        guard duration >= 0.5 else { return }
        let readout = PerformanceReadout(fps: Int((Double(performanceFrames) / duration).rounded()),
                                         online: freeRide?.connected == true,
                                         latencyMS: freeRide?.sampleLatency(at: time))
        if performanceDebug != readout { performanceDebug = readout }
        performanceWindowStart = time
        performanceFrames = 0
    }

    private func resetPerformanceWindow() {
        performanceWindowStart = nil
        performanceFrames = 0
    }

    private func updateRemoteBikes(at time: TimeInterval) {
        guard let world = currentWorld, let freeRide else { return }
        let poses = freeRide.remotePoses(at: time)
        for id in remoteBikes.keys.filter({ poses[$0] == nil }) {
            remoteBikes.removeValue(forKey: id)?.root.removeFromParent()
        }
        for (id, pose) in poses {
            if let remote = remoteBikes[id] {
                remote.update(pose)
            } else {
                let remote = BikeRenderer(configuration: simulation.configuration)
                remote.update(pose)
                world.addChild(remote.root)
                remoteBikes[id] = remote
            }
        }
    }

    private func updateTireDebug(brake: Float, elapsed: Float) {
        let front = simulation.frontTrace
        let rear = simulation.rearTrace
        tireVectors?.update(front: front, rear: rear)
        tireReadoutElapsed += elapsed
        guard tireReadoutElapsed >= 0.05 || tireDebug == nil || elapsed == 0 else { return }
        tireReadoutElapsed = 0
        let readout = TireDebugReadout(bike: simulation, brake: brake)
        if tireDebug != readout { tireDebug = readout }
    }

}
