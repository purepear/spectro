import Accelerate
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation

struct SpectrogramConfig {
    let fftSize: Int
    let hopSize: Int
    let minFrequency: Double
    let minDecibels: Float
    let maxDecibels: Float
    let maxColumns: Int
    let imageHeight: Int

    static let v1 = SpectrogramConfig(
        fftSize: 2048,
        hopSize: 512,
        minFrequency: 0,
        minDecibels: -120,
        maxDecibels: 0,
        maxColumns: 2800,
        imageHeight: 760
    )
}

struct SpectrogramResult {
    let image: CGImage
    let fileName: String
    let duration: TimeInterval
    let sampleRate: Double
    let sourceChannelCount: Int
    let minFrequency: Double
    let maxFrequency: Double
    let minDecibels: Float
    let maxDecibels: Float
    let fftSize: Int
    let hopSize: Int
    let renderedWidth: Int
    let renderedHeight: Int
}

enum SpectrogramAnalyzerError: LocalizedError {
    case invalidFFTSize
    case fftSetupFailed
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFFTSize:
            return "FFT size must be a power of two and greater than zero."
        case .fftSetupFailed:
            return "Could not initialize FFT setup."
        case .renderingFailed:
            return "Could not render spectrogram image."
        }
    }
}

private struct AggregatedSpectrum {
    let decibelsByColumn: [Float]
    let columns: Int
    let bins: Int
}

enum SpectrogramAnalyzer {
    static func analyze(url: URL, config: SpectrogramConfig = .v1) async throws -> SpectrogramResult {
        try await Task.detached(priority: .userInitiated) {
            let decoded = try await AudioDecoder.decodeMonoSamples(from: url)
            try throwIfCancelled()

            let cutoffHintHz = await lossyCodecCutoffHint(
                for: url,
                sampleRate: decoded.sampleRate,
                fallbackChannelCount: decoded.channelCount
            )

            let aggregated = try aggregateSpectrum(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                cutoffHintHz: cutoffHintHz,
                config: config
            )
            try throwIfCancelled()

            let maxFrequency = decoded.sampleRate / 2.0
            guard let image = SpectrogramRenderer.render(
                decibelsByColumn: aggregated.decibelsByColumn,
                columns: aggregated.columns,
                bins: aggregated.bins,
                sampleRate: decoded.sampleRate,
                minFrequency: config.minFrequency,
                maxFrequency: maxFrequency,
                minDecibels: config.minDecibels,
                maxDecibels: config.maxDecibels,
                imageHeight: config.imageHeight
            ) else {
                throw SpectrogramAnalyzerError.renderingFailed
            }

            return SpectrogramResult(
                image: image,
                fileName: url.lastPathComponent,
                duration: decoded.duration,
                sampleRate: decoded.sampleRate,
                sourceChannelCount: decoded.channelCount,
                minFrequency: config.minFrequency,
                maxFrequency: maxFrequency,
                minDecibels: config.minDecibels,
                maxDecibels: config.maxDecibels,
                fftSize: config.fftSize,
                hopSize: config.hopSize,
                renderedWidth: aggregated.columns,
                renderedHeight: config.imageHeight
            )
        }.value
    }

    private static func aggregateSpectrum(
        samples: [Float],
        sampleRate: Double,
        cutoffHintHz: Double?,
        config: SpectrogramConfig
    ) throws -> AggregatedSpectrum {
        guard isPowerOfTwo(config.fftSize), config.fftSize > 0 else {
            throw SpectrogramAnalyzerError.invalidFFTSize
        }

        let paddedFrameCount = requiredFrameCount(sampleCount: samples.count, fftSize: config.fftSize, hopSize: config.hopSize)
        let requiredSampleCount = (paddedFrameCount - 1) * config.hopSize + config.fftSize

        var paddedSamples = samples
        if paddedSamples.count < requiredSampleCount {
            paddedSamples.append(contentsOf: repeatElement(0, count: requiredSampleCount - paddedSamples.count))
        }

        let bins = (config.fftSize / 2) + 1
        let columns = min(paddedFrameCount, config.maxColumns)
        let framesPerColumn = Double(paddedFrameCount) / Double(columns)

        var aggregatedPowerSums = [Float](repeating: 0, count: columns * bins)
        var columnFrameCounts = [Int](repeating: 0, count: columns)

        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: config.fftSize,
            isHalfWindow: false
        )

        let fftSize = config.fftSize
        let halfSize = fftSize / 2
        let log2n = vDSP_Length(Int(log2(Double(fftSize))))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw SpectrogramAnalyzerError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let coherentGain = max(window.reduce(0, +) / Float(fftSize), 1e-6)
        let edgeScale = 1.0 / (Float(fftSize * fftSize) * coherentGain * coherentGain)
        let interiorScale = edgeScale * 4.0

        var fftInput = [Float](repeating: 0, count: fftSize)
        var splitReal = [Float](repeating: 0, count: halfSize)
        var splitImag = [Float](repeating: 0, count: halfSize)

        try fftInput.withUnsafeMutableBufferPointer { fftInputPtr in
            try splitReal.withUnsafeMutableBufferPointer { splitRealPtr in
                try splitImag.withUnsafeMutableBufferPointer { splitImagPtr in
                    guard
                        let fftInputBase = fftInputPtr.baseAddress,
                        let splitRealBase = splitRealPtr.baseAddress,
                        let splitImagBase = splitImagPtr.baseAddress
                    else {
                        throw SpectrogramAnalyzerError.fftSetupFailed
                    }

                    var splitComplex = DSPSplitComplex(realp: splitRealBase, imagp: splitImagBase)

                    for frameIndex in 0..<paddedFrameCount {
                        if frameIndex % 64 == 0 {
                            try throwIfCancelled()
                        }

                        let start = frameIndex * config.hopSize
                        var frameMean: Float = 0
                        for sampleIndex in 0..<fftSize {
                            frameMean += paddedSamples[start + sampleIndex]
                        }
                        frameMean /= Float(fftSize)

                        for sampleIndex in 0..<fftSize {
                            let centered = paddedSamples[start + sampleIndex] - frameMean
                            fftInputPtr[sampleIndex] = centered * window[sampleIndex]
                        }

                        fftInputBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexBuffer in
                            vDSP_ctoz(
                                complexBuffer,
                                2,
                                &splitComplex,
                                1,
                                vDSP_Length(halfSize)
                            )
                        }

                        vDSP_fft_zrip(
                            fftSetup,
                            &splitComplex,
                            1,
                            log2n,
                            FFTDirection(FFT_FORWARD)
                        )

                        let columnIndex = min(columns - 1, Int(Double(frameIndex) / framesPerColumn))
                        let columnOffset = columnIndex * bins
                        columnFrameCounts[columnIndex] += 1

                        let dc = splitRealBase[0] * splitRealBase[0] * edgeScale
                        aggregatedPowerSums[columnOffset] += dc

                        if bins > 2 {
                            for bin in 1..<(bins - 1) {
                                let real = splitRealBase[bin]
                                let imag = splitImagBase[bin]
                                let power = (real * real + imag * imag) * interiorScale
                                aggregatedPowerSums[columnOffset + bin] += power
                            }
                        }

                        let nyquist = splitImagBase[0] * splitImagBase[0] * edgeScale
                        aggregatedPowerSums[columnOffset + bins - 1] += nyquist
                    }
                }
            }
        }

        let averagePowers = averagedPowers(
            aggregatedPowerSums: aggregatedPowerSums,
            columnFrameCounts: columnFrameCounts,
            columns: columns,
            bins: bins
        )

        var aggregatedDecibels = [Float](repeating: config.minDecibels, count: columns * bins)
        for index in 0..<(columns * bins) {
            let power = max(averagePowers[index], 1e-20)
            let decibels = 10 * log10(power)
            aggregatedDecibels[index] = min(config.maxDecibels, max(config.minDecibels, decibels))
        }

        if let cutoffHintHz {
            let nyquist = sampleRate / 2.0
            if nyquist > 0 {
                let normalized = min(1.0, max(0.0, cutoffHintHz / nyquist))
                let hintedBin = Int((Double(bins - 1) * normalized).rounded())
                let cutoffBin = min(max(0, hintedBin), bins - 1)
                clampToCutoff(
                    decibels: &aggregatedDecibels,
                    columns: columns,
                    bins: bins,
                    cutoffBin: cutoffBin,
                    floorDecibels: config.minDecibels
                )
            }
        }

        return AggregatedSpectrum(
            decibelsByColumn: aggregatedDecibels,
            columns: columns,
            bins: bins
        )
    }

    private static func averagedPowers(
        aggregatedPowerSums: [Float],
        columnFrameCounts: [Int],
        columns: Int,
        bins: Int
    ) -> [Float] {
        var averagePowers = [Float](repeating: 0, count: columns * bins)
        for column in 0..<columns {
            let frameCount = max(1, columnFrameCounts[column])
            let columnOffset = column * bins

            for bin in 0..<bins {
                averagePowers[columnOffset + bin] = aggregatedPowerSums[columnOffset + bin] / Float(frameCount)
            }
        }

        return averagePowers
    }

    private static func lossyCodecCutoffHint(
        for url: URL,
        sampleRate: Double,
        fallbackChannelCount: Int
    ) async -> Double? {
        let asset = AVURLAsset(url: url)

        guard
            let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let formatDescriptions = try? await track.load(.formatDescriptions),
            let formatDescription = formatDescriptions.first
        else {
            return nil
        }

        let cmFormat = formatDescription as CMFormatDescription
        guard CMFormatDescriptionGetMediaType(cmFormat) == kCMMediaType_Audio else {
            return nil
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat)?.pointee else {
            return nil
        }

        let lossyIDs: Set<AudioFormatID> = [
            kAudioFormatMPEGLayer3,
            kAudioFormatMPEG4AAC,
            kAudioFormatMPEG4AAC_HE,
            kAudioFormatMPEG4AAC_HE_V2,
            kAudioFormatMPEG4AAC_ELD,
            kAudioFormatMPEG4AAC_LD,
            kAudioFormatOpus
        ]

        guard lossyIDs.contains(asbd.mFormatID) else {
            return nil
        }

        let bitRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
        guard bitRate > 0 else {
            return nil
        }

        let channelCount = max(1, Int(asbd.mChannelsPerFrame), fallbackChannelCount)
        let perChannelBitRate = bitRate / Double(channelCount)

        let cutoffHz: Double?
        switch perChannelBitRate {
        case ..<48_000:
            cutoffHz = 12_000
        case ..<64_000:
            cutoffHz = 14_000
        case ..<80_000:
            cutoffHz = 15_500
        case ..<96_000:
            cutoffHz = 17_000
        case ..<112_000:
            cutoffHz = 18_500
        default:
            cutoffHz = nil
        }

        guard let cutoffHz else { return nil }
        return min(cutoffHz, sampleRate / 2.0)
    }

    private static func clampToCutoff(
        decibels: inout [Float],
        columns: Int,
        bins: Int,
        cutoffBin: Int,
        floorDecibels: Float
    ) {
        guard cutoffBin >= 0, cutoffBin < bins - 1 else { return }

        for column in 0..<columns {
            let offset = column * bins
            for bin in (cutoffBin + 1)..<bins {
                decibels[offset + bin] = floorDecibels
            }
        }
    }

    private static func requiredFrameCount(sampleCount: Int, fftSize: Int, hopSize: Int) -> Int {
        guard sampleCount > 0 else { return 1 }
        guard sampleCount > fftSize else { return 1 }

        let overlappedCount = sampleCount - fftSize
        return Int(ceil(Double(overlappedCount) / Double(hopSize))) + 1
    }

    private static func isPowerOfTwo(_ value: Int) -> Bool {
        value > 0 && (value & (value - 1)) == 0
    }

    private static func throwIfCancelled() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }
}
