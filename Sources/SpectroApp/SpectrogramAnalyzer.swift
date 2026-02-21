import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

struct SpectrogramConfig {
    let fftSize: Int
    let hopSize: Int
    let minFrequency: Double
    let minDecibels: Float
    let maxDecibels: Float
    let maxColumns: Int
    let targetFramesPerColumn: Int
    let imageHeight: Int

    static let v1 = SpectrogramConfig(
        fftSize: 2048,
        hopSize: 512,
        minFrequency: 0,
        minDecibels: -120,
        maxDecibels: 0,
        maxColumns: 1400,
        targetFramesPerColumn: 2,
        imageHeight: 760
    )
}

struct SpectrogramResult {
    let image: CGImage
    let fileName: String
    let duration: TimeInterval
    let sampleRate: Double
    let sourceChannelCount: Int
    let sourceContainerFormat: String
    let sourceCodec: String
    let sourceBitRate: Double?
    let minFrequency: Double
    let maxFrequency: Double
    let minDecibels: Float
    let maxDecibels: Float
    let fftSize: Int
    let hopSize: Int
}

enum SpectrogramAnalyzerError: LocalizedError {
    case fftSetupFailed
    case renderingFailed
    case noAudioTrack
    case cannotCreateAssetReader
    case cannotAddReaderOutput
    case cannotReadSampleBuffer
    case emptyAnalysis

    var errorDescription: String? {
        switch self {
        case .fftSetupFailed:
            return "Could not initialize FFT setup."
        case .renderingFailed:
            return "Could not render spectrogram image."
        case .noAudioTrack:
            return "No audio track was found in this file."
        case .cannotCreateAssetReader:
            return "Could not create AVAssetReader for this file."
        case .cannotAddReaderOutput:
            return "Could not configure AVAssetReader output."
        case .cannotReadSampleBuffer:
            return "Could not read audio sample buffers from this file."
        case .emptyAnalysis:
            return "This file appears to contain no readable audio samples."
        }
    }
}

private struct AggregatedSpectrum {
    let decibelsByColumn: [Float]
    let columns: Int
    let bins: Int
}

private struct StreamingAnalysisResult {
    let spectrum: AggregatedSpectrum
    let sampleRate: Double
    let sourceChannelCount: Int
    let sourceContainerFormat: String
    let sourceCodec: String
    let sourceBitRate: Double?
    let duration: TimeInterval
}

enum SpectrogramAnalyzer {
    static func analyze(url: URL, config: SpectrogramConfig = .v1) async throws -> SpectrogramResult {
        try await Task.detached(priority: .userInitiated) {
            let streaming = try await analyzeUsingAVAssetReaderStream(url: url, config: config)
            let maxFrequency = streaming.sampleRate / 2.0

            guard let image = SpectrogramRenderer.render(
                decibelsByColumn: streaming.spectrum.decibelsByColumn,
                columns: streaming.spectrum.columns,
                bins: streaming.spectrum.bins,
                sampleRate: streaming.sampleRate,
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
                duration: streaming.duration,
                sampleRate: streaming.sampleRate,
                sourceChannelCount: streaming.sourceChannelCount,
                sourceContainerFormat: streaming.sourceContainerFormat,
                sourceCodec: streaming.sourceCodec,
                sourceBitRate: streaming.sourceBitRate,
                minFrequency: config.minFrequency,
                maxFrequency: maxFrequency,
                minDecibels: config.minDecibels,
                maxDecibels: config.maxDecibels,
                fftSize: config.fftSize,
                hopSize: config.hopSize
            )
        }.value
    }

    private static func analyzeUsingAVAssetReaderStream(url: URL, config: SpectrogramConfig) async throws -> StreamingAnalysisResult {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SpectrogramAnalyzerError.noAudioTrack
        }

        let initialDetails = await trackAudioDetails(track)
        var sampleRate = initialDetails.sampleRate > 0 ? initialDetails.sampleRate : 44_100
        var sourceChannelCount = max(1, initialDetails.channelCount)

        let assetDurationTime = (try? await asset.load(.duration)) ?? CMTime.invalid
        let durationSeconds = finiteSeconds(assetDurationTime)
        let sourceInfo = await sourceAudioInfo(
            for: url,
            track: track,
            formatID: initialDetails.formatID,
            durationSeconds: durationSeconds
        )
        let estimatedSampleCount = max(config.fftSize, Int(durationSeconds * sampleRate))

        let frameEstimate = requiredFrameCount(
            sampleCount: estimatedSampleCount,
            fftSize: config.fftSize,
            hopSize: config.hopSize
        )

        let roughColumns = min(frameEstimate, config.maxColumns)
        let desiredProcessedFrames = max(1, roughColumns * max(1, config.targetFramesPerColumn))
        let frameStride = max(1, frameEstimate / desiredProcessedFrames)
        let bins = (config.fftSize / 2) + 1

        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: config.fftSize,
            isHalfWindow: false
        )

        let fftSize = config.fftSize
        let halfSize = fftSize / 2
        let coherentGain = max(window.reduce(0, +) / Float(fftSize), 1e-6)
        let edgeScale = 1.0 / (Float(fftSize * fftSize) * coherentGain * coherentGain)
        let interiorScale = edgeScale * 4.0

        let log2n = vDSP_Length(Int(log2(Double(fftSize))))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw SpectrogramAnalyzerError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SpectrogramAnalyzerError.cannotCreateAssetReader
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw SpectrogramAnalyzerError.cannotAddReaderOutput
        }

        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SpectrogramAnalyzerError.cannotCreateAssetReader
        }

        let cutoffHintHz = await lossyCodecCutoffHint(
            for: url,
            sampleRate: sampleRate,
            fallbackChannelCount: sourceChannelCount
        )

        var monoFIFO: [Float] = []
        monoFIFO.reserveCapacity(max(fftSize * 8, 262_144))
        var fifoStart = 0

        var mixScratch: [Float] = []
        var interleavedScratch: [Float] = []

        var fftInput = [Float](repeating: 0, count: fftSize)
        var splitReal = [Float](repeating: 0, count: halfSize)
        var splitImag = [Float](repeating: 0, count: halfSize)
        var interiorMagnitudes = [Float](repeating: 0, count: max(0, bins - 2))
        var framePowers = [Float](repeating: 0, count: bins)
        var processedFramePowers: [Float] = []
        processedFramePowers.reserveCapacity(max(1, desiredProcessedFrames) * bins)

        let vectorLength = vDSP_Length(fftSize)
        var frameIndex = 0
        var processedFrameCount = 0
        var totalMonoSamples = 0

        try splitReal.withUnsafeMutableBufferPointer { splitRealPtr in
            try splitImag.withUnsafeMutableBufferPointer { splitImagPtr in
                guard
                    let splitRealBase = splitRealPtr.baseAddress,
                    let splitImagBase = splitImagPtr.baseAddress
                else {
                    throw SpectrogramAnalyzerError.fftSetupFailed
                }

                var splitComplex = DSPSplitComplex(realp: splitRealBase, imagp: splitImagBase)

                while let sampleBuffer = output.copyNextSampleBuffer() {
                    defer { CMSampleBufferInvalidate(sampleBuffer) }

                    let sourceFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
                    guard sourceFrameCount > 0 else { continue }

                    if let details = streamDetails(from: sampleBuffer) {
                        if details.sampleRate > 0 {
                            sampleRate = details.sampleRate
                        }
                        sourceChannelCount = max(1, details.channelCount)
                    }

                    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                        throw SpectrogramAnalyzerError.cannotReadSampleBuffer
                    }

                    let availableBytes = CMBlockBufferGetDataLength(blockBuffer)
                    guard availableBytes > 0 else { continue }

                    let channelCount = max(1, sourceChannelCount)
                    let expectedBytes = sourceFrameCount * channelCount * MemoryLayout<Float>.size
                    let copyByteCount = min(availableBytes, expectedBytes)
                    guard copyByteCount > 0, copyByteCount % MemoryLayout<Float>.size == 0 else {
                        throw SpectrogramAnalyzerError.cannotReadSampleBuffer
                    }

                    let interleavedCount = copyByteCount / MemoryLayout<Float>.size
                    let decodedFrameCount = interleavedCount / channelCount
                    guard decodedFrameCount > 0 else { continue }

                    var lengthAtOffset = 0
                    var totalLength = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?
                    let pointerStatus = CMBlockBufferGetDataPointer(
                        blockBuffer,
                        atOffset: 0,
                        lengthAtOffsetOut: &lengthAtOffset,
                        totalLengthOut: &totalLength,
                        dataPointerOut: &dataPointer
                    )

                    if pointerStatus == kCMBlockBufferNoErr,
                       let dataPointer,
                       lengthAtOffset >= copyByteCount,
                       totalLength >= copyByteCount {
                        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: interleavedCount)
                        appendMonoFromInterleaved(
                            interleaved: floatPointer,
                            frameCount: decodedFrameCount,
                            channelCount: channelCount,
                            mixScratch: &mixScratch,
                            output: &monoFIFO
                        )
                    } else {
                        if interleavedScratch.count < interleavedCount {
                            interleavedScratch = [Float](repeating: 0, count: interleavedCount)
                        }

                        let status = interleavedScratch.withUnsafeMutableBytes { rawPtr in
                            CMBlockBufferCopyDataBytes(
                                blockBuffer,
                                atOffset: 0,
                                dataLength: copyByteCount,
                                destination: rawPtr.baseAddress!
                            )
                        }

                        guard status == kCMBlockBufferNoErr else {
                            throw SpectrogramAnalyzerError.cannotReadSampleBuffer
                        }

                        interleavedScratch.withUnsafeBufferPointer { pointer in
                            guard let base = pointer.baseAddress else { return }
                            appendMonoFromInterleaved(
                                interleaved: base,
                                frameCount: decodedFrameCount,
                                channelCount: channelCount,
                                mixScratch: &mixScratch,
                                output: &monoFIFO
                            )
                        }
                    }

                    totalMonoSamples += decodedFrameCount

                    while (monoFIFO.count - fifoStart) >= fftSize {
                        if frameIndex % frameStride == 0 {
                            monoFIFO.withUnsafeBufferPointer { monoPtr in
                                guard let monoBase = monoPtr.baseAddress else { return }
                                let frameBase = monoBase + fifoStart
                                computeFramePowers(
                                    frameBase: frameBase,
                                    fftInput: &fftInput,
                                    splitComplex: &splitComplex,
                                    fftSetup: fftSetup,
                                    log2n: log2n,
                                    window: window,
                                    vectorLength: vectorLength,
                                    bins: bins,
                                    edgeScale: edgeScale,
                                    interiorScale: interiorScale,
                                    interiorMagnitudes: &interiorMagnitudes,
                                    output: &framePowers
                                )
                            }

                            processedFramePowers.append(contentsOf: framePowers)
                            processedFrameCount += 1
                        }

                        frameIndex += 1
                        fifoStart += config.hopSize

                        if fifoStart > 65_536, fifoStart > monoFIFO.count / 2 {
                            monoFIFO.removeFirst(fifoStart)
                            fifoStart = 0
                        }
                    }

                    try throwIfCancelled()
                }

                let remaining = monoFIFO.count - fifoStart
                if remaining > 0 {
                    var tailFrame = [Float](repeating: 0, count: fftSize)
                    monoFIFO.withUnsafeBufferPointer { monoPtr in
                        tailFrame.withUnsafeMutableBufferPointer { tailPtr in
                            guard
                                let monoBase = monoPtr.baseAddress,
                                let tailBase = tailPtr.baseAddress
                            else {
                                return
                            }
                            tailBase.update(from: monoBase + fifoStart, count: min(remaining, fftSize))
                        }
                    }

                    if frameIndex % frameStride == 0 {
                        tailFrame.withUnsafeBufferPointer { tailPtr in
                            guard let tailBase = tailPtr.baseAddress else { return }
                            computeFramePowers(
                                frameBase: tailBase,
                                fftInput: &fftInput,
                                splitComplex: &splitComplex,
                                fftSetup: fftSetup,
                                log2n: log2n,
                                window: window,
                                vectorLength: vectorLength,
                                bins: bins,
                                edgeScale: edgeScale,
                                interiorScale: interiorScale,
                                interiorMagnitudes: &interiorMagnitudes,
                                output: &framePowers
                            )
                        }

                        processedFramePowers.append(contentsOf: framePowers)
                        processedFrameCount += 1
                    }
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? SpectrogramAnalyzerError.cannotReadSampleBuffer
        }

        guard processedFrameCount > 0 else {
            throw SpectrogramAnalyzerError.emptyAnalysis
        }

        let aggregated = aggregateProcessedFrames(
            framePowers: processedFramePowers,
            processedFrameCount: processedFrameCount,
            bins: bins,
            maxColumns: config.maxColumns
        )

        let averagePowers = averagedPowers(
            aggregatedPowerSums: aggregated.powerSums,
            columnFrameCounts: aggregated.frameCounts,
            columns: aggregated.columns,
            bins: bins
        )

        var aggregatedDecibels = [Float](repeating: config.minDecibels, count: aggregated.columns * bins)
        for index in 0..<(aggregated.columns * bins) {
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
                    columns: aggregated.columns,
                    bins: bins,
                    cutoffBin: cutoffBin,
                    floorDecibels: config.minDecibels
                )
            }
        }

        let finalDuration = durationSeconds > 0 ? durationSeconds : Double(totalMonoSamples) / max(1.0, sampleRate)

        return StreamingAnalysisResult(
            spectrum: AggregatedSpectrum(
                decibelsByColumn: aggregatedDecibels,
                columns: aggregated.columns,
                bins: bins
            ),
            sampleRate: sampleRate,
            sourceChannelCount: sourceChannelCount,
            sourceContainerFormat: sourceInfo.containerFormat,
            sourceCodec: sourceInfo.codec,
            sourceBitRate: sourceInfo.bitRate,
            duration: finalDuration
        )
    }

    private static func computeFramePowers(
        frameBase: UnsafePointer<Float>,
        fftInput: inout [Float],
        splitComplex: inout DSPSplitComplex,
        fftSetup: FFTSetup,
        log2n: vDSP_Length,
        window: [Float],
        vectorLength: vDSP_Length,
        bins: Int,
        edgeScale: Float,
        interiorScale: Float,
        interiorMagnitudes: inout [Float],
        output: inout [Float]
    ) {
        fftInput.withUnsafeMutableBufferPointer { fftInputPtr in
            window.withUnsafeBufferPointer { windowPtr in
                guard
                    let fftInputBase = fftInputPtr.baseAddress,
                    let windowBase = windowPtr.baseAddress
                else {
                    return
                }

                let splitRealBase = splitComplex.realp
                let splitImagBase = splitComplex.imagp

                fftInputBase.update(from: frameBase, count: Int(vectorLength))

                var frameMean: Float = 0
                vDSP_meanv(fftInputBase, 1, &frameMean, vectorLength)

                var negativeMean = -frameMean
                vDSP_vsadd(fftInputBase, 1, &negativeMean, fftInputBase, 1, vectorLength)
                vDSP_vmul(fftInputBase, 1, windowBase, 1, fftInputBase, 1, vectorLength)

                let halfCount = Int(vectorLength) / 2
                fftInputBase.withMemoryRebound(to: DSPComplex.self, capacity: halfCount) { complexBuffer in
                    vDSP_ctoz(complexBuffer, 2, &splitComplex, 1, vDSP_Length(halfCount))
                }

                vDSP_fft_zrip(
                    fftSetup,
                    &splitComplex,
                    1,
                    log2n,
                    FFTDirection(FFT_FORWARD)
                )

                if output.count != bins {
                    output = [Float](repeating: 0, count: bins)
                }

                output[0] = splitRealBase[0] * splitRealBase[0] * edgeScale

                let interiorCount = bins - 2
                if interiorCount > 0 {
                    var interiorComplex = DSPSplitComplex(
                        realp: splitRealBase + 1,
                        imagp: splitImagBase + 1
                    )

                    interiorMagnitudes.withUnsafeMutableBufferPointer { magnitudesPtr in
                        output.withUnsafeMutableBufferPointer { outputPtr in
                            guard
                                let magnitudesBase = magnitudesPtr.baseAddress,
                                let outputBase = outputPtr.baseAddress
                            else {
                                return
                            }

                            vDSP_zvmags(
                                &interiorComplex,
                                1,
                                magnitudesBase,
                                1,
                                vDSP_Length(interiorCount)
                            )

                            var scale = interiorScale
                            let destination = outputBase + 1
                            vDSP_vsmul(
                                magnitudesBase,
                                1,
                                &scale,
                                destination,
                                1,
                                vDSP_Length(interiorCount)
                            )
                        }
                    }
                }

                output[bins - 1] = splitImagBase[0] * splitImagBase[0] * edgeScale
            }
        }
    }

    private static func aggregateProcessedFrames(
        framePowers: [Float],
        processedFrameCount: Int,
        bins: Int,
        maxColumns: Int
    ) -> (powerSums: [Float], frameCounts: [Int], columns: Int) {
        let columns = max(1, min(maxColumns, processedFrameCount))
        let framesPerColumn = Double(processedFrameCount) / Double(columns)

        var aggregatedPowerSums = [Float](repeating: 0, count: columns * bins)
        var columnFrameCounts = [Int](repeating: 0, count: columns)

        framePowers.withUnsafeBufferPointer { framePtr in
            aggregatedPowerSums.withUnsafeMutableBufferPointer { aggregatePtr in
                guard
                    let frameBase = framePtr.baseAddress,
                    let aggregateBase = aggregatePtr.baseAddress
                else {
                    return
                }

                for processedOrdinal in 0..<processedFrameCount {
                    let columnIndex = min(columns - 1, Int(Double(processedOrdinal) / framesPerColumn))
                    let source = frameBase + (processedOrdinal * bins)
                    let destination = aggregateBase + (columnIndex * bins)
                    vDSP_vadd(
                        source,
                        1,
                        destination,
                        1,
                        destination,
                        1,
                        vDSP_Length(bins)
                    )
                    columnFrameCounts[columnIndex] += 1
                }
            }
        }

        return (aggregatedPowerSums, columnFrameCounts, columns)
    }

    private static func appendMonoFromInterleaved(
        interleaved: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        mixScratch: inout [Float],
        output: inout [Float]
    ) {
        guard frameCount > 0 else { return }

        if channelCount == 1 {
            output.append(contentsOf: UnsafeBufferPointer(start: interleaved, count: frameCount))
            return
        }

        if channelCount == 2 {
            if mixScratch.count < frameCount {
                mixScratch = [Float](repeating: 0, count: frameCount)
            }

            mixScratch.withUnsafeMutableBufferPointer { scratchPtr in
                guard let scratchBase = scratchPtr.baseAddress else { return }

                vDSP_vadd(interleaved, 2, interleaved + 1, 2, scratchBase, 1, vDSP_Length(frameCount))
                var scale: Float = 0.5
                vDSP_vsmul(scratchBase, 1, &scale, scratchBase, 1, vDSP_Length(frameCount))
            }

            output.append(contentsOf: mixScratch.prefix(frameCount))
            return
        }

        for frame in 0..<frameCount {
            let base = frame * channelCount
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[base + channel]
            }
            output.append(sum / Float(channelCount))
        }
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

    private static func trackAudioDetails(_ track: AVAssetTrack) async -> (sampleRate: Double, channelCount: Int, formatID: UInt32?) {
        guard let formatDescriptions = try? await track.load(.formatDescriptions),
              let firstDescription = formatDescriptions.first
        else {
            return (0, 0, nil)
        }

        let cmFormat = firstDescription as CMFormatDescription
        guard CMFormatDescriptionGetMediaType(cmFormat) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat)?.pointee
        else {
            return (0, 0, nil)
        }

        return (
            sampleRate: max(0, asbd.mSampleRate),
            channelCount: max(0, Int(asbd.mChannelsPerFrame)),
            formatID: asbd.mFormatID
        )
    }

    private static func sourceAudioInfo(
        for url: URL,
        track: AVAssetTrack,
        formatID: UInt32?,
        durationSeconds: Double
    ) async -> (containerFormat: String, codec: String, bitRate: Double?) {
        let container = containerName(for: url)
        let codec = codecName(for: formatID)
        let trackBitRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)

        if trackBitRate > 0 {
            return (container, codec, trackBitRate)
        }

        guard durationSeconds > 0 else {
            return (container, codec, nil)
        }

        if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, fileSize > 0 {
            let derivedBitRate = (Double(fileSize) * 8.0) / durationSeconds
            if derivedBitRate.isFinite, derivedBitRate > 0 {
                return (container, codec, derivedBitRate)
            }
        }

        return (container, codec, nil)
    }

    private static func containerName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "aac":
            return "AAC"
        case "aif", "aiff":
            return "AIFF"
        case "amr":
            return "AMR"
        case "flac":
            return "FLAC"
        case "m4a":
            return "M4A"
        case "mp3":
            return "MP3"
        case "ogg":
            return "OGG"
        case "opus":
            return "Opus"
        case "wav":
            return "WAV"
        default:
            let ext = url.pathExtension
            return ext.isEmpty ? "Unknown" : ext.uppercased()
        }
    }

    private static func codecName(for formatID: UInt32?) -> String {
        guard let formatID else {
            return "Unknown codec"
        }

        switch formatID {
        case kAudioFormatLinearPCM:
            return "Linear PCM"
        case kAudioFormatMPEGLayer3:
            return "MPEG Audio Layer III"
        case kAudioFormatMPEG4AAC:
            return "AAC"
        case kAudioFormatMPEG4AAC_HE:
            return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2:
            return "HE-AAC v2"
        case kAudioFormatMPEG4AAC_LD:
            return "AAC-LD"
        case kAudioFormatMPEG4AAC_ELD:
            return "AAC-ELD"
        case kAudioFormatAppleLossless:
            return "Apple Lossless"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatOpus:
            return "Opus"
        default:
            return fourCCString(formatID)
        }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let isPrintableASCII = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        if isPrintableASCII, let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(format: "0x%08X", value)
    }

    private static func streamDetails(from sampleBuffer: CMSampleBuffer) -> (sampleRate: Double, channelCount: Int)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        guard CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio else {
            return nil
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        return (
            sampleRate: max(1.0, asbd.pointee.mSampleRate),
            channelCount: max(1, Int(asbd.pointee.mChannelsPerFrame))
        )
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

    private static func finiteSeconds(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private static func throwIfCancelled() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }
}
