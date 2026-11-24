import RealityKit
import SwiftUI
import UniformTypeIdentifiers

struct RideView: View {
    private struct StartSelection: Identifiable {
        let id = UUID()
        let track: Track
    }

    @Environment(\.scenePhase) private var phase
    @StateObject private var game = GameScene()
    @StateObject private var freeRide = FreeRideSession()
    @State private var loadAttempt = 0
    @State private var pickingTrack = false
    @State private var importing = false
    @State private var startSelection: StartSelection?
    @State private var importError: String?
    @State private var tiltEnabled = false
    @State private var showingSetup = false
    @AppStorage("ride.tireDebug") private var showTireDebug = false
    @AppStorage("ride.maximumLeanDegrees") private var maximumLeanDegrees = 48.0
    @AppStorage("ride.tireGrip") private var tireGrip = 1.0
    @AppStorage("ride.forkRebound") private var forkRebound = 1.0
    @AppStorage("ride.shockRebound") private var shockRebound = 1.0
    @AppStorage("ride.forkCompression") private var forkCompression = 1.0
    @AppStorage("ride.shockLowSpeedCompression") private var shockLowSpeedCompression = 1.0
    @AppStorage("ride.shockHighSpeedCompression") private var shockHighSpeedCompression = 1.0
    @AppStorage("ride.forkSpringRate") private var forkSpringRate = RideTuning.defaultForkSpringRate
    @AppStorage("ride.shockPreload") private var shockPreload = 8.0
    @GestureState private var steering = false
    @GestureState private var accelerating = false
    @GestureState private var braking = false

    var body: some View {
        RealityView { content in
            game.install(in: &content)
        }
        .task {
            game.freeRide = freeRide
            freeRide.currentTrack = { [weak game] in game?.track ?? Track() }
        }
        .task(id: loadAttempt) { await game.loadTrack() }
        .ignoresSafeArea()
        .overlay {
            if importing {
                ProgressView("Reading track files…")
                    .padding(20)
                    .background(.black.opacity(0.85), in: .rect(cornerRadius: 12))
            } else if game.startup == .ready {
                rideHUD
            } else {
                StartupView(startup: game.startup, retry: { loadAttempt += 1 },
                            rideBuiltIn: game.track.heightField == nil || freeRide.phase != .idle ? nil : { switchTrack(Track()) })
            }
        }
        .fileImporter(isPresented: $pickingTrack, allowedContentTypes: [.folder, .item]) { result in
            importTrack(result)
        }
        .sheet(item: $startSelection) { selection in
            TrackStartView(track: selection.track) { track in
                if freeRide.phase == .idle { switchTrack(track) }
            }
        }
        .sheet(isPresented: $freeRide.showLobby) {
            FreeRideView(session: freeRide, track: game.track)
        }
        .onChange(of: freeRide.trackRequest) { _, _ in
            if let track = freeRide.pendingTrack { switchTrack(track) }
        }
        .onChange(of: freeRide.phase) { _, phase in
            switch phase {
            case .riding:
                freeRide.showLobby = false
            case .idle:
                game.clearRemoteBikes()
            default:
                break
            }
        }
        .sheet(isPresented: $showingSetup) {
            RideSetupView(tuning: Binding(get: { tuning }, set: { updateTuning($0) }), showTireDebug: $showTireDebug, touchdownCSV: game.touchdownCSV)
        }
        .onChange(of: showTireDebug, initial: true) { _, enabled in game.setTireDebug(enabled) }
        .onChange(of: tuning, initial: true) { _, value in game.applyTuning(value) }
        .alert("Track Import", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: pickingTrack || importing || startSelection != nil || showingSetup || freeRide.showLobby) { _, busy in
            game.showingMenu = busy
            if busy { game.controls.releaseTouch() }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: phase) { _, phase in
            game.active = phase == .active
            if phase == .active {
                game.resumeSound()
            } else {
                if phase == .background { game.pauseSound() }
                game.controls.releaseTouch()
                game.controls.setTilt(false)
                tiltEnabled = false
            }
        }
    }

    private var rideHUD: some View {
        VStack {
            HStack(alignment: .top) {
                telemetry
                Spacer()
                if let error = game.error {
                    Text(error).padding(10).background(.black.opacity(0.78))
                }
                Menu {
                    Button("Free Ride…") { freeRide.showLobby = true }
                    Button("Import MX Bikes Track…") { pickingTrack = true }
                        .disabled(freeRide.phase != .idle)
                    Button("Change Start Point") {
                        startSelection = StartSelection(track: game.track)
                    }
                    .disabled(freeRide.phase != .idle)
                    if game.track.heightField != nil {
                        Button("Ride MotoSim Circuit") { switchTrack(Track()) }
                            .disabled(freeRide.phase != .idle)
                    }
                } label: {
                    Label("Track", systemImage: "map")
                }
                Button {
                    tiltEnabled = game.controls.setTilt(!tiltEnabled)
                } label: {
                    Label(tiltEnabled ? "Tilt on" : "Tilt", systemImage: "iphone.radiowaves.left.and.right")
                }
                .accessibilityAddTraits(tiltEnabled ? .isSelected : [])
                Button {
                    game.toggleSound()
                } label: {
                    Image(systemName: game.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .accessibilityLabel(game.soundEnabled ? "Mute engine" : "Unmute engine")
                Button {
                    game.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button {
                    showingSetup = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ride Setup")
            }
            .buttonStyle(.borderedProminent)
            .tint(.black.opacity(0.72))

            if let debug = game.tireDebug {
                HStack {
                    TireDebugView(readout: debug)
                    Spacer()
                }
            }

            Spacer()
            HStack(alignment: .bottom) {
                control("LEAN / WEIGHT", symbol: "move.3d", pressed: steering)
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($steering) { _, active, _ in active = true }
                        .onChanged { change in
                            game.controls.touch.steer = axis(change.translation.width)
                            game.controls.touch.weight = axis(-change.translation.height)
                        })
                    .onChange(of: steering) { _, held in
                        if !held {
                            game.controls.touch.steer = 0
                            game.controls.touch.weight = 0
                        }
                    }
                    .accessibilityHint("Drag horizontally to lean the bike and vertically to shift weight.")
                Spacer()
                control("BRAKE", symbol: "brakesignal", pressed: braking)
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($braking) { _, active, _ in active = true }
                        .onChanged { _ in game.controls.touch.brake = 1 })
                    .onChange(of: braking) { _, held in
                        if !held { game.controls.touch.brake = 0 }
                    }
                control("THROTTLE", symbol: "gauge.with.needle", pressed: accelerating)
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($accelerating) { _, active, _ in active = true }
                        .onChanged { _ in game.controls.touch.throttle = 1 })
                    .onChange(of: accelerating) { _, held in
                        if !held { game.controls.touch.throttle = 0 }
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tuning: RideTuning {
        RideTuning(maximumLeanDegrees: maximumLeanDegrees, tireGrip: tireGrip,
                   forkRebound: forkRebound, shockRebound: shockRebound,
                   forkCompression: forkCompression, shockLowSpeedCompression: shockLowSpeedCompression,
                   shockHighSpeedCompression: shockHighSpeedCompression,
                   forkSpringRate: forkSpringRate, shockPreload: shockPreload)
    }

    private func updateTuning(_ value: RideTuning) {
        maximumLeanDegrees = value.maximumLeanDegrees
        tireGrip = value.tireGrip
        forkRebound = value.forkRebound
        shockRebound = value.shockRebound
        forkCompression = value.forkCompression
        shockLowSpeedCompression = value.shockLowSpeedCompression
        shockHighSpeedCompression = value.shockHighSpeedCompression
        forkSpringRate = value.forkSpringRate
        shockPreload = value.shockPreload
    }

    private func switchTrack(_ track: Track) {
        game.selectTrack(track)
        loadAttempt += 1
    }

    private func importTrack(_ result: Result<URL, Error>) {
        guard freeRide.phase == .idle else { return }
        do {
            let trackURL = try result.get()
            importing = true
            Task {
                defer { importing = false }
                do {
                    let track = try await Task.detached(priority: .userInitiated) {
                        let hasAccess = trackURL.startAccessingSecurityScopedResource()
                        defer { if hasAccess { trackURL.stopAccessingSecurityScopedResource() } }
                        return try MXTrackImporter.load(file: trackURL)
                    }.value
                    if freeRide.phase == .idle { startSelection = StartSelection(track: track) }
                } catch {
                    if freeRide.phase == .idle { importError = error.localizedDescription }
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private var telemetry: some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            Text(game.speed, format: .number)
                .font(.system(size: 35, weight: .black, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                Text("KM/H  ·  G\(game.gear)")
                    .foregroundStyle(.orange)
                Text(game.airborne ? "AIRBORNE" : "\(game.rpm) RPM")
                    .monospacedDigit()
            }
            .font(.caption2.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.black.opacity(0.76), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func control(_ name: String, symbol: String, pressed: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
            Text(name).font(.caption2.bold())
        }
        .frame(minWidth: 83, minHeight: 68)
        .padding(.horizontal, 5)
        .background(pressed ? Color.orange.opacity(0.85) : Color.black.opacity(0.68),
                    in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func axis(_ translation: CGFloat) -> Float {
        min(1, max(-1, Float(translation / 58)))
    }
}
