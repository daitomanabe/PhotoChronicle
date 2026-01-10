import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum DropUtil {
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        var urls: [URL] = []
        let group = DispatchGroup()

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(fileURLType) {
                group.enter()
                p.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let data = item as? Data else { return }
                    if let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
        return true
    }
}
