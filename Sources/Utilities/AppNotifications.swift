import Foundation
import UniformTypeIdentifiers

extension NotificationCenter {
    func postAddFiles() {
        post(name: .addFilesRequested, object: nil)
    }
}

extension Notification.Name {
    static let addFilesRequested = Notification.Name("addFilesRequested")
}

extension NSItemProvider {
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let nsurl = item as? NSURL {
                    continuation.resume(returning: nsurl as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
