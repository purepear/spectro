import Foundation
import SwiftUI

@MainActor
final class SpectroViewModel: ObservableObject {
    struct ErrorPresentation {
        let title: String
        let message: String
        let technicalDetails: String?
    }

    enum ViewState {
        case idle
        case loading(fileName: String)
        case loaded(SpectrogramResult)
        case failed(ErrorPresentation)
    }

    @Published var isImporterPresented = false
    @Published var isDropTargeted = false
    @Published private(set) var state: ViewState = .idle

    private var analysisTask: Task<Void, Never>?

    func handleFileImporter(result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            load(url: url)
        case let .failure(error):
            state = .failed(makeErrorPresentation(from: error, title: "Failed to open file"))
        }
    }

    func handleDropped(urls: [URL]) -> Bool {
        guard let url = urls.first else {
            return false
        }
        load(url: url)
        return true
    }

    func load(url: URL) {
        analysisTask?.cancel()
        let fileURL = normalizedFileURL(from: url)
        let needsSecurityAccess = fileURL.startAccessingSecurityScopedResource()

        state = .loading(fileName: fileURL.lastPathComponent)

        analysisTask = Task(priority: .userInitiated) { [weak self] in
            defer {
                if needsSecurityAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let self else { return }

            do {
                let result = try await SpectrogramAnalyzer.analyze(url: fileURL)
                guard !Task.isCancelled else { return }
                self.state = .loaded(result)
            } catch is CancellationError {
                return
            } catch {
                self.state = .failed(makeErrorPresentation(from: error, title: "Could not analyze this file"))
            }
        }
    }

    private func normalizedFileURL(from url: URL) -> URL {
        if url.isFileURL {
            return url
        }
        if let decoded = URL(string: url.absoluteString.removingPercentEncoding ?? url.absoluteString), decoded.isFileURL {
            return decoded
        }
        return url
    }

    private func makeErrorPresentation(from error: Error, title: String) -> ErrorPresentation {
        let friendlyMessage = friendlyMessage(for: error)
        let details = technicalErrorDetails(error)
        return ErrorPresentation(title: title, message: friendlyMessage, technicalDetails: details)
    }

    private func friendlyMessage(for error: Error) -> String {
        if let analyzerError = error as? SpectrogramAnalyzerError {
            switch analyzerError {
            case .noAudioTrack:
                return "The selected file does not contain an audio track."
            case .emptyAnalysis:
                return "The file appears to contain no readable audio samples."
            case .cannotCreateAssetReader, .cannotAddReaderOutput, .cannotReadSampleBuffer:
                return "This audio file could not be decoded with the native macOS audio pipeline."
            case .fftSetupFailed, .renderingFailed:
                return "Analysis failed during spectrogram processing."
            }
        }

        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        return "An unexpected error occurred."
    }

    private func technicalErrorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []

        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            parts.append(description)
        } else {
            parts.append(nsError.localizedDescription)
        }

        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            parts.append("(\(nsError.domain) code \(nsError.code))")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Underlying: \(underlying.domain) code \(underlying.code)")
        }

        return parts.joined(separator: " ")
    }
}
