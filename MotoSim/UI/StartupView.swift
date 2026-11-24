import SwiftUI

struct StartupView: View {
    let startup: GameScene.Startup
    let retry: () -> Void
    var rideBuiltIn: (() -> Void)?

    private var progress: Double {
        switch startup {
        case .terrain(let fraction): 0.04 + fraction * 0.66
        case .bike: 0.78
        case .camera: 0.95
        case .ready: 1
        case .failed: 0
        }
    }

    private var status: LocalizedStringKey {
        switch startup {
        case .terrain: "Building the dirt circuit"
        case .bike: "Preparing the bike"
        case .camera, .ready: "Starting the ride"
        case .failed: "The circuit couldn’t load."
        }
    }

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("MotoSim")
                    .font(.system(size: 56, weight: .black, design: .monospaced))
                    .italic()
                    .accessibilityAddTraits(.isHeader)
                if startup == .failed {
                    Text(status)
                    HStack {
                        Button("Try again", action: retry)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .foregroundStyle(.black)
                        if let rideBuiltIn {
                            Button("Ride MotoSim Circuit", action: rideBuiltIn)
                                .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                } else {
                    ProgressView(value: progress) {
                        HStack {
                            Text(status)
                            Spacer()
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .accessibilityHidden(true)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .tint(.orange)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 380)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.91))
        .background(Color(red: 0.08, green: 0.067, blue: 0.06).ignoresSafeArea())
    }
}
