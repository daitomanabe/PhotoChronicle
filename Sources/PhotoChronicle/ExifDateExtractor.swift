import AVFoundation

enum ArchiveDateSource: String {
    case exif = "EXIF"
    case videoMeta = "VIDEO_META"
    case mtime = "MTIME"
}

struct ArchiveDateResult {
    let ymd: String  // "YYYY-MM-DD"
    let source: ArchiveDateSource
}

final class ExifDateExtractor {

    func exifDateYMD(_ url: URL) -> String? {
        let options: CFDictionary =
            [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary

        guard let src = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                let ymd = parseExifLikeYMD(s)
            {
                return ymd
            }
            if let s = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
                let ymd = parseExifLikeYMD(s)
            {
                return ymd
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let s = tiff[kCGImagePropertyTIFFDateTime] as? String,
            let ymd = parseExifLikeYMD(s)
        {
            return ymd
        }

        return nil
    }

    func videoDateYMD(_ url: URL) async -> String? {
        let asset = AVAsset(url: url)

        // Try common metadata
        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                // AVMetadataKey.commonKeyCreationDate is usually "creationDate"
                if let k = item.commonKey, k == .creationDate,
                    let v = try? await item.load(.value) as? String
                {
                    if let ymd = parseExifLikeYMD(v) { return ymd }
                }
            }
        }

        // Also simpler check on creationDate if available (though often it is nil or same as common)
        // Some formats put it in quickTime metadata
        // For robustness, if we failed above, fallback to mtime (handled by caller)
        return nil
    }

    /// "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD" を高速に返す
    /// Also handles "YYYY-MM-DDTHH:MM:SSZ" (ISO8601) common in video
    private func parseExifLikeYMD(_ s: String) -> String? {
        if s.isEmpty { return nil }

        // clean T or Z
        let datePart = s.replacingOccurrences(of: "T", with: " ").replacingOccurrences(
            of: "Z", with: "")

        let p1 = datePart.split(separator: " ").first.map(String.init) ?? datePart

        // Colon Style: YYYY:MM:DD
        if p1.contains(":") {
            let comps = p1.split(separator: ":")
            guard comps.count >= 3 else { return nil }
            let y = comps[0]
            let m = comps[1]
            let d = comps[2]
            if y == "0000" || m == "00" || d == "00" { return nil }
            if y.count == 4 && m.count == 2 && d.count == 2 {
                return "\(y)-\(m)-\(d)"
            }
        }

        // Dash Style already: YYYY-MM-DD
        if p1.contains("-") && p1.count >= 10 {
            let prefix = String(p1.prefix(10))
            let chars = Array(prefix)
            if chars.count == 10, chars[4] == "-", chars[7] == "-" {
                return prefix
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
