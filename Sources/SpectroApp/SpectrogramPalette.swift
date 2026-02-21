import SwiftUI

struct RGB8 {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

enum SpectrogramPalette {
    private static let stops: [(position: Float, color: RGB8)] = [
        (0.00, RGB8(r: 0, g: 0, b: 0)),
        (0.12, RGB8(r: 0, g: 0, b: 38)),
        (0.28, RGB8(r: 10, g: 0, b: 96)),
        (0.46, RGB8(r: 84, g: 0, b: 138)),
        (0.62, RGB8(r: 205, g: 0, b: 72)),
        (0.76, RGB8(r: 255, g: 26, b: 0)),
        (0.88, RGB8(r: 255, g: 148, b: 0)),
        (0.96, RGB8(r: 255, g: 225, b: 58)),
        (1.00, RGB8(r: 255, g: 255, b: 245))
    ]

    static func color(for normalizedValue: Float) -> RGB8 {
        let value = min(1, max(0, normalizedValue))

        guard let upperIndex = stops.firstIndex(where: { value <= $0.position }) else {
            return stops.last!.color
        }

        if upperIndex == 0 {
            return stops[0].color
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]

        let span = max(0.0001, upper.position - lower.position)
        let t = (value - lower.position) / span

        return RGB8(
            r: interpolate(lower.color.r, upper.color.r, t: t),
            g: interpolate(lower.color.g, upper.color.g, t: t),
            b: interpolate(lower.color.b, upper.color.b, t: t)
        )
    }

    static var legendGradient: Gradient {
        let gradientStops = stops.map { stop in
            Gradient.Stop(
                color: Color(
                    red: Double(stop.color.r) / 255.0,
                    green: Double(stop.color.g) / 255.0,
                    blue: Double(stop.color.b) / 255.0
                ),
                location: 1 - Double(stop.position)
            )
        }
        .sorted { $0.location < $1.location }

        return Gradient(stops: gradientStops)
    }

    private static func interpolate(_ a: UInt8, _ b: UInt8, t: Float) -> UInt8 {
        UInt8(min(255, max(0, Int((Float(a) + (Float(b) - Float(a)) * t).rounded()))))
    }
}
