import Foundation
import SwiftUI

@MainActor
final class SpectroViewModel: ObservableObject {
    enum ViewState {
        case idle
        case loading(fileName: String)
        case loaded(SpectrogramResult)
        case failed(message: String)
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
            state = .failed(message: "Failed to open file: \(userFacingErrorMessage(error))")
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
                self.state = .failed(message: userFacingErrorMessage(error))
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

    private func userFacingErrorMessage(_ error: Error) -> String {
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
