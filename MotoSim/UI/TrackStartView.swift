import SwiftUI

struct TrackStartView: View {
    let track: Track
    let ride: (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var point: CGPoint
    @State private var heading: Double

    init(track: Track, ride: @escaping (Track) -> Void) {
        self.track = track
        self.ride = ride
        let width = track.halfExtents.x * 2
        let length = track.halfExtents.y * 2
        _point = State(initialValue: CGPoint(x: CGFloat(track.startPosition.x / width + 0.5),
                                             y: CGFloat(track.startPosition.z / length + 0.5)))
        _heading = State(initialValue: Double(track.startHeading) * 180 / .pi)
    }

    private var width: Float { track.halfExtents.x * 2 }
    private var length: Float { track.halfExtents.y * 2 }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 24) {
                terrainMap
                    .frame(width: min(geometry.size.width * 0.48, geometry.size.height * CGFloat(width / length)))
                    .aspectRatio(CGFloat(width / length), contentMode: .fit)
                VStack(alignment: .leading, spacing: 12) {
                    Text(track.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text("Tap the map to set your start.")
                        .foregroundStyle(.secondary)
                    Slider(value: $heading, in: 0...360, step: 5) {
                        Text("Heading")
                    }
                    Text("Heading \(Int(heading))°")
                        .font(.caption.monospacedDigit())
                    HStack {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Ride") {
                            var selected = track
                            let start = position(u: Float(point.x), v: Float(point.y))
                            selected.startPosition = [start.x, 0, start.y]
                            selected.startHeading = Float(heading) * .pi / 180
                            ride(selected)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .foregroundStyle(.black)
                    }
                }
                .frame(maxWidth: 270)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }

    private func position(u: Float, v: Float) -> SIMD2<Float> {
        [(u - 0.5) * width, (v - 0.5) * length]
    }

    private var terrainMap: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let marker = CGPoint(x: point.x * size.width, y: point.y * size.height)
            Group {
                if let image = track.groundArt?.makeImage() {
                    Image(decorative: image, scale: 1)
                        .resizable()
                } else {
                    heightPreview
                }
            }
            .overlay {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white, .orange)
                    .rotationEffect(.degrees(180 - heading))
                    .position(marker)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(SpatialTapGesture().onEnded { tap in
                let xMargin = min(0.25, 1.5 / CGFloat(width))
                let zMargin = min(0.25, 1.5 / CGFloat(length))
                point = CGPoint(x: min(1 - xMargin, max(xMargin, tap.location.x / size.width)),
                                y: min(1 - zMargin, max(zMargin, tap.location.y / size.height)))
            })
            .accessibilityLabel("Start location map")
        }
    }

    private var heightPreview: some View {
        Canvas { context, size in
            let divisions = 64
            let cell = CGSize(width: size.width / CGFloat(divisions), height: size.height / CGFloat(divisions))
            let elevations = track.heightField?.elevationBounds ?? -0.3...3.0
            let minHeight = elevations.lowerBound
            let maxHeight = elevations.upperBound
            let range = max(0.01, maxHeight - minHeight)
            for row in 0..<divisions {
                for column in 0..<divisions {
                    let center = position(u: (Float(column) + 0.5) / Float(divisions),
                                          v: (Float(row) + 0.5) / Float(divisions))
                    let height = track.height(center.x, center.y)
                    let offset = position(u: (Float(column) + 1.5) / Float(divisions),
                                          v: (Float(row) - 0.5) / Float(divisions))
                    let slope = (track.height(offset.x, offset.y) - height) / max(1, width / Float(divisions))
                    let lane = track.heightField == nil && abs(track.coordinates(center.x, center.y).offset) < 4
                    let shade = Double(max(0.16, min(0.80, 0.40 + 0.22 * (height - minHeight) / range + slope)))
                    let rect = CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                                      width: cell.width + 0.5, height: cell.height + 0.5)
                    let color = lane ? Color(red: shade + 0.25, green: shade + 0.11, blue: shade)
                        : Color(red: shade + 0.1, green: shade * 0.90, blue: shade * 0.71)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
