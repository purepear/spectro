import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SpectroViewModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 16) {
                content
            }
            .padding(20)

            if viewModel.isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: $viewModel.isImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: viewModel.handleFileImporter
        )
        .dropDestination(for: URL.self, action: { urls, _ in
            viewModel.handleDropped(urls: urls)
        }, isTargeted: { isTargeted in
            viewModel.isDropTargeted = isTargeted
        })
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            placeholderView

        case let .loading(fileName):
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Analyzing \(fileName)…")
                    .font(.headline)
                Text("Using native AVFoundation + Accelerate pipeline")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            VStack(spacing: 10) {
                Text("Could not analyze this file")
                    .font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Choose Another File") {
                    viewModel.isImporterPresented = true
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(result):
            SpectrogramView(result: result)
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.secondary)

            Text("Drop an audio file here")
                .font(.title3)

            Text("or choose Open Audio File… to load MP3, FLAC, AAC, WAV, and other formats supported by macOS")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)

            Button("Open Audio File...") {
                viewModel.isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
