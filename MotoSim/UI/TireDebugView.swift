import SwiftUI

struct TireDebugView: View {
    let readout: TireDebugReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                legend("Wheel points", color: .cyan)
                legend("Wheel travels", color: .white)
                legend("Tire force", color: .orange)
            }
            Text("Brake \(readout.brakePercent)%  ·  Bars \(readout.barDegrees)°  ·  Lean \(readout.leanDegrees)° / \(readout.targetLeanDegrees)°")
            wheel("F", trace: readout.front)
            wheel("R", trace: readout.rear)
            if readout.recordingTouchdown {
                Text("Recording touchdown…")
            } else if readout.hasTouchdown {
                Text("Touchdown trace ready in Ride Setup")
            }
        }
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .padding(8)
        .background(.black.opacity(0.82), in: .rect(cornerRadius: 8))
        .allowsHitTesting(false)
    }

    private func legend(_ name: String, color: Color) -> some View {
        Text(name).foregroundStyle(color)
    }

    @ViewBuilder
    private func wheel(_ label: String, trace: TireDebugReadout.Wheel) -> some View {
        let direction = trace.speedCM < 0 ? "Rebound" : "Comp"
        let speed = (Double(abs(trace.speedCM)) / 100).formatted(.number.precision(.fractionLength(2)))
        Text("\(label)  \(trace.travelMM) mm  \(direction) \(speed) m/s  Bottom \(trace.bottomOuts)")
        if !trace.contact {
            Text("\(label)  Airborne")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                Text("\(label)  Side \(trace.slipDegrees)°  Slip \(trace.slipPercent)%  Grip \(trace.gripUsed)%  \(trace.load) N")
                if trace.locked {
                    Text("LOCK").foregroundStyle(.yellow)
                }
            }
        }
    }
}
