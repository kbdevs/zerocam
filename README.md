# ZeroCam

ZeroCam is a tiny native iPhone camera app built around one idea: capture the cleanest, least-processed image possible with a dead-simple camera UI.

It is inspired by the spirit of Halide's Process Zero and pro camera apps like Moment, but the app itself is intentionally minimal. Open it, frame the shot, adjust focus/zoom/exposure if needed, and shoot.

## What It Does

- Full-screen live viewfinder
- RAW-first capture pipeline
- Bayer RAW when the active camera supports it
- Apple ProRAW fallback when Bayer RAW is unavailable
- Minimal RAW development into a companion JPEG
- Saves the processed JPEG and RAW original to Photos
- Tap to focus and expose
- Exposure bias control
- Native-feeling zoom control with lens sticky points
- Portrait and landscape camera controls
- Last-photo thumbnail with a simple viewer
- Pinch, pan, double-tap zoom, and swipe-down dismiss in the viewer

## What "Zero" Means Here

ZeroCam tries to avoid the usual computational-photo look:

- No fake preview tint
- No hardcoded warmer/brighter/greener display correction
- No added sharpening in the RAW render
- No added noise reduction in the RAW render
- No lens correction in the RAW render
- No local tone mapping in the RAW render

The JPEG preview is rendered from the captured RAW data using Core Image's RAW pipeline with the enhancement knobs kept as low as practical. The RAW file is saved alongside it so the original capture remains available.

## Current Scope

This is an early, focused prototype. It is not trying to be a full pro camera app yet.

There are no filters, presets, albums, histograms, grids, manual shutter speed, ISO controls, focus peaking, or RAW editing tools. Those can come later. The first version is just the camera.

## Requirements

- iPhone with RAW-capable rear camera
- iOS 17 or newer
- Xcode 26 or newer
- A signing profile that can install to your device

The app is being tested on an iPhone 15 Pro.

## Build

Open the project in Xcode:

```sh
open ProcessZeroCamera.xcodeproj
```

Then select the `ProcessZeroCamera` scheme and run on a physical iPhone.

Command-line simulator build:

```sh
xcodebuild \
  -project ProcessZeroCamera.xcodeproj \
  -scheme ProcessZeroCamera \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## App Icon

The icon is intentionally simple: a flat camera glyph with no gradients, glass effects, or decorative background artwork.

Source:

```text
ProcessZeroCamera/AppIconSource/flat-camera.svg
```

Rendered asset:

```text
ProcessZeroCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Notes

The app uses AVFoundation directly for camera capture and Photos for saving. RAW availability differs by device, lens, zoom position, and active capture device, so ZeroCam attempts the cleanest supported RAW path and falls back when needed rather than failing the shot.

## License

No license has been added yet.
