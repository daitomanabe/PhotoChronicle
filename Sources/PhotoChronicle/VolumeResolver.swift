import Foundation

enum VolumeResolver {

    struct VolumeInfo {
        let uuid: String
        let name: String?
        let rootURL: URL
    }

    /// URL が属するボリュームの (UUID, rootURL) を得る（可能なら）
    static func volumeInfo(for url: URL) -> VolumeInfo? {
        do {
            let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey]
            let v = try url.resourceValues(forKeys: keys)
            guard let uuid = v.volumeUUIDString else { return nil }
            let root = v.volume ?? URL(fileURLWithPath: "/")
            return VolumeInfo(uuid: uuid, name: v.volumeName, rootURL: root)
        } catch {
            return nil
        }
    }

    /// 現在マウント中の volumeUUID -> rootURL を解決
    static func mountURL(forVolumeUUID uuid: String) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey]
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        for v in vols {
            if let info = volumeInfo(for: v), info.uuid.lowercased() == uuid.lowercased() {
                return info.rootURL
            }
        }
        // root volume fallback (best-effort)
        return nil
    }

    static func relPath(of absoluteURL: URL, volumeRoot: URL) -> String {
        let abs = absoluteURL.standardizedFileURL.path
        let root = volumeRoot.standardizedFileURL.path
        if abs == root { return "" }
        if abs.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            let start = root.hasSuffix("/") ? root.count : root.count + 1
            let idx = abs.index(abs.startIndex, offsetBy: start)
            return String(abs[idx...])
        }
        // fallback: return lastPathComponent
        return absoluteURL.lastPathComponent
    }

    static func destRootRelpath(destFolder: URL, volumeRoot: URL) -> String {
        // destRootRelpath is relative to volume root
        let rel = relPath(of: destFolder, volumeRoot: volumeRoot)
        return rel.isEmpty ? "." : rel
    }
}
