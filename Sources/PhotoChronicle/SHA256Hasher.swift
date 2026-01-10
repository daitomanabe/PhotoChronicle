import Foundation
import CryptoKit

enum SHA256Hasher {
    static func sha256Hex(of fileURL: URL, progress: ((Int) -> Void)? = nil) throws -> (hex: String, bytesRead: Int64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        let chunkSize = 4 * 1024 * 1024  // 4MB

        while true {
            if Task.isCancelled { throw CancellationError() }
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            total += Int64(data.count)
            hasher.update(data: data)
            progress?(data.count)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }
}
