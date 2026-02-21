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
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 8)

            if viewModel.isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 0)
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Spectro")
                    .font(.headline)
            }
        }
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

        case let .failed(error):
            VStack(spacing: 10) {
                Text(error.title)
                    .font(.headline)
                Text(error.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let details = error.technicalDetails, !details.isEmpty {
                    DisclosureGroup("Technical details") {
                        ScrollView {
                            Text(details)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    .frame(maxWidth: 760)
                }

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
