# Spectro

Native macOS spectrogram app prototype built with Apple frameworks only.

<img width="1224" height="769" alt="image" src="https://github.com/user-attachments/assets/46a5aedd-5f99-401d-bd16-761c3eca0f3b" />


## Stack

- `SwiftUI` for UI
- `AVFoundation` (`AVAssetReader`) for streaming decode to PCM
- `Accelerate/vDSP` for windowing + FFT
- `CoreGraphics` for static spectrogram image rendering

No third-party libraries are used.

## v1 behavior

- macOS target: **15+**
- Open file with menu/button (`Cmd+O`) or drag/drop a file onto the window
- Decodes supported audio formats (for example MP3, FLAC, AAC, WAV) through macOS native codecs
- Mixes all channels to mono
- Uses fixed analysis settings:
  - FFT size: `2048`
  - Hop size: `512`
  - Hann window
  - Linear-frequency display
  - Absolute dBFS power scale (`0 dB` equals full-scale sine reference)
  - Adaptive frame subsampling for faster analysis on long files
  - Accelerate-optimized FFT + rendering path for faster analysis
  - One-pass AVAssetReader stream analysis (no full PCM staging)
  - Static image output

## Run

1. Open `Package.swift` in Xcode.
2. Build and run the `Spectro` executable target.

Or via CLI:

```bash
swift run Spectro
```

## Build As macOS App (`.app`)

This repo now includes a generated Xcode project:

- `Spectro.xcodeproj`

Open it in Xcode and build/run the `Spectro` scheme. The app bundle will be produced as `Spectro.app` in Xcode's build products.

Project generation source is:

- `project.yml`

Regenerate after project-structure changes:

```bash
xcodegen generate
```

## Testing

```bash
swift test
```

- Renderer tests run out of the box.
- Analyzer tests validate the bundled Espressif fixture set in `Tests/Fixtures/Audio/Espressif`.

## Important local prerequisite

On this machine, Swift/Xcode CLI commands are currently blocked until the Apple SDK license is accepted:

```bash
sudo xcodebuild -license
```

After accepting, `swift run` and command-line build checks should work.

## Notes

- Supported formats depend on codecs available in the running macOS version.
- Very long files may take time because v1 performs full-file analysis and static image generation.
- v1 intentionally does not include interactive zoom/pan or user-adjustable FFT settings.
- See `docs/AppStoreReleaseChecklist.md` for release hardening and App Store prep.
