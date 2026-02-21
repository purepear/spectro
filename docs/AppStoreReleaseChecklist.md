# Spectro App Store Release Checklist

## Product and Build Settings

- Use an explicit bundle identifier and release versioning (`CFBundleShortVersionString`, `CFBundleVersion`).
- Set deployment target to macOS 15+.
- Ensure Release configuration uses whole-module optimization (`-O`).

## Signing and Distribution

- Use a valid Apple Distribution certificate.
- Enable automatic signing for release archives.
- Archive and validate with Xcode Organizer before upload.

## App Sandbox and File Access

- Enable App Sandbox.
- Enable `User Selected File` access as `Read Only`.
- You can start from `Config/SpectroApp.entitlements` and assign it to the app target in Xcode.
- Verify file open and drag-drop work from Desktop, Downloads, external drives, and iCloud Drive.
- Confirm security-scoped file access survives long analyses.

## Privacy and Metadata

- Keep app language/metadata in English.
- Provide accurate category, keywords, and support URL.
- Add privacy manifest entries only if required by used APIs.

## Stability and Quality

- Run `swift build` for release branch.
- Run `swift test` locally (outside restricted sandbox) including optional fixture tests.
- Test decode and analysis on at least:
  - WAV
  - AAC (`.m4a`)
  - MP3
  - FLAC
- Verify spectrogram axis labels and dB legend mapping on known reference files.

## Performance and UX

- Benchmark short, medium, and long files on target hardware.
- Confirm app remains responsive during analysis and cancellation.
- Verify dark appearance, axis readability, and no clipping on small windows.

## Submission

- Upload build to App Store Connect.
- Add release notes and screenshots.
- Pass TestFlight sanity checks before App Review submission.
