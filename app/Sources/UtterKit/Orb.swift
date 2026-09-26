import SwiftUI

/// The dotted "thinking orb" shown while listening: particles running on
/// tilted orbits around a faint dotted shell.
///
/// A native port of the `orbits` mode ("working" state) of thinking-orbs by
/// Jakub Antalik (MIT, https://github.com/Jakubantalik/Libraries.dev). The
/// geometry and tuning are the library's; drawing is a SwiftUI `Canvas`.
/// Its web-only "gravity" cursor effect isn't ported: the overlay never
/// takes the mouse, and an app can't redraw the system pointer.
struct OrbView: View {
    /// 0…1, how loud the user is; the orb swells a little with their voice.
    var level: Float = 0
    /// Multiplier on the tuned speed (the transcribing state runs slower).
    var speed: Double = 1
    var size: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = OrbGeometry.resolve(size: Double(size))
        Group {
            if reduceMotion {
                canvas(geometry, time: 0.6)
            } else {
                TimelineView(.animation) { context in
                    canvas(geometry, time: context.date.timeIntervalSinceReferenceDate * geometry.speed * speed)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func canvas(_ geometry: OrbGeometry, time: Double) -> some View {
        let swell = 1 + 0.22 * Double(min(max(level, 0), 1))
        return Canvas { context, canvasSize in
            for dot in geometry.frame(time: time, swell: swell) {
                let rect = CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2)
                // Dark substrate: the ink value is mirrored, so near dots read bright.
                let gray = 1 - dot.white
                context.fill(Path(ellipseIn: rect), with: .color(Color(white: gray, opacity: dot.alpha)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The `orbits` mode's geometry, resolved for one size.
struct OrbGeometry: Equatable {
    struct Dot: Equatable {
        var x, y, z, r, white, alpha: Double
    }

    struct Orbit: Equatable {
        var radius: Double
        var u: SIMD3<Double>
        var v: SIMD3<Double>
        var speed: Double
        var phase: Double
    }

    let size: Double
    let speed: Double
    let orbits: [Orbit]
    let ghostCount: Int
    let particles: Int
    let ghostRadius: Double
    let particleRadius: Double
    let particleDepthRadius: Double

    /// The library tunes two sizes (32 and 64 px); sizes between blend them.
    static func resolve(size: Double) -> OrbGeometry {
        let t = min(max((size - 32) / 32, 0), 1)
        func blend(_ small: Double, _ large: Double) -> Double { small + (large - small) * t }
        let speed = blend(2.9072, 1.885)
        let countScale = blend(0.4251, 1)
        let sizeScale = blend(1.6849, 1)
        let orbitCount = max(1, Int((12 * countScale).rounded()))
        let ghostCount = max(1, Int((40 * countScale).rounded()))
        let radiusScale = pow(size / 300, 0.6) * sizeScale
        let shell = size / 2 * 0.82
        let orbits = (0..<orbitCount).map { index -> Orbit in
            let i = Double(index)
            let h1 = hash(i, 1.7), h2 = hash(i, 5.2), h3 = hash(i, 8.9)
            let theta = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let n = SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            var u = SIMD3(-n.y, n.x, 0)
            u /= max(1e-6, (u.x * u.x + u.y * u.y).squareRoot())
            let v = SIMD3(n.z * u.y - n.y * u.z, n.x * u.z - n.z * u.x, n.y * u.x - n.x * u.y)
            return Orbit(radius: shell * (0.45 + 0.52 * h1), u: u, v: v,
                         speed: (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1), phase: h2 * 6)
        }
        return OrbGeometry(size: size, speed: speed, orbits: orbits, ghostCount: ghostCount, particles: 3,
                           ghostRadius: 0.9 * radiusScale, particleRadius: 1.2 * radiusScale,
                           particleDepthRadius: 1.6 * radiusScale)
    }

    /// Deterministic hash in [0, 1), as in the library.
    static func hash(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// Every dot at time `time`, sorted far to near (the draw order).
    func frame(time: Double, swell: Double = 1) -> [Dot] {
        let center = size / 2
        let yaw = time * 0.12, tilt = 0.3
        let sy = sin(yaw), cy = cos(yaw), st = sin(tilt), ct = cos(tilt)
        func project(_ p: SIMD3<Double>) -> (Double, Double, Double) {
            let x1 = p.x * cy + p.z * sy
            let z1 = -p.x * sy + p.z * cy
            let y1 = p.y * ct - z1 * st
            let z2 = p.y * st + z1 * ct
            return (center + x1, center - y1, z2)
        }
        var dots: [Dot] = []
        dots.reserveCapacity(orbits.count * (ghostCount + particles))
        for orbit in orbits {
            let radius = orbit.radius * swell
            func point(_ a: Double) -> SIMD3<Double> { (orbit.u * cos(a) + orbit.v * sin(a)) * radius }
            for k in 0..<ghostCount {
                let (x, y, z) = project(point(Double(k) / Double(ghostCount) * 2 * .pi))
                let depth = (z / radius + 1) / 2
                // The library's shell ink is 0.72; at pill size on a translucent dark
                // background that vanished, so it's a little brighter here.
                dots.append(Dot(x: x, y: y, z: z, r: ghostRadius, white: 0.5, alpha: 0.6 * (0.4 + 0.6 * depth)))
            }
            for m in 0..<particles {
                let a = time * orbit.speed + Double(m) / Double(particles) * 2 * .pi + orbit.phase
                let (x, y, z) = project(point(a))
                let depth = (z / radius + 1) / 2
                dots.append(Dot(x: x, y: y, z: z, r: particleRadius + particleDepthRadius * depth,
                                white: 0.3 - 0.22 * depth, alpha: 1))
            }
        }
        return dots
            .filter { $0.alpha >= 0.02 }
            .map { var d = $0; d.r = max(0.3, d.r); return d }
            .sorted { $0.z < $1.z }
    }
}
