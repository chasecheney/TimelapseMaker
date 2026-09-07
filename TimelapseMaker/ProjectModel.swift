import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ProjectModel: ObservableObject {
    // Source
    @Published var sourceFolder: URL?
    @Published var frames: [URL] = []
    @Published var sourceSize: CGSize = .zero
    @Published var isScanning = false

    // Range (1-based, inclusive, like START/END in the script)
    @Published var startFrame = 1
    @Published var endFrame = 1

    // Timing
    @Published var fps: Double = 15

    // Crop (source pixel coordinates, top-left origin). nil = whole image.
    @Published var crop: CGRect? = nil {
        didSet { if !suppressCropSync { syncOutputSizeToCrop() } }
    }
    private var suppressCropSync = false
    @Published var cropAspectPreset: CropAspect = .free {
        didSet { if let r = cropAspectPreset.ratio { setCropAspect(r) } }
    }

    // Output size
    @Published var outputWidth: Int = 0
    @Published var outputHeight: Int = 0
    @Published var lockAspect = true

    // Encoding
    @Published var codec: VideoCodec = .h264
    @Published var quality: Double = 0.6

    // Stabilization
    @Published var stabilizeEnabled = false
    @Published var stabilizeSensitivity: Double = 0.5
    @Published var stabilizeRecenter = true
    /// Absolute index into `frames` of the anchor; nil = first frame of the range.
    @Published var anchorFrame: Int? = nil
    @Published var stabilizeSummary: String?

    var effectiveAnchorFrame: Int {
        let first = max(0, startFrame - 1)
        let last = max(first, min(endFrame, frames.count) - 1)
        guard let a = anchorFrame else { return first }
        return min(max(a, first), last)
    }

    func useCurrentPreviewAsAnchor() { anchorFrame = previewIndex }

    // Label overlay
    @Published var labelMode: LabelMode = .none
    @Published var labelTimeZone: LabelTimeZone = .pacific
    @Published var labelFontSize: Double = 28

    // Preview
    @Published var previewIndex = 0
    @Published var previewImage: CGImage?
    private var previewTask: Task<Void, Never>?

    // Rendering state
    @Published var isRendering = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var lastOutput: URL?
    private var renderer: TimelapseRenderer?

    // MARK: - Derived values

    var totalFrames: Int { frames.count }

    var selectedFrames: [URL] {
        guard !frames.isEmpty else { return [] }
        let s = max(1, min(startFrame, frames.count))
        let e = max(s, min(endFrame, frames.count))
        return Array(frames[(s - 1)..<e])
    }

    var selectedCount: Int { selectedFrames.count }

    var effectiveCrop: CGRect {
        crop ?? CGRect(origin: .zero, size: sourceSize)
    }

    var cropAspect: Double {
        let c = effectiveCrop
        return c.height > 0 ? c.width / c.height : 16.0 / 9.0
    }

    var estimatedDuration: TimeInterval {
        fps > 0 ? Double(selectedCount) / fps : 0
    }

    var estimatedDurationText: String {
        let secs = Int(estimatedDuration.rounded())
        return String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }

    var canRender: Bool {
        !isRendering && selectedCount > 0 && outputWidth >= 2 && outputHeight >= 2 && fps > 0
    }

    // MARK: - Folder loading

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of images (subfolders are included)."
        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        sourceFolder = url
        isScanning = true
        statusText = "Scanning \(url.lastPathComponent)…"
        errorMessage = nil
        lastOutput = nil
        anchorFrame = nil
        stabilizeSummary = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let found = ImageLoader.findImages(in: url)
            let size = found.first.flatMap { ImageLoader.pixelSize(of: $0) } ?? .zero
            await self.applyScan(frames: found, size: size)
        }
    }

    private func applyScan(frames found: [URL], size: CGSize) {
        frames = found
        sourceSize = size
        startFrame = 1
        endFrame = max(1, found.count)
        previewIndex = 0
        isScanning = false

        suppressCropSync = true
        crop = nil
        suppressCropSync = false
        outputWidth = Int(size.width) & ~1
        outputHeight = Int(size.height) & ~1
        oldCropWidth = size.width

        if found.isEmpty {
            statusText = "No images found in that folder."
            previewImage = nil
        } else {
            statusText = "\(found.count) images · \(Int(size.width))×\(Int(size.height))"
            loadPreview()
        }
    }

    func loadPreview() {
        previewTask?.cancel()
        guard !frames.isEmpty else { previewImage = nil; return }
        let idx = max(0, min(previewIndex, frames.count - 1))
        let url = frames[idx]
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let img = ImageLoader.loadPreview(url)
            guard !Task.isCancelled else { return }
            await self.setPreviewImage(img)
        }
    }

    private func setPreviewImage(_ img: CGImage?) { previewImage = img }

    // MARK: - Crop / scale helpers

    func resetCrop() { crop = nil }

    /// Apply a crop from numeric fields (clamped to the image).
    func setCrop(x: Int, y: Int, width: Int, height: Int) {
        guard sourceSize.width > 0 else { return }
        var r = CGRect(x: x, y: y, width: max(2, width), height: max(2, height))
        r = r.intersection(CGRect(origin: .zero, size: sourceSize)).integral
        if r.isEmpty { return }
        if r.size == sourceSize { crop = nil } else { crop = r }
    }

    func setCropAspect(_ aspect: Double) {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let base = effectiveCrop
        var w = base.width
        var h = w / aspect
        if h > base.height {
            h = base.height
            w = h * aspect
        }
        let r = CGRect(x: base.midX - w / 2, y: base.midY - h / 2, width: w, height: h).integral
        crop = r.intersection(CGRect(origin: .zero, size: sourceSize))
    }

    private func syncOutputSizeToCrop() {
        let c = effectiveCrop
        guard c.width > 0 else { return }
        // Keep the user's chosen scale factor when the crop changes.
        let previousScale = (outputWidth > 0 && oldCropWidth > 0) ? Double(outputWidth) / oldCropWidth : 1.0
        oldCropWidth = c.width
        setOutputScale(previousScale)
    }
    private var oldCropWidth: CGFloat = 0

    func setOutputScale(_ scale: Double) {
        let c = effectiveCrop
        outputWidth = max(2, Int((c.width * scale).rounded()) & ~1)
        outputHeight = max(2, Int((c.height * scale).rounded()) & ~1)
    }

    func widthChanged(_ newWidth: Int) {
        outputWidth = max(2, newWidth & ~1)
        if lockAspect {
            outputHeight = max(2, Int((Double(outputWidth) / cropAspect).rounded()) & ~1)
        }
    }

    func heightChanged(_ newHeight: Int) {
        outputHeight = max(2, newHeight & ~1)
        if lockAspect {
            outputWidth = max(2, Int((Double(outputHeight) * cropAspect).rounded()) & ~1)
        }
    }

    var currentScalePercent: Int {
        let c = effectiveCrop
        guard c.width > 0 else { return 100 }
        return Int((Double(outputWidth) / c.width * 100).rounded())
    }

    // MARK: - Rendering

    func chooseOutputAndRender() {
        guard canRender else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let folderName = sourceFolder?.lastPathComponent ?? "timelapse"
        panel.nameFieldStringValue = "timelapse-\(folderName).mp4"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Save the timelapse video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startRender(to: url)
    }

    func startRender(to url: URL) {
        let settings = RenderSettings(
            frames: selectedFrames,
            fps: fps,
            crop: crop,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            codec: codec,
            quality: quality,
            label: LabelSettings(mode: labelMode, timeZone: labelTimeZone, fontSize: labelFontSize),
            stabilize: StabilizerSettings(
                enabled: stabilizeEnabled,
                sensitivity: stabilizeSensitivity,
                anchorIndex: effectiveAnchorFrame - max(0, startFrame - 1),
                recenter: stabilizeRecenter
            ),
            outputURL: url
        )

        let renderer = TimelapseRenderer()
        self.renderer = renderer
        isRendering = true
        progress = 0
        errorMessage = nil
        lastOutput = nil
        stabilizeSummary = nil
        statusText = "Rendering 0 / \(settings.frames.count)…"

        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lastUpdate = Date.distantPast
            do {
                let stats = try await renderer.render(settings) { done, total in
                    // Throttle UI updates to ~20/sec.
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) > 0.05 || done == total else { return }
                    lastUpdate = now
                    let elapsed = now.timeIntervalSince(started)
                    let rate = elapsed > 0 ? Double(done) / elapsed : 0
                    let remaining = rate > 0 ? Double(total - done) / rate : 0
                    let status = String(
                        format: "Rendering %d / %d  ·  %.0f fps  ·  ~%@ left",
                        done, total, rate, Self.format(seconds: remaining)
                    )
                    let fraction = Double(done) / Double(total)
                    Task { await self.updateProgress(fraction, status: status) }
                }
                let secs = Date().timeIntervalSince(started)
                await self.finishRender(output: url, status: "Done in \(Self.format(seconds: secs)) → \(url.lastPathComponent)", error: nil)
                if let stats { await self.setStabilizeSummary(stats.summary) }
            } catch {
                if case RenderError.cancelled = error {
                    await self.finishRender(output: nil, status: "Cancelled.", error: nil)
                } else {
                    await self.finishRender(output: nil, status: "Failed.", error: error.localizedDescription)
                }
            }
        }
    }

    private func updateProgress(_ fraction: Double, status: String) {
        progress = fraction
        statusText = status
    }

    private func setStabilizeSummary(_ text: String) { stabilizeSummary = text }

    private func finishRender(output: URL?, status: String, error: String?) {
        isRendering = false
        if output != nil { progress = 1 }
        lastOutput = output
        statusText = status
        errorMessage = error
    }

    func cancelRender() {
        renderer?.cancel()
        statusText = "Cancelling…"
    }

    func revealLastOutput() {
        guard let url = lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    nonisolated static func format(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
