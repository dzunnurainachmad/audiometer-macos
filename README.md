# AudioMeter

A lightweight macOS system-audio metering app built with SwiftUI. It captures system audio and displays a smooth, scrolling stereo waveform (DAW/oscilloscope style) alongside BS.1770-4 LUFS loudness meters.

## Features

- **Scrolling stereo waveform** — DAW-style min/max peak rendering, smooth 60fps scroll.
- **LUFS loudness metering** — BS.1770-4 K-weighting, Momentary (400 ms) + Short-Term (3 s) with peak hold.
- **Lightweight** — ~13% CPU (Release build). Audio processing is near-free; the cost is purely GPU rendering.
- **Floating always-on-top window** so it stays visible over other apps.

## Tech

- **SwiftUI** on macOS 14.2+
- **CATapDescription + AudioHardwareCreateProcessTap + AVAudioEngine** for pure-audio system capture (no video pipeline)
- **Metal** fragment shader rendering a ring buffer for the waveform (GPU-accelerated, DAW-style min/max binning)
- **Accelerate / vDSP** — SIMD biquad K-weighting filter and min/max peak extraction

## Build & Run

> ⚠️ Always run the **Release** build for low CPU usage. Debug builds are many times heavier because Swift numeric code runs unoptimized.

From the terminal:

```bash
xcodebuild -project AudioMeter.xcodeproj -scheme AudioMeter -configuration Release -derivedDataPath build_release build
```

Then launch `build_release/Build/Products/Release/AudioMeter.app` (or copy it to `/Applications`).

Or in Xcode: **Product → Scheme → Edit Scheme → Run → Build Configuration → Release**, then Run.

## Permissions

The app requires audio capture permission to tap system audio. macOS may show a "Currently Sharing" indicator while capturing — this is by design for any global system-audio capture.

## License

MIT
