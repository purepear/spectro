import AVFoundation
import Foundation
import XCTest
@testable import SpectroApp

final class SpectrogramAnalyzerTests: XCTestCase {
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

    func testAnalyzeFixtureWAVIfPresent() async throws {
        try await assertFixtureCanAnalyze("sample.wav")
    }

    func testAnalyzeFixtureAACIfPresent() async throws {
        try await assertFixtureCanAnalyze("sample.m4a")
    }

    func testAnalyzeFixtureMP3IfPresent() async throws {
        try await assertFixtureCanAnalyze("sample.mp3")
    }

    func testAnalyzeFixtureFLACIfPresent() async throws {
        try await assertFixtureCanAnalyze("sample.flac")
    }

    private func assertFixtureCanAnalyze(_ fileName: String) async throws {
        let url = fixtureAudioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Fixture not found: \(url.path)")
        }

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
