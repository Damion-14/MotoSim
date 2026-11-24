import SwiftUI

struct FreeRideView: View {
    @ObservedObject var session: FreeRideSession
    let track: Track
    @AppStorage("online.trackServer") private var serverAddress = ""
    @State private var uploadKey = ""

    var body: some View {
        NavigationStack {
            Form {
                if let notice = session.notice {
                    Section { Text(notice).foregroundStyle(.orange) }
                }
                switch session.phase {
                case .idle:
                    if session.signedIn {
                        Section {
                            LabeledContent("Track", value: track.name)
                            if track.heightField != nil {
                                TextField("Track server HTTPS address", text: $serverAddress)
                                    .textContentType(.URL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                SecureField("Host upload key", text: $uploadKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button("Host Free Ride") {
                                session.host(track: track, serverAddress: serverAddress,
                                             uploadKey: uploadKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .disabled(track.heightField != nil &&
                                      (TrackTransfer.serverURL(serverAddress) == nil || uploadKey.utf8.count < 32))
                        } footer: {
                            if track.heightField != nil {
                                Text("Hosting uploads a temporary copy. Invited riders get the track automatically.")
                            }
                        }
                        Section("Join Invite") {
                            Text("Open a Game Center invitation from your friend to join their Free Ride.")
                        }
                    } else {
                        Section {
                            Button("Sign In to Game Center", action: session.signIn)
                        } footer: {
                            Text("Game Center connects you with invited riders.")
                        }
                    }
                case .preparing:
                    ProgressView("Uploading track…")
                    Button("Cancel", role: .cancel) { session.leave() }
                case .inviting:
                    ProgressView("Connecting to Game Center…")
                case .lobby, .riding:
                    Section("Riders") {
                        ForEach(session.riders) { rider in
                            LabeledContent(rider.name, value: session.phase == .riding && rider.status == .ready
                                           ? "Riding" : rider.status.rawValue)
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
        .tint(.orange)
        .interactiveDismissDisabled(session.phase != .idle && session.phase != .riding)
    }
}
