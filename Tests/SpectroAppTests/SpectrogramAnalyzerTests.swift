import AVFoundation
import Foundation
import XCTest
@testable import SpectroApp

final class SpectrogramAnalyzerTests: XCTestCase {
    private static let expectedEspressifFiles: [String] = [
        "ff-16b-1c-11025hz.mp3",
        "ff-16b-1c-12000hz.mp3",
        "ff-16b-1c-16000hz.mp3",
        "ff-16b-1c-22050hz.mp3",
        "ff-16b-1c-24000hz.mp3",
        "ff-16b-1c-32000hz.mp3",
        "ff-16b-1c-44100hz.aac",
        "ff-16b-1c-44100hz.flac",
        "ff-16b-1c-44100hz.m4a",
        "ff-16b-1c-44100hz.mp3",
        "ff-16b-1c-44100hz.ogg",
        "ff-16b-1c-44100hz.opus",
        "ff-16b-1c-44100hz.wav",
        "ff-16b-1c-8000hz.amr",
        "ff-16b-1c-8000hz.mp3",
        "ff-16b-2c-11025hz.mp3",
        "ff-16b-2c-12000hz.mp3",
        "ff-16b-2c-16000hz.mp3",
        "ff-16b-2c-22050hz.mp3",
        "ff-16b-2c-24000hz.mp3",
        "ff-16b-2c-32000hz.mp3",
        "ff-16b-2c-44100hz.aac",
        "ff-16b-2c-44100hz.flac",
        "ff-16b-2c-44100hz.m4a",
        "ff-16b-2c-44100hz.mp3",
        "ff-16b-2c-44100hz.ogg",
        "ff-16b-2c-44100hz.opus",
        "ff-16b-2c-44100hz.wav",
        "ff-16b-2c-8000hz.mp3",
        "gs-16b-1c-44100hz.aac",
        "gs-16b-1c-44100hz.flac",
        "gs-16b-1c-44100hz.m4a",
        "gs-16b-1c-44100hz.mp3",
        "gs-16b-1c-44100hz.ogg",
        "gs-16b-1c-44100hz.opus",
        "gs-16b-1c-44100hz.wav",
        "gs-16b-1c-8000hz.amr",
        "gs-16b-2c-44100hz.aac",
        "gs-16b-2c-44100hz.flac",
        "gs-16b-2c-44100hz.m4a",
        "gs-16b-2c-44100hz.mp3",
        "gs-16b-2c-44100hz.ogg",
        "gs-16b-2c-44100hz.opus",
        "gs-16b-2c-44100hz.wav"
    ]

    private static let coreAnalysisFixtures: [String] = [
        "ff-16b-1c-44100hz.aac",
        "ff-16b-1c-44100hz.flac",
        "ff-16b-1c-44100hz.m4a",
        "ff-16b-1c-44100hz.mp3",
        "ff-16b-1c-44100hz.wav",
        "ff-16b-2c-44100hz.aac",
        "ff-16b-2c-44100hz.flac",
        "ff-16b-2c-44100hz.m4a",
        "ff-16b-2c-44100hz.mp3",
        "ff-16b-2c-44100hz.wav",
        "gs-16b-1c-44100hz.aac",
        "gs-16b-1c-44100hz.flac",
        "gs-16b-1c-44100hz.m4a",
        "gs-16b-1c-44100hz.mp3",
        "gs-16b-1c-44100hz.wav",
        "gs-16b-2c-44100hz.aac",
        "gs-16b-2c-44100hz.flac",
        "gs-16b-2c-44100hz.m4a",
        "gs-16b-2c-44100hz.mp3",
        "gs-16b-2c-44100hz.wav"
    ]

    func testAnalyzeGeneratedWAV() async throws {
        let url = try makeTemporarySineWAV(sampleRate: 44_100, duration: 1.2, frequency: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await SpectrogramAnalyzer.analyze(url: url)

        XCTAssertGreaterThan(result.duration, 1.0)
        XCTAssertEqual(result.sampleRate, 44_100, accuracy: 1.0)
        XCTAssertEqual(result.sourceChannelCount, 1)
        XCTAssertEqual(result.fftSize, 2048)
        XCTAssertEqual(result.hopSize, 512)
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
        XCTAssertEqual(result.maxFrequency, result.sampleRate / 2.0, accuracy: 0.5)
    }

    func testEspressifFixtureSetIsCompleteAndNonEmpty() throws {
        let directory = espressifFixtureAudioDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Espressif fixture directory not found: \(directory.path)")
        }

        let files = try fixtureFileNames(in: directory)
        XCTAssertEqual(Set(files), Set(Self.expectedEspressifFiles))

        for fileName in Self.expectedEspressifFiles {
            let url = directory.appendingPathComponent(fileName)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? NSNumber
            XCTAssertGreaterThan(size?.intValue ?? 0, 0, "Empty fixture file: \(fileName)")
        }
    }

    func testAnalyzeEspressifCoreFormats() async throws {
        let directory = espressifFixtureAudioDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Espressif fixture directory not found: \(directory.path)")
        }

        for fileName in Self.coreAnalysisFixtures {
            try await assertFixtureCanAnalyze(fileName, in: directory)
        }
    }

    private func assertFixtureCanAnalyze(_ fileName: String, in directory: URL) async throws {
        let url = directory.appendingPathComponent(fileName)
        let result = try await SpectrogramAnalyzer.analyze(url: url)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertGreaterThan(result.sampleRate, 0)
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
    }

    private var fixtureAudioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
    }

    private var espressifFixtureAudioDirectory: URL {
        fixtureAudioDirectory.appendingPathComponent("Espressif", isDirectory: true)
    }

    private func fixtureFileNames(in directory: URL) throws -> [String] {
        let allowedExtensions: Set<String> = ["aac", "amr", "flac", "m4a", "mp3", "ogg", "opus", "wav"]
        let names = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
        .map(\.lastPathComponent)
        .sorted()
        return names
    }

    private func makeTemporarySineWAV(sampleRate: Double, duration: Double, frequency: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "SpectroTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }

        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SpectroTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No channel data in PCM buffer"])
        }

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            channel[frame] = Float(sin(2.0 * Double.pi * frequency * t) * 0.5)
        }

        try file.write(from: buffer)
        return url
    }
}
