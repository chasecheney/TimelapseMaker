# Timelapse Maker (macOS)

A native SwiftUI app that does what `make_timelapse.command` does, without ffmpeg:
pick a folder of images → set frame rate, crop, and output size → get an MP4.

## Build

1. Open `TimelapseMaker.xcodeproj` in Xcode 16 or newer (macOS 14+ target).
2. In the target's *Signing & Capabilities* tab pick your Team (or leave "Sign to Run Locally").
3. Press **Run** (⌘R). To keep a copy, use *Product ▸ Archive* or drag the built
   app out of *Product ▸ Show Build Folder in Finder*.

## Use

* **Choose Folder…** (⌘O) or drop a folder on the window. Every JPG/PNG/HEIC/TIFF in it
  (subfolders included) is sorted by filename, one image per frame — same as the script.
* **Range** trims to a start/end frame number (START/END in the script).
* **Frame rate** 1–60 fps; the estimated video length updates live.
* **Crop**: drag on the preview to draw a rectangle, drag inside to move it, drag a
  corner to resize. Numeric X/Y/W/H fields and aspect presets are in the sidebar.
* **Output size** defaults to the crop size; edit width/height (aspect locked by default)
  or click 100/75/50/25 %.
* **Stabilize** (optional): locks every frame to an anchor frame (the first frame, or the
  preview frame you pick). Each frame's X/Y offset from the anchor is measured with Vision's
  image registration and undone; frames that don't match the anchor above the sensitivity
  threshold count as a scene change and become the new anchor. Combine with a crop to hide
  the shifting edges.
* **Label overlay** (optional): none, the filename, or the timestamp parsed from
  Timesnapper names like `2026-07-22--14-05-31 UTC.jpg`, shown in PT/ET/UTC/local.
  It is burned into the picture (the script's `burn` mode).
* **Encoding**: H.264 or HEVC via Apple's hardware encoder; the quality slider sets
  the target bitrate.
* **Make Video…** (⌘↩) asks where to save and renders with a progress bar and Cancel.

## Differences from the script

* No soft (toggleable) subtitle track — AVFoundation can't author one cleanly; use the
  burned-in label instead.
* Bitrate-based quality instead of x264 CRF/presets.
* Images are decoded with ImageIO, so EXIF orientation is honored.
