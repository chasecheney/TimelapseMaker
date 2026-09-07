import SwiftUI
import AppKit

/// Shows a frame and lets the user draw / move / resize a crop rectangle.
/// `crop` is expressed in source pixel coordinates with a top-left origin.
struct CropEditorView: View {
    let image: CGImage
    let sourceSize: CGSize
    /// Fixed width/height ratio from the Aspect picker; nil = free (⇧ still constrains to the current ratio).
    var lockedAspect: Double? = nil
    @Binding var crop: CGRect?

    private enum DragMode {
        case create(start: CGPoint)
        case move(startRect: CGRect)
        case resize(corner: Corner, startRect: CGRect)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    @State private var dragMode: DragMode?
    /// Ratio (w/h) of the crop when the drag began, used for ⇧-constrained drags.
    @State private var dragStartAspect: Double = 1
    private let handleSize: CGFloat = 12
    private let minCropPixels: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            let scale = fitted.width > 0 ? sourceSize.width / fitted.width : 1
            let viewCrop = viewRect(for: crop ?? CGRect(origin: .zero, size: sourceSize), fitted: fitted, scale: scale)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)

                // Dim everything outside the crop.
                if crop != nil {
                    Path { p in
                        p.addRect(fitted)
                        p.addRect(viewCrop)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                }

                // Crop outline + thirds
                Path { p in
                    p.addRect(viewCrop)
                    let dx = viewCrop.width / 3, dy = viewCrop.height / 3
                    for i in 1...2 {
                        p.move(to: CGPoint(x: viewCrop.minX + dx * CGFloat(i), y: viewCrop.minY))
                        p.addLine(to: CGPoint(x: viewCrop.minX + dx * CGFloat(i), y: viewCrop.maxY))
                        p.move(to: CGPoint(x: viewCrop.minX, y: viewCrop.minY + dy * CGFloat(i)))
                        p.addLine(to: CGPoint(x: viewCrop.maxX, y: viewCrop.minY + dy * CGFloat(i)))
                    }
                }
                .stroke(Color.white.opacity(crop == nil ? 0.35 : 0.9), lineWidth: 1)

                // Corner handles
                ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let pt = point(of: corner, in: viewCrop)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: handleSize, height: handleSize)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .position(pt)
                }

                // Size readout
                let c = crop ?? CGRect(origin: .zero, size: sourceSize)
                Text("\(Int(c.width)) × \(Int(c.height))  @ \(Int(c.minX)), \(Int(c.minY))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .position(x: viewCrop.midX, y: max(fitted.minY + 12, viewCrop.minY - 14))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragMode == nil {
                            dragMode = beginDrag(at: value.startLocation, viewCrop: viewCrop, fitted: fitted)
                            dragStartAspect = viewCrop.height > 0 ? viewCrop.width / viewCrop.height : 1
                        }
                        guard let mode = dragMode else { return }
                        let shift = NSEvent.modifierFlags.contains(.shift)
                        let ratio: Double? = lockedAspect ?? (shift ? dragStartAspect : nil)
                        crop = updatedCrop(for: mode, translation: value.translation,
                                           location: value.location, fitted: fitted, scale: scale,
                                           ratio: ratio)
                    }
                    .onEnded { _ in dragMode = nil }
            )
        }
    }

    // MARK: - Geometry

    private func fittedRect(in container: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let s = min(container.width / sourceSize.width, container.height / sourceSize.height)
        let w = sourceSize.width * s, h = sourceSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func viewRect(for pixelRect: CGRect, fitted: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: fitted.minX + pixelRect.minX / scale,
               y: fitted.minY + pixelRect.minY / scale,
               width: pixelRect.width / scale,
               height: pixelRect.height / scale)
    }

    private func pixelRect(for viewRect: CGRect, fitted: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (viewRect.minX - fitted.minX) * scale,
               y: (viewRect.minY - fitted.minY) * scale,
               width: viewRect.width * scale,
               height: viewRect.height * scale)
    }

    private func point(of corner: Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func beginDrag(at p: CGPoint, viewCrop: CGRect, fitted: CGRect) -> DragMode {
        let grab = handleSize * 1.4
        for corner in Corner.allCases {
            let c = point(of: corner, in: viewCrop)
            if abs(c.x - p.x) <= grab && abs(c.y - p.y) <= grab {
                return .resize(corner: corner, startRect: viewCrop)
            }
        }
        if crop != nil && viewCrop.insetBy(dx: -4, dy: -4).contains(p) {
            return .move(startRect: viewCrop)
        }
        return .create(start: clamp(p, to: fitted))
    }

    private func updatedCrop(for mode: DragMode, translation: CGSize, location: CGPoint,
                             fitted: CGRect, scale: CGFloat, ratio: Double?) -> CGRect? {
        var r: CGRect
        switch mode {
        case .create(let start):
            let end = clamp(location, to: fitted)
            r = anchoredRect(anchor: start, to: end, ratio: ratio, bounds: fitted)
        case .move(let start):
            r = start.offsetBy(dx: translation.width, dy: translation.height)
            // Keep inside the image.
            if r.minX < fitted.minX { r.origin.x = fitted.minX }
            if r.minY < fitted.minY { r.origin.y = fitted.minY }
            if r.maxX > fitted.maxX { r.origin.x = fitted.maxX - r.width }
            if r.maxY > fitted.maxY { r.origin.y = fitted.maxY - r.height }
        case .resize(let corner, let start):
            let p = clamp(location, to: fitted)
            // The opposite corner stays fixed; the dragged corner follows the mouse.
            let anchor: CGPoint
            switch corner {
            case .topLeft: anchor = CGPoint(x: start.maxX, y: start.maxY)
            case .topRight: anchor = CGPoint(x: start.minX, y: start.maxY)
            case .bottomLeft: anchor = CGPoint(x: start.maxX, y: start.minY)
            case .bottomRight: anchor = CGPoint(x: start.minX, y: start.minY)
            }
            r = anchoredRect(anchor: anchor, to: p, ratio: ratio, bounds: fitted)
        }

        var px = pixelRect(for: r, fitted: fitted, scale: scale).integral
        px = px.intersection(CGRect(origin: .zero, size: sourceSize))
        if px.isNull || px.width < minCropPixels || px.height < minCropPixels {
            // Too small to be meaningful yet; keep whatever we had during a create drag.
            if case .create = mode { return crop }
            return crop
        }
        // Snap to even pixels so the output size is encoder-friendly.
        px.size.width = floor(px.width / 2) * 2
        if let ratio = ratio, ratio > 0 {
            px.size.height = max(2, (px.width / CGFloat(ratio) / 2).rounded() * 2)
            if px.maxY > sourceSize.height { px.origin.y = sourceSize.height - px.height }
            if px.minY < 0 { px.origin.y = 0 }
        } else {
            px.size.height = floor(px.height / 2) * 2
        }
        if px.size == sourceSize && px.origin == .zero { return nil }
        return px
    }

    /// Rectangle spanning `anchor` → `p`, optionally forced to `ratio` (w/h) and kept inside `bounds`.
    private func anchoredRect(anchor: CGPoint, to p: CGPoint, ratio: Double?, bounds: CGRect) -> CGRect {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        var w = abs(dx), h = abs(dy)
        if let ratio = ratio, ratio > 0 {
            // Follow whichever axis the mouse has moved further along (relative to the ratio).
            if w / CGFloat(ratio) >= h { h = w / CGFloat(ratio) } else { w = h * CGFloat(ratio) }
            // Don't let the constrained rect leave the image.
            let maxW = dx >= 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let maxH = dy >= 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            w = min(w, maxW, maxH * CGFloat(ratio))
            h = w / CGFloat(ratio)
        }
        // Direction: if the mouse hasn't moved on an axis yet, grow toward the image centre.
        let right = dx > 0 || (dx == 0 && anchor.x < bounds.midX)
        let down = dy > 0 || (dy == 0 && anchor.y < bounds.midY)
        return CGRect(x: right ? anchor.x : anchor.x - w,
                      y: down ? anchor.y : anchor.y - h,
                      width: w, height: h)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
}
