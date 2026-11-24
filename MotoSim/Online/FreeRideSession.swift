import Combine
import Foundation
@preconcurrency import GameKit
import UIKit

private enum RideMessage: Codable {
    case hello
    case setup(RideManifest)
    case status(FreeRideSession.LoadStatus)
    case start
    case end
    case reset(RideSnapshot)
    case movement(RideSnapshot)
}

private struct RidePacket: Codable {
    let version: Int
    let message: RideMessage
}

@MainActor
final class FreeRideSession: NSObject, ObservableObject {
    enum LoadStatus: String, Codable {
        case connecting = "Connecting"
        case downloading = "Checking or downloading track"
        case loading = "Loading terrain"
        case ready = "Ready"
        case failed = "Track could not load"
        case disconnected = "Disconnected"
    }

    struct Rider: Identifiable {
        let id: String
        let name: String
        var status: LoadStatus
    }

    enum Phase: Equatable {
        case idle, preparing, inviting, lobby, riding
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var signedIn = false
    @Published private(set) var isHost = false
    @Published private(set) var riders: [Rider] = []
    @Published private(set) var notice: String?
    @Published var showLobby = false
    @Published private(set) var trackRequest = 0

    private(set) var pendingTrack: Track?
    var currentTrack: (() -> Track)?
    private var configured = false
    private var authenticationView: UIViewController?
    private weak var matchmaker: GKMatchmakerViewController?
    private var match: GKMatch?
    private var manifest: RideManifest?
    private var hostID: String?
    private var hostedTrack: Track?
    private var hostedDownload: TrackDownload?
    private var transfer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var motions: [String: RemoteBikeMotion] = [:]
    private var sequence: UInt32 = 0
    private var generation: UInt32 = 0
    private var nextSendAt: TimeInterval = 0
    private var resetPending = false
    private var localID: String { GKLocalPlayer.local.gamePlayerID }
    private static let protocolVersion = 1
    private static let maxPacketBytes = 8192

    var canStart: Bool {
        isHost && phase == .lobby && riders.count >= 2 && riders.allSatisfy { $0.status == .ready }
    }

    var blocksRiding: Bool { phase == .lobby }
    var canRetryTrack: Bool {
        phase == .lobby && (pendingTrack != nil || manifest != nil) &&
            riders.first { $0.id == localID }?.status == .failed
    }

    func configure() {
        guard !configured else { return }
        configured = true
        GKLocalPlayer.local.register(self)
        GKLocalPlayer.local.authenticateHandler = { [weak self] controller, _ in
            Task { @MainActor in
                guard let self else { return }
                self.signedIn = GKLocalPlayer.local.isAuthenticated
                self.authenticationView = controller
                if !self.signedIn && self.match != nil { self.leave(reason: "Game Center signed out.") }
            }
        }
    }

    func signIn() {
        if let authenticationView {
            presenter()?.present(authenticationView, animated: true)
        } else if !signedIn {
            notice = "Sign in to Game Center in iPhone Settings, then reopen MotoSim."
        }
    }

    func host(track: Track, serverAddress: String, uploadKey: String) {
        guard phase == .idle, signedIn else { return }
        guard !GKLocalPlayer.local.isMultiplayerGamingRestricted else {
            notice = "This Game Center account is restricted from multiplayer."
            return
        }
        notice = nil
        isHost = true
        phase = .preparing
        hostedTrack = track
        transfer = Task {
            do {
                if track.heightField != nil {
                    guard let url = TrackTransfer.serverURL(serverAddress), uploadKey.utf8.count >= 32 else {
                        throw TrackTransfer.Failure.configuration
                    }
                    let download = try await TrackTransfer.upload(track, server: url, key: uploadKey)
                    try Task.checkCancellation()
                    hostedDownload = download
                }
                try Task.checkCancellation()
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 4
                guard let controller = GKMatchmakerViewController(matchRequest: request) else {
                    leave(reason: "Game Center could not open the invitation screen.")
                    return
                }
                controller.matchmakingMode = .inviteOnly
                presentMatchmaker(controller)
            } catch {
                if !Task.isCancelled { leave(reason: error.localizedDescription) }
            }
        }
    }

    func startRide() {
        guard canStart, send(.start) else { return }
        phase = .riding
    }

    func terrainReady() {
        guard phase == .lobby, pendingTrack != nil else { return }
        pendingTrack = nil
        updateLocal(.ready)
    }

    func terrainFailed() {
        guard phase == .lobby, pendingTrack != nil else { return }
        notice = "The shared terrain could not be rendered."
        updateLocal(.failed)
    }

    func retryTrack() {
        guard canRetryTrack, let manifest else { return }
        pendingTrack = nil
        prepareTrack(manifest)
    }

    func leave(reason: String? = nil) {
        if isHost { _ = send(.end) }
        matchmaker?.dismiss(animated: true)
        matchmaker = nil
        match?.delegate = nil
        match?.disconnect()
        match = nil
        heartbeat?.cancel()
        heartbeat = nil
        transfer?.cancel()
        transfer = nil
        for task in removalTasks.values { task.cancel() }
        removalTasks.removeAll()
        motions.removeAll()
        riders.removeAll()
        pendingTrack = nil
        hostedTrack = nil
        hostedDownload = nil
        hostID = nil
        manifest = nil
        isHost = false
        phase = .idle
        sequence = 0
        generation = 0
        nextSendAt = 0
        resetPending = false
        notice = reason
        if reason != nil { showLobby = true }
    }

    func respawned() {
        guard phase == .riding else { return }
        generation &+= 1
        resetPending = true
    }

    func sendPose(_ pose: BikeState, at time: TimeInterval) {
        guard phase == .riding, resetPending || time >= nextSendAt else { return }
        sequence &+= 1
        let snapshot = RideSnapshot(pose, sequence: sequence, generation: generation)
        if resetPending {
            resetPending = !send(.reset(snapshot), mode: .reliable, reportError: false)
        } else {
            _ = send(.movement(snapshot), mode: .unreliable, reportError: false)
        }
        nextSendAt = max(nextSendAt + 0.05, time + 0.025)
    }

    func remotePoses(at time: TimeInterval) -> [String: BikeState] {
        guard phase == .riding else { return [:] }
        return motions.compactMapValues { $0.pose(at: time) }
    }

    private func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    private func presentMatchmaker(_ controller: GKMatchmakerViewController) {
        guard let presenter = presenter() else {
            leave(reason: "The invitation screen is unavailable. Open Free Ride and try again.")
            return
        }
        phase = .inviting
        matchmaker = controller
        controller.matchmakerDelegate = self
        presenter.present(controller, animated: true)
    }

    private func begin(_ match: GKMatch) {
        self.match = match
        match.delegate = self
        phase = .lobby
        refreshRiders()
        heartbeat = Task {
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled && phase == .lobby {
                if isHost && manifest == nil && match.expectedPlayerCount == 0 && match.players.count >= 1 {
                    createManifest(match)
                } else if !isHost && manifest == nil {
                    _ = send(.hello, reportError: false)
                }
                if let status = riders.first(where: { $0.id == localID })?.status, manifest != nil {
                    _ = send(.status(status), reportError: false)
                }
                if manifest == nil && ProcessInfo.processInfo.systemUptime - started > 45 {
                    leave(reason: "The Free Ride invitation did not finish connecting. Try again.")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func createManifest(_ match: GKMatch) {
        guard let hostedTrack else { return }
        let roster = [localID] + match.players.map(\.gamePlayerID).sorted()
        let config = RideManifest(trackVersion: SharedTrack.version, name: String(hostedTrack.name.prefix(100)),
                                  download: hostedDownload,
                                  start: [hostedTrack.startPosition.x, hostedTrack.startPosition.z],
                                  heading: hostedTrack.startHeading, roster: roster)
        manifest = config
        _ = send(.setup(config))
        prepareTrack(config)
    }

    private func prepareTrack(_ config: RideManifest) {
        transfer?.cancel()
        notice = nil
        updateLocal(config.download != nil && !isHost ? .downloading : .loading)
        // Capture the current terrain before the guest's shared start replaces it.
        let current = currentTrack?() ?? Track()
        let hosted = hostedTrack
        transfer = Task {
            do {
                let terrain: Track
                if let hosted {
                    terrain = hosted
                } else if let download = config.download {
                    terrain = try await TrackTransfer.load(download, name: config.name, current: current)
                } else {
                    terrain = Track()
                }
                try Task.checkCancellation()
                let track = try config.placed(terrain, rider: localID)
                updateLocal(.loading)
                pendingTrack = track
                trackRequest += 1
            } catch {
                guard !Task.isCancelled else { return }
                updateLocal(.failed)
                notice = error.localizedDescription
            }
        }
    }

    private func refreshRiders() {
        guard let match else { return }
        for player in [GKLocalPlayer.local as GKPlayer] + match.players where !riders.contains(where: { $0.id == player.gamePlayerID }) {
            riders.append(Rider(id: player.gamePlayerID, name: player.displayName, status: .connecting))
        }
    }

    private func updateLocal(_ status: LoadStatus) {
        updateStatus(status, for: localID)
        _ = send(.status(status), reportError: false)
    }

    private func updateStatus(_ status: LoadStatus, for id: String) {
        if let index = riders.firstIndex(where: { $0.id == id }), riders[index].status != status {
            riders[index].status = status
        }
    }

    @discardableResult
    private func send(_ message: RideMessage, to player: GKPlayer? = nil,
                      mode: GKMatch.SendDataMode = .reliable, reportError: Bool = true) -> Bool {
        guard let match else { return false }
        do {
            let data = try JSONEncoder().encode(RidePacket(version: Self.protocolVersion, message: message))
            guard data.count <= Self.maxPacketBytes else { return false }
            if let player {
                try match.send(data, to: [player], dataMode: mode)
            } else {
                try match.sendData(toAllPlayers: data, with: mode)
            }
            return true
        } catch {
            if reportError { notice = "Could not send a Free Ride update. Try again." }
            return false
        }
    }

    private func receive(_ message: RideMessage, from player: GKPlayer) {
        let id = player.gamePlayerID
        switch message {
        case .hello:
            if isHost, phase == .lobby, let manifest, manifest.roster.contains(id) {
                _ = send(.setup(manifest), to: player)
            }
        case .setup(let config):
            guard !isHost, phase == .lobby, id == hostID, manifest == nil else { return }
            guard config.trackVersion == SharedTrack.version else {
                leave(reason: "This Free Ride uses a different MotoSim track version.")
                return
            }
            let connected = Set((match?.players.map(\.gamePlayerID) ?? []) + [localID])
            guard (2...4).contains(config.roster.count), Set(config.roster) == connected,
                  config.roster.first == id, !config.name.isEmpty, config.name.count <= 100 else { return }
            manifest = config
            prepareTrack(config)
        case .status(let status):
            guard phase == .lobby, status != .disconnected else { return }
            updateStatus(status, for: id)
        case .start:
            if !isHost, id == hostID, phase == .lobby,
               riders.first(where: { $0.id == localID })?.status == .ready {
                phase = .riding
            }
        case .end:
            if !isHost, id == hostID { leave(reason: "The host ended the Free Ride. You can keep riding locally.") }
        case .movement(let snapshot), .reset(let snapshot):
            guard phase == .riding, riders.contains(where: { $0.id == id && $0.status != .disconnected }) else { return }
            motions[id, default: RemoteBikeMotion()].receive(snapshot, at: ProcessInfo.processInfo.systemUptime)
        }
    }
}

extension FreeRideSession: GKLocalPlayerListener, GKMatchmakerViewControllerDelegate, GKMatchDelegate {
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in await acceptInvite(invite) }
    }

    private func acceptInvite(_ invite: GKInvite) async {
        leave()
        hostID = invite.sender.gamePlayerID
        // An invite can launch the app before its SwiftUI window is ready.
        for _ in 0..<20 {
            if let presenter = presenter(), presenter.viewIfLoaded?.window != nil,
               !presenter.isBeingDismissed, !presenter.isBeingPresented,
               UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard phase == .idle, hostID == invite.sender.gamePlayerID else { return }
        guard let controller = GKMatchmakerViewController(invite: invite) else {
            leave(reason: "Game Center could not open this Free Ride invitation.")
            return
        }
        presentMatchmaker(controller)
    }

    nonisolated func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        Task { @MainActor in
            guard viewController === matchmaker else { return }
            leave()
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        Task { @MainActor in
            guard viewController === matchmaker else { return }
            leave(reason: error.localizedDescription)
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        Task { @MainActor in
            guard viewController === matchmaker else { match.disconnect(); return }
            viewController.dismiss(animated: true) { [weak self] in
                guard let self, self.matchmaker === viewController else { match.disconnect(); return }
                self.matchmaker = nil
                self.begin(match)
            }
        }
    }

    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        Task { @MainActor in
            guard match === self.match, data.count <= Self.maxPacketBytes,
                  let packet = try? JSONDecoder().decode(RidePacket.self, from: data) else { return }
            guard packet.version == Self.protocolVersion else {
                if player.gamePlayerID == hostID || isHost {
                    leave(reason: "A rider is using an incompatible MotoSim version.")
                }
                return
            }
            receive(packet.message, from: player)
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        Task { @MainActor in connectionChanged(match, player: player, state: state) }
    }

    private func connectionChanged(_ match: GKMatch, player: GKPlayer, state: GKPlayerConnectionState) {
        guard match === self.match else { return }
        let id = player.gamePlayerID
        switch state {
        case .connected:
            refreshRiders()
        case .disconnected:
            if id == hostID || phase == .lobby {
                let reason = id == hostID ? "The host left. You can keep riding locally."
                    : "A rider disconnected while the lobby was loading. Start a new Free Ride to retry."
                leave(reason: reason)
                return
            }
            updateStatus(.disconnected, for: id)
            notice = "\(player.displayName) disconnected."
            removalTasks[id]?.cancel()
            removalTasks[id] = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                motions[id] = nil
                removalTasks[id] = nil
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in
            guard match === self.match else { return }
            leave(reason: error?.localizedDescription ?? "The Free Ride connection ended.")
        }
    }

    nonisolated func match(_ match: GKMatch, shouldReinviteDisconnectedPlayer player: GKPlayer) -> Bool { false }
}
