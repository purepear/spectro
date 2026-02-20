import Accelerate
import AVFoundation
import CoreMedia
import Foundation

enum DecoderBackend: String {
    case avAudioFile = "AVAudioFile"
    case avAssetReader = "AVAssetReader"
}

struct DecodedAudio {
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let backend: DecoderBackend

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

enum AudioDecoderError: LocalizedError {
    case noChannels
    case emptyAudio
    case bufferAllocationFailed
    case noAudioTrack
    case cannotCreateAssetReader
    case cannotAddReaderOutput
    case cannotReadSampleBuffer
    case decodeFailed(primaryDomain: String, primaryCode: Int, fallbackDomain: String, fallbackCode: Int)

    var errorDescription: String? {
        switch self {
        case .noChannels:
            return "This file has no readable audio channels."
        case .emptyAudio:
            return "This file appears to contain no audio samples."
        case .bufferAllocationFailed:
            return "Could not allocate decoding buffer."
        case .noAudioTrack:
            return "No audio track was found in this file."
        case .cannotCreateAssetReader:
            return "Could not create AVAssetReader for this file."
        case .cannotAddReaderOutput:
            return "Could not configure AVAssetReader output."
        case .cannotReadSampleBuffer:
            return "Could not read audio sample buffers from this file."
        case let .decodeFailed(primaryDomain, primaryCode, fallbackDomain, fallbackCode):
            return "Native decode failed (AVAudioFile: \(primaryDomain) \(primaryCode), AVAssetReader: \(fallbackDomain) \(fallbackCode))."
        }
    }
}

enum AudioDecoder {
    static func decodeMonoSamplesAVAudioFileOnly(from url: URL) throws -> DecodedAudio {
        try decodeUsingAVAudioFile(from: url)
    }

    static func decodeMonoSamples(from url: URL) async throws -> DecodedAudio {
        do {
            return try decodeMonoSamplesAVAudioFileOnly(from: url)
        } catch {
            let primaryNSError = error as NSError

            do {
                return try await decodeUsingAVAssetReader(from: url)
            } catch {
                let fallbackNSError = error as NSError
                throw AudioDecoderError.decodeFailed(
                    primaryDomain: primaryNSError.domain,
                    primaryCode: primaryNSError.code,
                    fallbackDomain: fallbackNSError.domain,
                    fallbackCode: fallbackNSError.code
                )
            }
        }
    }

    private static func decodeUsingAVAudioFile(from url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            throw AudioDecoderError.noChannels
        }

        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(max(Int(file.length), Int(chunkSize)))
        var mixScratch: [Float] = [Float](repeating: 0, count: Int(chunkSize))

        while true {
            try file.read(into: buffer, frameCount: chunkSize)

            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 {
                break
            }

            guard let channels = buffer.floatChannelData else {
                throw AudioDecoderError.emptyAudio
            }

            if channelCount == 1 {
                monoSamples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frameCount))
                continue
            }

            if mixScratch.count < frameCount {
                mixScratch = [Float](repeating: 0, count: frameCount)
            }

            mixScratch.withUnsafeMutableBufferPointer { scratchPtr in
                guard let scratchBase = scratchPtr.baseAddress else { return }

                scratchBase.update(from: channels[0], count: frameCount)
                for channelIndex in 1..<channelCount {
                    vDSP_vadd(scratchBase, 1, channels[channelIndex], 1, scratchBase, 1, vDSP_Length(frameCount))
                }

                var scale: Float = 1.0 / Float(channelCount)
                vDSP_vsmul(scratchBase, 1, &scale, scratchBase, 1, vDSP_Length(frameCount))
            }

            monoSamples.append(contentsOf: mixScratch.prefix(frameCount))
        }

        guard !monoSamples.isEmpty else {
            throw AudioDecoderError.emptyAudio
        }

        return DecodedAudio(
            samples: monoSamples,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            backend: .avAudioFile
        )
    }

    private static func decodeUsingAVAssetReader(from url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioDecoderError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecoderError.cannotCreateAssetReader
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
            throw AudioDecoderError.cannotAddReaderOutput
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? AudioDecoderError.cannotCreateAssetReader
        }

        var resolvedSampleRate: Double = 0
        var resolvedChannelCount = 0

        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(1 << 18)

        var didReadAnyBuffer = false
        while let sampleBuffer = output.copyNextSampleBuffer() {
            didReadAnyBuffer = true
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            let sourceFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sourceFrameCount > 0 else { continue }

            if let details = streamDetails(from: sampleBuffer) {
                if resolvedSampleRate <= 0 {
                    resolvedSampleRate = details.sampleRate
                }
                if resolvedChannelCount <= 0 {
                    resolvedChannelCount = details.channelCount
                }
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw AudioDecoderError.cannotReadSampleBuffer
            }

            let availableBytes = CMBlockBufferGetDataLength(blockBuffer)
            guard availableBytes > 0 else { continue }

            if resolvedChannelCount <= 0 {
                let derivedChannels = availableBytes / max(1, sourceFrameCount * MemoryLayout<Float>.size)
                resolvedChannelCount = max(1, derivedChannels)
            }

            let channelCount = max(1, resolvedChannelCount)
            let expectedBytes = sourceFrameCount * channelCount * MemoryLayout<Float>.size
            let copyByteCount = min(availableBytes, expectedBytes)
            guard copyByteCount > 0, copyByteCount % MemoryLayout<Float>.size == 0 else {
                throw AudioDecoderError.cannotReadSampleBuffer
            }

            let interleavedCount = copyByteCount / MemoryLayout<Float>.size
            var interleaved = [Float](repeating: 0, count: interleavedCount)

            let status = interleaved.withUnsafeMutableBytes { rawPtr in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: copyByteCount,
                    destination: rawPtr.baseAddress!
                )
            }

            guard status == kCMBlockBufferNoErr else {
                throw AudioDecoderError.cannotReadSampleBuffer
            }

            let decodedFrameCount = interleavedCount / channelCount
            guard decodedFrameCount > 0 else { continue }

            if channelCount == 1 {
                monoSamples.append(contentsOf: interleaved.prefix(decodedFrameCount))
            } else {
                var sampleIndex = 0
                for _ in 0..<decodedFrameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += interleaved[sampleIndex + channel]
                    }
                    monoSamples.append(sum / Float(channelCount))
                    sampleIndex += channelCount
                }
            }
        }

        guard didReadAnyBuffer else {
            throw AudioDecoderError.cannotReadSampleBuffer
        }

        if reader.status == .failed {
            throw reader.error ?? AudioDecoderError.cannotReadSampleBuffer
        }

        guard !monoSamples.isEmpty else {
            throw AudioDecoderError.emptyAudio
        }

        let sampleRate = resolvedSampleRate > 0 ? resolvedSampleRate : 44_100
        let channelCount = max(1, resolvedChannelCount)

        return DecodedAudio(
            samples: monoSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            backend: .avAssetReader
        )
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
}
