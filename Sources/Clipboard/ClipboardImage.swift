import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ClipboardImage: Equatable, Hashable {
    let pngData: Data
    let width: Int
    let height: Int
    let digest: String
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumPixels = 20_000_000
    static let maximumInputBytes = 100 * 1024 * 1024

    /// Normalize clipboard PNG/TIFF to a static PNG without source metadata.
    init?(data: Data) {
        guard data.count <= Self.maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maximumPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= Self.maximumBytes else { return nil }
        pngData = output as Data
        self.width = width; self.height = height
        digest = Self.digest(pngData)
    }

    init?(storedPNG data: Data, width: Int, height: Int, digest: String) {
        guard data.count <= Self.maximumBytes, Self.digest(data) == digest,
              width > 0, height > 0, width <= Self.maximumPixels / height,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { return nil }
        pngData = data; self.width = width; self.height = height; self.digest = digest
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func hash(into hasher: inout Hasher) { hasher.combine(digest) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.digest == rhs.digest }
    var title: String { "图片 · \(width) × \(height)" }
    func thumbnail(maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

enum ClipboardContent: Hashable {
    case text(String)
    case image(ClipboardImage)
    var byteCount: Int {
        switch self { case .text(let text): return text.utf8.count
        case .image(let image): return image.pngData.count }
    }
}
