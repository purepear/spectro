import CoreGraphics
import Foundation

enum SpectrogramRenderer {
    static func render(
        decibelsByColumn: [Float],
        columns: Int,
        bins: Int,
        sampleRate: Double,
        minFrequency: Double,
        maxFrequency: Double,
        minDecibels: Float,
        maxDecibels: Float,
        imageHeight: Int
    ) -> CGImage? {
        guard columns > 0, bins > 1, imageHeight > 0 else {
            return nil
        }

        let width = columns
        let height = imageHeight
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let minHz = max(0, minFrequency)
        let maxHz = max(maxFrequency, minHz + 1)
        let dbSpan = max(0.001, maxDecibels - minDecibels)

        var mappedBin = [Double](repeating: 0, count: height)
        for y in 0..<height {
            let normalizedY = Double(height - 1 - y) / Double(max(1, height - 1))
            let frequency = minHz + normalizedY * (maxHz - minHz)
            let bin = frequency * Double((bins - 1) * 2) / sampleRate
            mappedBin[y] = min(Double(bins - 1), max(0, bin))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            let binPosition = mappedBin[y]
            let lowerBin = Int(binPosition)
            let upperBin = min(bins - 1, lowerBin + 1)
            let mix = Float(binPosition - Double(lowerBin))

            for x in 0..<width {
                let sourceOffset = x * bins
                let low = decibelsByColumn[sourceOffset + lowerBin]
                let high = decibelsByColumn[sourceOffset + upperBin]
                let decibels = low + (high - low) * mix

                let normalized = min(1, max(0, (decibels - minDecibels) / dbSpan))
                let color = SpectrogramPalette.color(for: normalized)

                let pixelOffset = (y * width + x) * bytesPerPixel
                pixels[pixelOffset] = color.r
                pixels[pixelOffset + 1] = color.g
                pixels[pixelOffset + 2] = color.b
                pixels[pixelOffset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
