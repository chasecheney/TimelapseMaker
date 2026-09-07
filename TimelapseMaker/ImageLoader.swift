import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageLoader {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"
    ]

    /// Finds every supported image under `folder` (recursively, like the script's `find`)
    /// and returns them sorted by filename using natural ordering.
    static func findImages(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            if let values = try? url.resourceValues(forKeys: Set(keys)),
               values.isRegularFile == true {
                found.append(url)
            }
        }
        found.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return found
    }

    /// Pixel size of an image without decoding it.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Respect EXIF orientation: if rotated 90/270, swap.
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    /// Fully decoded, orientation-corrected image.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return applyOrientation(img, source: src)
    }

    /// Downsampled image for the on-screen preview (still orientation-corrected).
    static func loadPreview(_ url: URL, maxPixels: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func applyOrientation(_ image: CGImage, source: CGImageSource) -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? UInt32, o != 1 else { return image }

        let w = image.width, h = image.height
        let swapped = (5...8).contains(o)
        let outW = swapped ? h : w
        let outH = swapped ? w : h

        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        // Transform mapping the stored pixels to the displayed orientation.
        var t = CGAffineTransform.identity
        switch o {
        case 2: t = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(w), y: 0)
        case 3: t = CGAffineTransform(translationX: CGFloat(w), y: CGFloat(h)).rotated(by: .pi)
        case 4: t = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h))
        // (EXIF 5–8: 5 = transposed, 6 = rotate 90° CW to display, 7 = transverse, 8 = rotate 90° CCW.)
        case 5: t = CGAffineTransform(translationX: CGFloat(h), y: CGFloat(w)).scaledBy(x: 1, y: -1).rotated(by: .pi / 2)
        case 6: t = CGAffineTransform(translationX: 0, y: CGFloat(w)).rotated(by: -.pi / 2)
        case 7: t = CGAffineTransform(scaleX: -1, y: 1).rotated(by: .pi / 2)
        case 8: t = CGAffineTransform(translationX: CGFloat(h), y: 0).rotated(by: .pi / 2)
        default: break
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
