import SwiftUI

/// Confetti burst for a finished build.
///
/// A drive takes anywhere from five minutes to over an hour, and the operator is
/// usually doing something else by the time it lands. Worth marking.
///
/// Deliberately cheap: one `TimelineView` driving pure geometry, no per-particle
/// views or animations, so it cannot compete with a build that is still writing.
struct ConfettiView: View {
    /// Restarting the burst — bump this and the particles regenerate.
    let seed: Int

    private struct Particle {
        let x: Double            // 0…1 across the width
        let hue: Double
        let size: Double
        let delay: Double
        let drift: Double        // horizontal travel, in fractions of width
        let spin: Double
        let rectangular: Bool
    }

    private static let duration = 2.6

    /// Generated once per seed rather than per frame.
    private var particles: [Particle] {
        var generator = SplitMix64(seed: UInt64(truncatingIfNeeded: seed) &+ 0x9E37_79B9)
        return (0..<90).map { _ in
            Particle(
                x: generator.unit(),
                hue: generator.unit(),
                size: 5 + generator.unit() * 8,
                delay: generator.unit() * 0.5,
                drift: (generator.unit() - 0.5) * 0.45,
                spin: (generator.unit() - 0.5) * 12,
                rectangular: generator.unit() > 0.35
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let items = particles

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startDate)
                Canvas { context, _ in
                    for particle in items {
                        // Each particle's own clock, offset by its delay.
                        let t = (elapsed - particle.delay) / Self.duration
                        guard t > 0, t < 1 else { continue }

                        // Up fast, then down under gravity — a lob, not a fall.
                        let rise = sin(t * .pi) * height * 0.42
                        let fall = t * t * height * 1.15
                        let y = height * 0.5 - rise + fall
                        let x = width * (particle.x + particle.drift * t)

                        // Fade only at the very end so the burst reads as solid.
                        let opacity = t > 0.75 ? (1 - t) / 0.25 : 1

                        var transform = context
                        transform.opacity = opacity
                        transform.translateBy(x: x, y: y)
                        transform.rotate(by: .radians(particle.spin * t))

                        let rect = CGRect(
                            x: -particle.size / 2,
                            y: -particle.size / 2,
                            width: particle.size,
                            height: particle.rectangular ? particle.size * 0.5 : particle.size
                        )
                        let color = Color(hue: particle.hue, saturation: 0.85, brightness: 0.95)
                        if particle.rectangular {
                            transform.fill(Path(rect), with: .color(color))
                        } else {
                            transform.fill(Path(ellipseIn: rect), with: .color(color))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: seed) { _, _ in startDate = Date() }
    }

    /// Fixed when the burst starts so every particle shares one origin in time,
    /// and reset when `seed` changes so a second build gets a second burst.
    @State private var startDate = Date()
}

/// Small deterministic PRNG. `Math.random`-style APIs would give a different
/// burst on every frame, which is exactly what must not happen here.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0…1
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
