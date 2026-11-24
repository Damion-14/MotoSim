import SwiftUI

struct FreeRideView: View {
    @ObservedObject var session: FreeRideSession
    let track: Track
    @AppStorage("online.trackServer") private var serverAddress = TrackTransfer.defaultServerAddress
    @AppStorage("online.riderName") private var riderName = ""
    @State private var joinCode = ""

    private var server: URL? { TrackTransfer.serverURL(serverAddress) }
    private var canHostCustomTrack: Bool { server.map { TrackTransfer.canUpload(to: $0) } ?? false }
    private var normalizedCode: String { joinCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let notice = session.notice {
                    Section { Text(notice).foregroundStyle(.orange) }
                }
                switch session.phase {
                case .idle:
                    Section {
                        TextField("Server HTTPS address", text: $serverAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Rider name", text: $riderName, prompt: Text("Rider"))
                            .textContentType(.nickname)
                    }
                    Section("Host") {
                        LabeledContent("Track", value: track.name)
                        if track.heightField != nil && !canHostCustomTrack {
                            Text("Custom-track hosting requires a configured test build and its default server.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Host Free Ride") {
                            session.host(track: track, serverAddress: serverAddress, name: riderName)
                        }
                        .disabled(server == nil || (track.heightField != nil && !canHostCustomTrack))
                    }
                    Section("Join") {
                        TextField("8-character room code", text: $joinCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Join Free Ride") {
                            session.join(code: normalizedCode, serverAddress: serverAddress, name: riderName)
                        }
                        .disabled(server == nil || !FreeRideSession.validCode(normalizedCode))
                    }
                case .preparing, .connecting:
                    ProgressView(session.phase == .preparing ? "Uploading track…" : "Connecting to Free Ride…")
                    Button("Cancel", role: .cancel) { session.leave() }
                case .lobby, .riding:
                    if session.isHost && session.phase == .lobby {
                        Section("Invite Riders") {
                            LabeledContent("Room code") {
                                Text(session.roomCode)
                                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                            }
                            ShareLink(item: "Join my MotoSim Free Ride with code \(session.roomCode) on \(serverAddress).")
                        }
                    }
                    Section("Riders") {
                        ForEach(session.riders) { rider in
                            LabeledContent(rider.name, value: session.phase == .riding && rider.status == .ready
                                           ? "Riding" : rider.status.label)
                        }
                    }
                    if session.phase == .lobby {
                        Section {
                            if session.canRetryTrack {
                                Button("Retry track load", action: session.retryTrack)
                            }
                            if session.isHost {
                                Button("Start Ride", action: session.startRide)
                                    .disabled(!session.canStart)
                            } else if !session.canRetryTrack {
                                Text("Waiting for the host to start.")
                            }
                        }
                    }
                    Button(session.isHost ? "End Free Ride" : "Leave Free Ride", role: .destructive) {
                        session.leave()
                        session.showLobby = false
                    }
                }
            }
            .navigationTitle("Free Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.phase == .idle || session.phase == .riding {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { session.showLobby = false }
                    }
                }
            }
        }
        .onAppear {
            if serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                serverAddress = TrackTransfer.defaultServerAddress
            }
        }
        .tint(.orange)
        .interactiveDismissDisabled(session.phase != .idle && session.phase != .riding)
    }
}
