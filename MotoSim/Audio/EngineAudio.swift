import AVFoundation
import Synchronization

@MainActor
final class EngineAudio {
    private let engine = AVAudioEngine()
    private let exhaust: ExhaustSynth

    init?() {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }

        let exhaust = ExhaustSynth(sampleRate: Float(sampleRate))
        self.exhaust = exhaust
        let source = AVAudioSourceNode(format: format) { _, _, frames, audioBuffers in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBuffers)
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            exhaust.render(to: data, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() -> Bool {
        if engine.isRunning { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try engine.start()
            return true
        } catch {
            stop()
            return false
        }
    }

    func pause() {
        engine.pause()
    }

    func stop() {
        engine.stop()
    }

    func update(rpm: Float, throttle: Float, ignitionCut: Bool) {
        exhaust.update(rpm: rpm, throttle: throttle, ignitionCut: ignitionCut)
    }
}

private final class ExhaustSynth: @unchecked Sendable {
    // The main thread publishes one atomic snapshot. Oscillator state belongs to the render thread.
    private let controls = Atomic<UInt32>(2200)
    private let sampleRate: Float
    private let rpmResponse: Float
    private let throttleResponse: Float
    private var rpm: Float = 2200
    private var throttle: Float = 0
    private var phase: Float = 0
    private var crankPhase: Float = 0
    private var mechanicalTone: Float = 0
    private var intervalVariation: Float = 1
    private var wasCut = false
    private var randomState: UInt32 = 0xA341316C
    private var noiseEnvelope: Float = 0
    private var filteredNoise: Float = 0
    private var body: Resonator
    private var pipe: Resonator
    private var crack: Resonator

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        rpmResponse = 1 - exp(-1 / (0.022 * sampleRate))
        throttleResponse = 1 - exp(-1 / (0.020 * sampleRate))
        body = Resonator(frequency: 113, decay: 0.010, sampleRate: sampleRate)
        pipe = Resonator(frequency: 306, decay: 0.005, sampleRate: sampleRate)
        crack = Resonator(frequency: 790, decay: 0.0023, sampleRate: sampleRate)
    }

    func update(rpm: Float, throttle: Float, ignitionCut: Bool) {
        let speed = UInt32(max(1_200, min(16_000, rpm)))
        let load = UInt32(max(0, min(1, throttle)) * 255)
        controls.store(speed | (load << 16) | (ignitionCut ? 1 << 24 : 0), ordering: .relaxed)
    }

    func render(to output: UnsafeMutablePointer<Float>, frames: Int) {
        let snapshot = controls.load(ordering: .relaxed)
        let targetRPM = Float(snapshot & 0xFFFF)
        let targetThrottle = Float((snapshot >> 16) & 0xFF) / 255
        let ignitionCut = snapshot & (1 << 24) != 0
        for frame in 0..<frames {
            rpm += (targetRPM - rpm) * rpmResponse
            throttle += (targetThrottle - throttle) * throttleResponse

            // Crankshaft and intake noise continue when the ignition skips combustion.
            crankPhase += rpm / (60 * sampleRate)
            if crankPhase >= 1 { crankPhase -= 1 }
            let crankWave = 1 - 4 * abs(crankPhase - 0.5)
            mechanicalTone += (crankWave - mechanicalTone) * 0.07

            // A single-cylinder four-stroke fires once every two crankshaft revolutions.
            phase += rpm * intervalVariation / (120 * sampleRate)
            var pulse: Float = 0
            var edge: Float = 0
            if phase >= 1 {
                phase -= 1
                intervalVariation = 1 + random() * (0.004 + 0.024 * (1 - throttle))
                if ignitionCut {
                    pulse = 0.035 + throttle * 0.035
                    noiseEnvelope += pulse * 0.29
                } else {
                    pulse = (0.11 + 0.32 * throttle) * (1 + 0.14 * random())
                    edge = pulse * (wasCut ? 1.65 : 0.55 + 0.45 * throttle)
                    noiseEnvelope += edge * 0.72
                }
                wasCut = ignitionCut
            }

            filteredNoise += (random() - filteredNoise) * 0.18
            noiseEnvelope *= 0.987
            let signal = body.step(pulse) * 0.95 + pipe.step(pulse) * 0.53
                + crack.step(edge) * 0.24 + filteredNoise * (noiseEnvelope + 0.012)
                + mechanicalTone * (0.040 + 0.022 * throttle)
            output[frame] = signal / (1 + abs(signal))
        }
    }

    private func random() -> Float {
        randomState ^= randomState << 13
        randomState ^= randomState >> 17
        randomState ^= randomState << 5
        return Float(randomState >> 8) * (2 / 16_777_215) - 1
    }
}

private struct Resonator {
    private let feedback: Float
    private let decaySquared: Float
    private let inputGain: Float
    private var last: Float = 0
    private var previous: Float = 0

    init(frequency: Float, decay: Float, sampleRate: Float) {
        let angle = 2 * Float.pi * frequency / sampleRate
        let radius = exp(-1 / (decay * sampleRate))
        feedback = 2 * radius * cos(angle)
        decaySquared = radius * radius
        inputGain = sin(angle)
    }

    mutating func step(_ input: Float) -> Float {
        let sample = input * inputGain + feedback * last - decaySquared * previous
        previous = last
        last = sample
        return sample
    }
}
