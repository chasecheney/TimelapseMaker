import Foundation
import AVFoundation
import AppKit
import CoreVideo

enum RenderError: LocalizedError {
    case noFrames
    case cannotCreateWriter(String)
    case cannotCreatePixelBuffer
    case cannotDecode(URL)
    case appendFailed(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noFrames: return "There are no frames to render."
        case .cannotCreateWriter(let s): return "Could not create the video file: \(s)"
        case .cannotCreatePixelBuffer: return "Could not allocate a frame buffer."
        case .cannotDecode(let url): return "Could not decode image: \(url.lastPathComponent)"
        case .appendFailed(let i, let s): return "Failed to write frame \(i): \(s)"
        case .cancelled: return "Rendering was cancelled."
        }
    }
}

/// Builds a video from a list of still images with AVFoundation.
/// Runs its work on a background thread; call `cancel()` from anywhere.
final class TimelapseRenderer {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    /// Renders the video. `progress` is called with (framesDone, totalFrames) from a background thread.
    /// Returns stabilization statistics when stabilization was on.
    @discardableResult
    func render(_ settings: RenderSettings, progress: @escaping (Int, Int) -> Void) async throws -> StabilizerStats? {
        let frames = settings.frames
        guard !frames.isEmpty else { throw RenderError.noFrames }

        // Stabilizer: lock everything to the anchor frame.
        var stabilizer: FrameStabilizer?
        if settings.stabilize.enabled {
            var stabSettings = settings.stabilize
            stabSettings.analysisRect = settings.crop
            let st = FrameStabilizer(settings: stabSettings)
            let anchorIdx = max(0, min(settings.stabilize.anchorIndex, frames.count - 1))
            guard let anchorImage = ImageLoader.loadImage(frames[anchorIdx]) else {
                throw RenderError.cannotDecode(frames[anchorIdx])
            }
            st.setAnchor(anchorImage)
            stabilizer = st
        }

        let width = max(2, settings.outputWidth & ~1)   // must be even for yuv420p
        let height = max(2, settings.outputHeight & ~1)

        // Remove any existing output; AVAssetWriter won't overwrite.
        try? FileManager.default.removeItem(at: settings.outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: .mp4)
        } catch {
            throw RenderError.cannotCreateWriter(error.localizedDescription)
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: Int(max(1, settings.fps * 2)),
            AVVideoAllowFrameReorderingKey: true
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(input) else {
            throw RenderError.cannotCreateWriter("Unsupported output settings for this codec/size.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RenderError.cannotCreateWriter(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Frame timing: use a timescale that represents the frame rate exactly.
        let timescale: Int32 = 60_000
        let frameDuration = Int64((Double(timescale) / settings.fps).rounded())

        let formatter = FrameLabeler.makeFormatter(settings: settings.label)
        let total = frames.count
        let sourceCrop = settings.crop

        for (index, url) in frames.enumerated() {
            if isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: settings.outputURL)
                throw RenderError.cancelled
            }

            while !input.isReadyForMoreMediaData {
                if isCancelled { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            guard let image = ImageLoader.loadImage(url) else {
                writer.cancelWriting()
                throw RenderError.cannotDecode(url)
            }

            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw RenderError.cannotCreatePixelBuffer
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else {
                writer.cancelWriting()
                throw RenderError.cannotCreatePixelBuffer
            }

            let label = FrameLabeler.label(for: url, settings: settings.label, formatter: formatter)
            var shift = CGPoint.zero
            if let st = stabilizer {
                let raw = st.process(image).shift
                shift = st.finalizeShift(raw, crop: sourceCrop,
                                         imageSize: CGSize(width: image.width, height: image.height))
            }
            Self.draw(image: image, crop: sourceCrop, shift: shift, label: label,
                      fontSize: settings.label.fontSize, into: pixelBuffer)

            let time = CMTime(value: Int64(index) * frameDuration, timescale: timescale)
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                let msg = writer.error?.localizedDescription ?? "unknown error"
                writer.cancelWriting()
                throw RenderError.appendFailed(index + 1, msg)
            }

            progress(index + 1, total)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RenderError.cannotCreateWriter(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        return stabilizer?.stats
    }

    // MARK: - Frame drawing

    /// Draws `image` (optionally cropped, optionally shifted by `shift` source pixels for
    /// stabilization) scaled to fill the pixel buffer, then the label.
    static func draw(image: CGImage, crop: CGRect?, shift: CGPoint = .zero, label: String?,
                     fontSize: Double, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(full)
        ctx.interpolationQuality = .high

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Region of the (shifted) image that fills the output. Moving content by +shift is the
        // same as sampling the source from a window moved by -shift. Top-left coordinates.
        let window = (crop ?? bounds).offsetBy(dx: -shift.x, dy: -shift.y).integral
        let visible = window.intersection(bounds)
        if !visible.isEmpty, window.width > 0, window.height > 0,
           let part = image.cropping(to: visible) {
            // Map the visible part of the window into the output; anything outside stays black.
            let sx = full.width / window.width, sy = full.height / window.height
            let destTopLeft = CGRect(x: (visible.minX - window.minX) * sx,
                                     y: (visible.minY - window.minY) * sy,
                                     width: visible.width * sx,
                                     height: visible.height * sy)
            // CGContext is bottom-left based; flip Y.
            let dest = CGRect(x: destTopLeft.minX,
                              y: full.height - destTopLeft.maxY,
                              width: destTopLeft.width,
                              height: destTopLeft.height)
            // The script used a plain scale (no letterboxing), so stretch to fill.
            ctx.draw(part, in: dest)
        }

        if let label = label, !label.isEmpty {
            drawLabel(label, fontSize: fontSize, in: ctx, canvas: full)
        }
    }

    private static func drawLabel(_ text: String, fontSize: Double, in ctx: CGContext, canvas: CGRect) {
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let font = NSFont.boldSystemFont(ofSize: CGFloat(fontSize))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0   // negative = stroke and fill
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()

        // Bottom-left with margins, mirroring the script's ASS style (MarginL 24, MarginV 18).
        let margin = CGFloat(24)
        let bottom = CGFloat(18)
        let origin = CGPoint(x: margin, y: bottom)

        // Translucent backing box for legibility.
        let pad: CGFloat = 8
        let box = CGRect(x: origin.x - pad, y: origin.y - pad / 2,
                         width: size.width + pad * 2, height: size.height + pad)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        str.draw(at: origin)
    }
}
