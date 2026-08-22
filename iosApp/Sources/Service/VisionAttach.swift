import UIKit

/// Pending camera photos drained into the next /chat/completions call.
/// Mirrors VisionAttach.kt: downscale → JPEG → base64 data URL queue.
enum VisionAttach {

    private static var queue: [String] = []
    private static let lock = NSLock()

    /// Read + downscale + JPEG-encode an image file into a data URL and enqueue it.
    @discardableResult
    static func pushFile(_ url: URL, maxDim: CGFloat = 1280, quality: CGFloat = 0.8) -> Bool {
        guard let dataUrl = downscaleToDataUrl(url, maxDim: maxDim, quality: quality) else { return false }
        lock.lock()
        queue.append(dataUrl)
        lock.unlock()
        return true
    }

    static func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = queue
        queue.removeAll()
        return out
    }

    static func hasPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !queue.isEmpty
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
    }

    static func downscaleToDataUrl(_ url: URL, maxDim: CGFloat, quality: CGFloat) -> String? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        var target = image
        let maxSide = max(image.size.width, image.size.height)
        if maxSide > maxDim {
            let scale = maxDim / maxSide
            let newSize = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        guard let jpeg = target.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
