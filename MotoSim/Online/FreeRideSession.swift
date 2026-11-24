import Combine
import Foundation

private struct RoomTrack: Codable {
    let version: Int
    let name: String
    let grant: String?
    let sha256: String?
    let start: SIMD2<Float>
    let heading: Float
}

private struct RoomCommand: Encodable {
    var version = 1
    let type: String
    var code: String?
    var name: String?
    var token: String?
    var status: String?
    var track: RoomTrack?
    var pose: RideSnapshot?
}

private struct RoomEvent: Decodable {
    let type: String
    let code: String?
    let token: String?
    let id: String?
    let slot: Int?
    let track: RoomTrack?
    let riders: [FreeRideSession.Rider]?
    let active: Bool?
    let pose: RideSnapshot?
    let notice: String?
}

@MainActor
final class FreeRideSession: ObservableObject {
    enum LoadStatus: String, Codable {
        case downloading, loading, ready, failed, reconnecting

        var label: String {
            switch self {
            case .downloading: "Checking or downloading track"
            case .loading: "Loading terrain"
            case .ready: "Ready"
            case .failed: "Track could not load"
            case .reconnecting: "Reconnecting"
            }
        }
    }

    struct Rider: Identifiable, Decodable {
        let id: String
        let name: String
        let status: LoadStatus
    }

    enum Phase: Equatable {
        case idle, preparing, connecting, lobby, riding
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var isHost = false
    @Published private(set) var riders: [Rider] = []
    @Published private(set) var notice: String?
    @Published private(set) var roomCode = ""
    @Published private(set) var connected = false
    @Published var showLobby = false
    @Published private(set) var trackRequest = 0

    private(set) var pendingTrack: Track?
    var currentTrack: (() -> Track)?
    private var hostedTrack: Track?
    private var roomTrack: RoomTrack?
    private var server: URL?
    private var localID: String?
    private var slot = 0
    private var resumeToken: String?
    private var localStatus: LoadStatus = .loading
    private var sessionID = UUID()
    private var socket: URLSessionWebSocketTask?
    private var lastServerEvent: TimeInterval = 0
    private var connectionTask: Task<Void, Never>?
    private var transfer: Task<Void, Never>?
    private var motions: [String: RemoteBikeMotion] = [:]
    private var sequence: UInt32 = 0
    private var generation: UInt32 = 0
    private var nextSendAt: TimeInterval = 0
    private var movementTask: Task<Void, Never>?

    var canStart: Bool {
        connected && isHost && phase == .lobby && riders.count >= 2 && riders.allSatisfy { $0.status == .ready }
    }

    var blocksRiding: Bool { phase == .lobby }
    var canRetryTrack: Bool { phase == .lobby && roomTrack != nil && localStatus == .failed }

    static func validCode(_ code: String) -> Bool {
        code.utf8.count == 8 && code.uppercased().utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    func host(track: Track, serverAddress: String, uploadKey: String, name: String) {
        guard phase == .idle, let server = TrackTransfer.serverURL(serverAddress) else { return }
        notice = nil
        isHost = true
        self.server = server
        hostedTrack = track
        phase = track.heightField == nil ? .connecting : .preparing
        let id = sessionID
        transfer = Task {
            do {
                var download: TrackDownload?
                if track.heightField != nil {
                    download = try await TrackTransfer.upload(track, server: server, key: uploadKey)
                }
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let config = RoomTrack(version: SharedTrack.version, name: String(track.name.prefix(100)),
                                       grant: download?.grant, sha256: download?.sha256,
                                       start: [track.startPosition.x, track.startPosition.z], heading: track.startHeading)
                connect(RoomCommand(type: "host", name: name, track: config), server: server)
            } catch {
                if sessionID == id && !Task.isCancelled { finish(reason: error.localizedDescription) }
            }
        }
    }

    func join(code: String, serverAddress: String, name: String) {
        guard phase == .idle, Self.validCode(code), let server = TrackTransfer.serverURL(serverAddress) else { return }
        notice = nil
        self.server = server
        connect(RoomCommand(type: "join", code: code.uppercased(), name: name), server: server)
    }

    func startRide() {
        if canStart { send(RoomCommand(type: "start")) }
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
        if canRetryTrack { prepareTrack() }
    }

    func leave() {
        let previous = socket
        let runner = connectionTask
        if connected, let previous {
            // Give the leave message a chance to reach the server before closing the socket.
            Task {
                try? await Self.send(RoomCommand(type: "leave"), over: previous)
                previous.cancel(with: .normalClosure, reason: nil)
                runner?.cancel()
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                previous.cancel(with: .normalClosure, reason: nil)
                runner?.cancel()
            }
            socket = nil
            connectionTask = nil
        }
        finish()
    }

    func respawned() {
        if phase == .riding { generation &+= 1 }
    }

    func sendPose(_ pose: BikeState, at time: TimeInterval) {
        guard phase == .riding, connected, time >= nextSendAt, movementTask == nil, let socket else { return }
        sequence &+= 1
        nextSendAt = max(nextSendAt + 0.05, time + 0.025)
        let packet = RoomCommand(type: "pose", pose: RideSnapshot(pose, sequence: sequence, generation: generation))
        let id = sessionID
        movementTask = Task {
            defer { if id == sessionID && socket === self.socket { movementTask = nil } }
            do { try await Self.send(packet, over: socket) }
            catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    func remotePoses(at time: TimeInterval) -> [String: BikeState] {
        phase == .riding ? motions.compactMapValues { $0.pose(at: time) } : [:]
    }

    private func connect(_ initial: RoomCommand, server: URL) {
        guard var address = URLComponents(url: server.appending(path: "v1/rooms/connect"), resolvingAgainstBaseURL: false) else { return }
        address.scheme = "wss"
        guard let url = address.url else { return }
        phase = .connecting
        let id = sessionID
        connectionTask = Task {
            var request = initial
            var retryUntil: TimeInterval?
            while !Task.isCancelled && sessionID == id {
                let connection = URLSession.shared.webSocketTask(with: url)
                connection.maximumMessageSize = 8192
                socket = connection
                connection.resume()
                lastServerEvent = ProcessInfo.processInfo.systemUptime
                let watchdog = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard socket === connection else { return }
                        if ProcessInfo.processInfo.systemUptime - lastServerEvent >= 20 {
                            connection.cancel(with: .goingAway, reason: nil)
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                do {
                    try await Self.send(request, over: connection)
                    while !Task.isCancelled && sessionID == id {
                        let message = try await connection.receive()
                        lastServerEvent = ProcessInfo.processInfo.systemUptime
                        guard sessionID == id else { break }
                        guard case .string(let text) = message else { continue }
                        let event = try JSONDecoder().decode(RoomEvent.self, from: Data(text.utf8))
                        if event.type == "welcome" { retryUntil = nil }
                        receive(event)
                    }
                } catch {
                    guard !Task.isCancelled, sessionID == id else { return }
                    connection.cancel(with: .goingAway, reason: nil)
                    socket = nil
                    movementTask?.cancel()
                    movementTask = nil
                    connected = false
                    guard let resumeToken else {
                        finish(reason: "Could not connect to the Free Ride server. \(error.localizedDescription)")
                        return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    let cutoff = retryUntil ?? now + 25
                    retryUntil = cutoff
                    guard now < cutoff else {
                        finish(reason: "The connection expired. Join a new Free Ride to continue online.")
                        return
                    }
                    notice = "Connection lost. Reconnecting…"
                    request = RoomCommand(type: "resume", code: roomCode, token: resumeToken)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func receive(_ event: RoomEvent) {
        switch event.type {
        case "welcome":
            guard let id = event.id, let code = event.code, let token = event.token, let info = event.track,
                  info.version == SharedTrack.version else {
                finish(reason: "This Free Ride uses an incompatible track format.")
                return
            }
            let resuming = resumeToken != nil
            localID = id
            roomCode = code
            resumeToken = token
            roomTrack = info
            slot = event.slot ?? 0
            connected = true
            notice = nil
            setRoster(event.riders ?? [])
            phase = event.active == true ? .riding : .lobby
            if !resuming { prepareTrack() }
            else if phase == .lobby { updateLocal(localStatus) }
        case "roster":
            setRoster(event.riders ?? [])
        case "started":
            phase = .riding
        case "pose":
            if let id = event.id, let pose = event.pose, id != localID, phase == .riding,
               riders.contains(where: { $0.id == id }) {
                motions[id, default: RemoteBikeMotion()].receive(pose, at: ProcessInfo.processInfo.systemUptime)
            }
        case "notice":
            notice = event.notice
        case "error", "ended":
            finish(reason: event.notice ?? "The Free Ride ended.")
        default:
            break
        }
    }

    private func prepareTrack() {
        guard let info = roomTrack, let server else { return }
        transfer?.cancel()
        pendingTrack = nil
        notice = nil
        let hosted = hostedTrack
        let current = currentTrack?() ?? Track()
        let id = sessionID
        let startSlot = slot
        updateLocal(info.grant != nil && hosted == nil ? .downloading : .loading)
        transfer = Task {
            do {
                let terrain: Track
                if let hosted { terrain = hosted }
                else if let grant = info.grant, let hash = info.sha256 {
                    let download = TrackDownload(server: server, grant: grant, sha256: hash)
                    terrain = try await TrackTransfer.load(download, name: info.name, current: current)
                } else {
                    terrain = Track()
                }
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let start = RideStart(position: info.start, heading: info.heading)
                pendingTrack = try start.placed(terrain, slot: startSlot)
                updateLocal(.loading)
                trackRequest += 1
            } catch {
                guard sessionID == id, !Task.isCancelled else { return }
                updateLocal(.failed)
                notice = error.localizedDescription
            }
        }
    }

    private func setRoster(_ roster: [Rider]) {
        riders = roster
        let present = Set(roster.map(\.id))
        motions = motions.filter { present.contains($0.key) }
    }

    private func updateLocal(_ status: LoadStatus) {
        localStatus = status
        send(RoomCommand(type: "status", status: status.rawValue))
    }

    private func send(_ command: RoomCommand) {
        guard connected, let socket else { return }
        Task {
            do { try await Self.send(command, over: socket) }
            catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    private static func send(_ packet: RoomCommand, over socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(packet)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func finish(reason: String? = nil) {
        sessionID = UUID()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connectionTask?.cancel()
        connectionTask = nil
        transfer?.cancel()
        transfer = nil
        movementTask?.cancel()
        movementTask = nil
        motions.removeAll()
        riders.removeAll()
        pendingTrack = nil
        hostedTrack = nil
        roomTrack = nil
        server = nil
        localID = nil
        resumeToken = nil
        localStatus = .loading
        roomCode = ""
        connected = false
        isHost = false
        phase = .idle
        sequence = 0
        generation = 0
        nextSendAt = 0
        notice = reason
        if reason != nil { showLobby = true }
    }
}
