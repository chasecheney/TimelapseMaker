import Foundation
import AVFoundation
import CoreGraphics

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"

    var id: String { rawValue }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

enum LabelMode: String, CaseIterable, Identifiable {
    case none = "None"
    case filename = "Filename"
    case timestamp = "Timestamp"

    var id: String { rawValue }
}

enum LabelTimeZone: String, CaseIterable, Identifiable {
    case utc = "UTC"
    case eastern = "ET"
    case pacific = "PT"
    case local = "Local"

    var id: String { rawValue }

    var timeZone: TimeZone {
        switch self {
        case .utc: return TimeZone(identifier: "UTC")!
        case .eastern: return TimeZone(identifier: "America/New_York")!
        case .pacific: return TimeZone(identifier: "America/Los_Angeles")!
        case .local: return TimeZone.current
        }
    }

    var suffix: String {
        switch self {
        case .utc: return "UTC"
        case .eastern: return "ET"
        case .pacific: return "PT"
        case .local: return TimeZone.current.abbreviation() ?? ""
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case r16x9 = "16 : 9"
    case r16x10 = "16 : 10"
    case r4x3 = "4 : 3"
    case r1x1 = "1 : 1"
    case r9x16 = "9 : 16 (vertical)"

    var id: String { rawValue }

    /// width / height, or nil for unconstrained.
    var ratio: Double? {
        switch self {
        case .free: return nil
        case .r16x9: return 16.0 / 9.0
        case .r16x10: return 16.0 / 10.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        }
    }
}

struct LabelSettings {
    var mode: LabelMode = .none
    var timeZone: LabelTimeZone = .pacific
    var fontSize: Double = 28
    var timeFormat: String = "yyyy-MM-dd HH:mm:ss"
}

struct RenderSettings {
    var frames: [URL]
    var fps: Double
    /// Crop rectangle in source pixel coordinates (origin top-left). nil = whole image.
    var crop: CGRect?
    var outputWidth: Int
    var outputHeight: Int
    var codec: VideoCodec
    /// 0...1, maps to a target bitrate.
    var quality: Double
    var label: LabelSettings
    var stabilize: StabilizerSettings = StabilizerSettings()
    var outputURL: URL

    /// Approximate target bitrate in bits per second.
    var bitrate: Int {
        let pixelsPerSecond = Double(outputWidth * outputHeight) * fps
        // bits per pixel: 0.05 (very compressed) ... 0.45 (near-lossless looking)
        let bpp = 0.05 + quality * 0.40
        let factor = codec == .hevc ? 0.65 : 1.0
        return max(500_000, Int(pixelsPerSecond * bpp * factor))
    }
}

/// Parses Timesnapper-style filenames such as "2026-07-22--14-05-31 UTC.jpg"
/// and returns a label in the requested time zone.
enum FrameLabeler {
    private static let regex = try! NSRegularExpression(
        pattern: #"(\d{4})-(\d{2})-(\d{2})--(\d{2})-(\d{2})-(\d{2})\s*UTC"#
    )

    static func label(for url: URL, settings: LabelSettings, formatter: DateFormatter) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        switch settings.mode {
        case .none:
            return nil
        case .filename:
            return url.lastPathComponent
        case .timestamp:
            if let date = parseUTCDate(from: name) {
                let s = formatter.string(from: date)
                let suffix = settings.timeZone.suffix
                return suffix.isEmpty ? s : "\(s) \(suffix)"
            }
            return url.lastPathComponent
        }
    }

    static func makeFormatter(settings: LabelSettings) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = settings.timeZone.timeZone
        f.dateFormat = settings.timeFormat
        return f
    }

    static func parseUTCDate(from name: String) -> Date? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = regex.firstMatch(in: name, range: range), m.numberOfRanges == 7 else { return nil }
        func num(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let y = num(1), let mo = num(2), let d = num(3),
              let h = num(4), let mi = num(5), let s = num(6) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)
    }
}
