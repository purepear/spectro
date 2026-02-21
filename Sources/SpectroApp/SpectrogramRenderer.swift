import CoreGraphics
import Foundation

enum SpectrogramRenderer {
    private static let paletteResolution = 1024
    private static let paletteLUT: [RGB8] = {
        (0..<paletteResolution).map { index in
            let normalized = Float(index) / Float(max(1, paletteResolution - 1))
            return SpectrogramPalette.color(for: normalized)
        }
    }()

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

        let minHz = Float(max(0, minFrequency))
        let maxHz = Float(max(maxFrequency, Double(minHz) + 1.0))
        let sampleRateFloat = Float(sampleRate)
        let dbSpan = max(0.001, maxDecibels - minDecibels)
        let invDbSpan: Float = 1.0 / dbSpan

        var lowerBins = [Int](repeating: 0, count: height)
        var upperBins = [Int](repeating: 0, count: height)
        var binMixes = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let normalizedY = Float(height - 1 - y) / Float(max(1, height - 1))
            let frequency = minHz + normalizedY * (maxHz - minHz)
            let bin = frequency * Float((bins - 1) * 2) / max(1.0, sampleRateFloat)
            let clamped = min(Float(bins - 1), max(0, bin))

            let lower = Int(clamped)
            lowerBins[y] = lower
            upperBins[y] = min(bins - 1, lower + 1)
            binMixes[y] = clamped - Float(lower)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let palette = paletteLUT
        let paletteMaxIndex = palette.count - 1
        let paletteScale = Float(paletteMaxIndex)

        decibelsByColumn.withUnsafeBufferPointer { decibelsPtr in
            pixels.withUnsafeMutableBufferPointer { pixelsPtr in
                guard
                    let decibelsBase = decibelsPtr.baseAddress,
                    let pixelsBase = pixelsPtr.baseAddress
                else {
                    return
                }

                for y in 0..<height {
                    let lowerBin = lowerBins[y]
                    let upperBin = upperBins[y]
                    let mix = binMixes[y]

                    var sourceLowOffset = lowerBin
                    var sourceHighOffset = upperBin
                    var pixelOffset = y * bytesPerRow

                    for _ in 0..<width {
                        let low = decibelsBase[sourceLowOffset]
                        let high = decibelsBase[sourceHighOffset]
                        let decibels = low + (high - low) * mix

                        let normalized = (decibels - minDecibels) * invDbSpan
                        let clamped = normalized < 0 ? 0 : (normalized > 1 ? 1 : normalized)
                        let paletteIndex = min(paletteMaxIndex, max(0, Int((clamped * paletteScale).rounded())))
                        let color = palette[paletteIndex]

                        pixelsBase[pixelOffset] = color.r
                        pixelsBase[pixelOffset + 1] = color.g
                        pixelsBase[pixelOffset + 2] = color.b
                        pixelsBase[pixelOffset + 3] = 255

                        sourceLowOffset += bins
                        sourceHighOffset += bins
                        pixelOffset += bytesPerPixel
                    }
                }
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
