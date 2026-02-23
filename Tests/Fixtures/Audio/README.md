Analyzer fixtures live under this directory.

- `Espressif/` contains samples downloaded from:
  - `https://docs.espressif.com/projects/esp-adf/en/latest/design-guide/audio-samples.html`
  - Attribution/license details: `THIRD_PARTY_NOTICES.md`

Test behavior:

- `testEspressifFixtureSetIsCompleteAndNonEmpty` checks that all expected files exist and are non-empty.
- `testAnalyzeEspressifCoreFormats` runs full spectrogram analysis on a core subset of AAC/FLAC/M4A/MP3/WAV fixtures.
