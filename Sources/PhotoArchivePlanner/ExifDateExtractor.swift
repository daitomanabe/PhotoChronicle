import Foundation
import ImageIO

enum ArchiveDateSource: String { case exif = "EXIF", mtime = "MTIME" }

struct ArchiveDateResult {
    let ymd: String          // "YYYY-MM-DD"
    let source: ArchiveDateSource
}

final class ExifDateExtractor {

    func exifDateYMD(_ url: URL) -> String? {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let src = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let ymd = parseExifLikeYMD(s) { return ymd }
            if let s = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
               let ymd = parseExifLikeYMD(s) { return ymd }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let ymd = parseExifLikeYMD(s) { return ymd }

        return nil
    }

    /// "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD" を高速に返す
    private func parseExifLikeYMD(_ s: String) -> String? {
        if s.isEmpty { return nil }
        let datePart = s.split(separator: " ").first.map(String.init) ?? s
        if datePart.contains(":") {
            let comps = datePart.split(separator: ":")
            guard comps.count >= 3 else { return nil }
            let y = comps[0], m = comps[1], d = comps[2]
            if y == "0000" || m == "00" || d == "00" { return nil }
            if y.count == 4 && m.count == 2 && d.count == 2 {
                return "\(y)-\(m)-\(d)"
            }
        }
        if datePart.count >= 10 {
            let p = datePart.prefix(10)
            let chars = Array(p)
            if chars.count == 10, chars[4] == "-", chars[7] == "-" {
                return String(p)
            }
        }
        return nil
    }

    /// mtime epoch を UTC 固定で "YYYY-MM-DD" にする
    static func ymdFromEpochUTC(_ epoch: Int64) -> String {
        let dt = Date(timeIntervalSince1970: TimeInterval(epoch))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!  // UTC fixed
        let c = cal.dateComponents([.year, .month, .day], from: dt)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
