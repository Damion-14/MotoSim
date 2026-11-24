import SwiftUI
import UniformTypeIdentifiers

private struct TouchdownCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct RideSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tuning: RideTuning
    @Binding var showTireDebug: Bool

    let touchdownCSV: String
    @State private var exportingTrace = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    adjustment("Maximum lean", value: $tuning.maximumLeanDegrees,
                               range: RideTuning.leanRange, step: 1,
                               display: "\(Int(tuning.maximumLeanDegrees))°")
                    adjustment("Tire grip", value: $tuning.tireGrip,
                               range: RideTuning.gripRange, step: 0.05,
                               display: percent(tuning.tireGrip))
                } header: {
                    Text("Handling")
                } footer: {
                    Text("Grip scales the traction available on each surface. More lean needs more grip to hold a tighter line.")
                }
                Section {
                    adjustment("Fork rebound", value: $tuning.forkRebound,
                               range: RideTuning.reboundRange, step: 0.05,
                               display: percent(tuning.forkRebound))
                    adjustment("Shock rebound", value: $tuning.shockRebound,
                               range: RideTuning.reboundRange, step: 0.05,
                               display: percent(tuning.shockRebound))
                    adjustment("Fork compression", value: $tuning.forkCompression,
                               range: RideTuning.compressionRange, step: 0.05,
                               display: percent(tuning.forkCompression))
                    adjustment("Shock low-speed compression", value: $tuning.shockLowSpeedCompression,
                               range: RideTuning.compressionRange, step: 0.05,
                               display: percent(tuning.shockLowSpeedCompression))
                    adjustment("Shock high-speed compression", value: $tuning.shockHighSpeedCompression,
                               range: RideTuning.compressionRange, step: 0.05,
                               display: percent(tuning.shockHighSpeedCompression))
                    Picker("Fork spring rate", selection: Binding(
                        get: { tuning.selectedForkSpringRate }, set: { tuning.forkSpringRate = $0 }
                    )) {
                        ForEach(RideTuning.forkSpringRates, id: \.self) { rate in
                            Text("\(rate.formatted(.number.precision(.fractionLength(0)))) N/mm").tag(rate)
                        }
                    }
                    adjustment("Rear spring preload", value: $tuning.shockPreload,
                               range: RideTuning.preloadRange, step: 0.5,
                               display: "\(tuning.shockPreload.formatted(.number.precision(.fractionLength(0...1)))) mm")
                    let configuration = BikeConfiguration()
                    let staticSag = Int((configuration.rearSag(tuning: tuning, withRider: false) * 1000).rounded())
                    let riderSag = Int((configuration.rearSag(tuning: tuning, withRider: true) * 1000).rounded())
                    LabeledContent("Estimated rear sag", value: "\(staticSag) mm static / \(riderSag) mm rider")
                } header: {
                    Text("Suspension")
                } footer: {
                    Text("Fork spring rate is the combined rate for both fork legs. Higher rebound damping slows extension and can leave the suspension compressed through repeated bumps. Shock compression settings respond to damper shaft speed.")
                }
                Section("Diagnostics") {
                    Toggle("Tire & Suspension Telemetry", isOn: $showTireDebug)
                    Button("Export Last Touchdown CSV") { exportingTrace = true }
                        .disabled(touchdownCSV.isEmpty)
                }
            }
            .fileExporter(isPresented: $exportingTrace, document: TouchdownCSV(text: touchdownCSV),
                          contentType: .commaSeparatedText, defaultFilename: "MotoSim-Touchdown") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert("Trace Export", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .tint(.orange)
            .navigationTitle("Ride Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset to Defaults") { tuning = RideTuning() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func adjustment(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                            display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: step) { Text(name) }
                .accessibilityValue(display)
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
