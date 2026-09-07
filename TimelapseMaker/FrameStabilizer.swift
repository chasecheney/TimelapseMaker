import Foundation
import CoreGraphics
import Vision

struct StabilizerSettings {
    var enabled = false
    /// 0 = align almost everything, 1 = only frames nearly identical to the anchor.
    var sensitivity: Double = 0.5
    /// Index (within the frames being rendered) of the frame everything is locked to.
    var anchorIndex: Int = 0
    /// Region of the source (top-left pixel coords) to analyze — normally the crop, so static
    /// UI outside it (a sidebar, a toolbar) can't fight the content you care about. nil = whole frame.
    var analysisRect: CGRect? = nil
    /// When the correction has used more than half the margin on one side, slowly pan the
    /// locked view back toward the crop's original position so margin is recovered.
    var recenter = true
    /// Fraction of the remaining offset recovered per frame while recentering (0.02 ≈ 2%/frame).
    var recenterRate: Double = 0.02

    /// Minimum normalized cross-correlation for a frame to count as "the same scene".
    var similarityThreshold: Double { 0.50 + 0.45 * sensitivity }
}

struct StabilizerStats {
    var aligned = 0        // frames that received a non-zero correction
    var passedThrough = 0  // frames similar enough but needing no shift
    var resets = 0         // scene changes: frame became the new anchor
    var clamped = 0        // frames whose correction was limited by the crop margin
    var recentered = 0     // frames during which the view drifted back toward center
    var maxShift: CGFloat = 0

    var summary: String {
        var parts = ["\(aligned) aligned"]
        if resets > 0 { parts.append("\(resets) scene change\(resets == 1 ? "" : "s")") }
        if clamped > 0 { parts.append("\(clamped) limited by crop margin") }
        if recentered > 0 { parts.append("\(recentered) recentering") }
        if maxShift > 0 { parts.append(String(format: "max shift %.0f px", maxShift)) }
        return parts.joined(separator: " · ")
    }
}

/// Locks each frame to an anchor frame by estimating the X/Y shift between them
/// (Vision's translational registration) and verifying the match with a
/// normalized cross-correlation. Frames that don't match the anchor well enough
/// are treated as a scene change: they pass through unshifted and become the new anchor.
final class FrameStabilizer {
    struct Result {
        var shift: CGPoint        // how far to move the frame's content, in source pixels
        var similarity: Double    // 0...1 against the anchor after alignment
        var reset: Bool           // this frame became the new anchor
    }

    /// Small grayscale copy used for analysis.
    private struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let scale: CGFloat   // source pixels per analysis pixel
        let cgImage: CGImage
    }

    private let settings: StabilizerSettings
    private let analysisWidth = 1600
    private var anchor: Gray?
    /// Correction that was in effect when the anchor was last replaced, so a scene change
    /// carries the current alignment forward instead of jumping back to zero.
    private var baseShift: CGPoint = .zero
    private var lastShift: CGPoint = .zero
    /// Slow pan applied on top of the measured correction to drift back toward center.
    private var recenterOffset: CGPoint = .zero
    private var signX: CGFloat = 1
    private var signY: CGFloat = 1
    private(set) var stats = StabilizerStats()

    init(settings: StabilizerSettings) {
        self.settings = settings
        calibrateSigns()
    }

    func setAnchor(_ image: CGImage) {
        anchor = makeGray(image)
    }

    /// Turns the measured correction into the shift actually used for drawing:
    /// 1. adds the slow recentering pan (if enabled and the view is closer to an edge than to center),
    /// 2. limits the result so the crop window, moved by -shift, stays inside the image.
    /// Without a crop there is no margin, so no shift is possible.
    func finalizeShift(_ measured: CGPoint, crop: CGRect?, imageSize: CGSize) -> CGPoint {
        guard let crop = crop else {
            if measured != .zero { stats.clamped += 1 }
            return .zero
        }
        // window = crop - shift must satisfy 0 <= minX and maxX <= width (same for y)
        let minShiftX = crop.maxX - imageSize.width   // <= 0  (margin on the right)
        let maxShiftX = crop.minX                      // >= 0  (margin on the left)
        let minShiftY = crop.maxY - imageSize.height
        let maxShiftY = crop.minY

        var shift = CGPoint(x: measured.x + recenterOffset.x, y: measured.y + recenterOffset.y)

        if settings.recenter {
            var drifted = false
            func drift(_ value: CGFloat, minLimit: CGFloat, maxLimit: CGFloat, offset: inout CGFloat) -> CGFloat {
                // "Closer to the edge than to center": beyond half the margin on that side.
                let margin = value > 0 ? maxLimit : -minLimit
                guard margin > 0, abs(value) > margin / 2 else { return value }
                // Pan back by a fraction of the current offset, at least 1 px so it always finishes.
                var step = abs(value) * CGFloat(settings.recenterRate)
                step = max(1, step.rounded())
                step = min(step, abs(value))
                let delta = value > 0 ? -step : step
                offset += delta
                drifted = true
                return value + delta
            }
            shift.x = drift(shift.x, minLimit: minShiftX, maxLimit: maxShiftX, offset: &recenterOffset.x)
            shift.y = drift(shift.y, minLimit: minShiftY, maxLimit: maxShiftY, offset: &recenterOffset.y)
            if drifted { stats.recentered += 1 }
        }

        let clamped = CGPoint(x: min(max(shift.x, minShiftX), maxShiftX),
                              y: min(max(shift.y, minShiftY), maxShiftY))
        if clamped != shift { stats.clamped += 1 }
        return clamped
    }

    func process(_ image: CGImage) -> Result {
        guard let gray = makeGray(image) else {
            return Result(shift: .zero, similarity: 0, reset: false)
        }
        guard let ref = anchor else {
            anchor = gray
            return Result(shift: .zero, similarity: 1, reset: false)
        }

        // Estimate displacement of this frame relative to the anchor (analysis pixels).
        var d = register(reference: ref, target: gray)
        let limitX = CGFloat(ref.width) * 0.3, limitY = CGFloat(ref.height) * 0.3
        if abs(d.x) > limitX || abs(d.y) > limitY { d = .zero }
        let dInt = (x: Int(d.x.rounded()), y: Int(d.y.rounded()))

        // Verify: is the aligned match actually better than doing nothing?
        let simZero = ncc(ref, gray, dx: 0, dy: 0)
        let simShift = (dInt.x == 0 && dInt.y == 0) ? simZero : ncc(ref, gray, dx: dInt.x, dy: dInt.y)
        let useShift = simShift > simZero + 0.005
        let similarity = useShift ? simShift : simZero

        if similarity < settings.similarityThreshold {
            // Scene changed: lock to this frame from now on, keeping the current correction
            // so the picture doesn't jump.
            anchor = gray
            baseShift = lastShift
            stats.resets += 1
            return Result(shift: baseShift, similarity: similarity, reset: true)
        }

        guard useShift else {
            stats.passedThrough += 1
            return Result(shift: baseShift, similarity: similarity, reset: false)
        }

        // Content moved by +d; move it back by -d, in full-resolution pixels.
        let correction = CGPoint(x: (-CGFloat(dInt.x) * gray.scale).rounded(),
                                 y: (-CGFloat(dInt.y) * gray.scale).rounded())
        let shift = CGPoint(x: baseShift.x + correction.x, y: baseShift.y + correction.y)
        lastShift = shift
        stats.aligned += 1
        stats.maxShift = max(stats.maxShift, max(abs(correction.x), abs(correction.y)))
        return Result(shift: shift, similarity: similarity, reset: false)
    }

    // MARK: - Registration

    /// Displacement (dx, dy) of `target` content relative to `reference`, in analysis pixels,
    /// top-left coordinates. Uses Vision, with signs normalized by `calibrateSigns()`.
    private func register(reference: Gray, target: Gray) -> CGPoint {
        let raw = rawRegister(reference: reference.cgImage, target: target.cgImage)
        return CGPoint(x: raw.x * signX, y: raw.y * signY)
    }

    private func rawRegister(reference: CGImage, target: CGImage) -> CGPoint {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .zero
        }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return .zero }
        let t = obs.alignmentTransform
        return CGPoint(x: t.tx, y: t.ty)
    }

    /// Vision's sign/axis conventions aren't worth guessing: shift a synthetic image by a
    /// known amount, see what comes back, and remember the signs.
    private func calibrateSigns() {
        let w = 192, h = 144, dx = 13, dy = 7
        var base = [UInt8](repeating: 0, count: w * h)
        var seed: UInt32 = 12345
        for i in 0..<base.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            base[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        // Blur a little so the pattern has structure at more than one scale.
        var blurred = base
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for j in -1...1 { for i in -1...1 { sum += Int(base[(y + j) * w + (x + i)]) } }
                blurred[y * w + x] = UInt8(sum / 9)
            }
        }
        var shifted = [UInt8](repeating: 128, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let sx = x - dx, sy = y - dy
                if sx >= 0, sx < w, sy >= 0, sy < h { shifted[y * w + x] = blurred[sy * w + sx] }
            }
        }
        guard let a = Self.grayImage(width: w, height: h, pixels: blurred),
              let b = Self.grayImage(width: w, height: h, pixels: shifted) else { return }
        let r = rawRegister(reference: a, target: b)
        if abs(r.x) > 1 { signX = (r.x > 0) == (dx > 0) ? 1 : -1 }
        if abs(r.y) > 1 { signY = (r.y > 0) == (dy > 0) ? 1 : -1 }
    }

    // MARK: - Similarity

    /// Normalized cross-correlation between `a` and `b` where b is displaced by (dx, dy).
    /// Brightness/contrast invariant, so day-to-night drift doesn't read as a scene change.
    private func ncc(_ a: Gray, _ b: Gray, dx: Int, dy: Int) -> Double {
        // b's content is displaced by (dx, dy): b(p) = a(p - d), so a(x, y) pairs with b(x + dx, y + dy).
        let w = min(a.width, b.width), h = min(a.height, b.height)
        let x0 = max(0, -dx), x1 = min(w, w - dx)
        let y0 = max(0, -dy), y1 = min(h, h - dy)
        guard x1 - x0 > 16, y1 - y0 > 16 else { return 0 }

        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        var n = 0.0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in y0..<y1 {
                    let rowA = y * a.width
                    let rowB = (y + dy) * b.width
                    for x in x0..<x1 {
                        let va = Double(pa[rowA + x])
                        let vb = Double(pb[rowB + (x + dx)])
                        sa += va; sb += vb
                        saa += va * va; sbb += vb * vb; sab += va * vb
                        n += 1
                    }
                }
            }
        }
        let ma = sa / n, mb = sb / n
        let varA = saa / n - ma * ma, varB = sbb / n - mb * mb
        guard varA > 1e-6, varB > 1e-6 else { return varA < 1e-6 && varB < 1e-6 ? 1 : 0 }
        let cov = sab / n - ma * mb
        return max(0, min(1, cov / (varA * varB).squareRoot()))
    }

    // MARK: - Grayscale helpers

    private func makeGray(_ full: CGImage) -> Gray? {
        var image = full
        if let r = settings.analysisRect {
            let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
            let clipped = r.intersection(bounds).integral
            if clipped.width >= 32, clipped.height >= 32, let part = full.cropping(to: clipped) {
                image = part
            }
        }
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let w = min(analysisWidth, srcW)
        let scale = CGFloat(srcW) / CGFloat(w)
        let h = max(16, Int((CGFloat(srcH) / scale).rounded()))

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data, let cg = ctx.makeImage() else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let bpr = ctx.bytesPerRow
        pixels.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: y * w), data.advanced(by: y * bpr), w)
            }
        }
        return Gray(width: w, height: h, pixels: pixels, scale: scale, cgImage: cg)
    }

    private static func grayImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                memcpy(data.advanced(by: y * bpr), p.baseAddress!.advanced(by: y * width), width)
            }
        }
        return ctx.makeImage()
    }
}
