import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Decode at the size needed by profile views, away from the UI executor.
/// Keeping only the most recent image bounds memory even after many edits.
actor AvatarImageCache {
    static let shared = AvatarImageCache()
    private var sourceData: Data?
    private var decodedImage: CGImage?

    func image(for data: Data?) -> CGImage? {
        guard data != sourceData else { return decodedImage }
        sourceData = data
        decodedImage = nil
        guard let data, let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        decodedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
        return decodedImage
    }
}

enum AvatarService {
    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { throw WorkspaceFailure.invalid("头像图片无效或超过 5 MB。") }
        let side = min(thumbnail.width, thumbnail.height)
        let rectangle = CGRect(x: CGFloat(thumbnail.width - side) / 2, y: CGFloat(thumbnail.height - side) / 2,
            width: CGFloat(side), height: CGFloat(side))
        guard let cropped = thumbnail.cropping(to: rectangle),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WorkspaceFailure.invalid("无法处理头像图片。")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let image = context.makeImage() else { throw WorkspaceFailure.invalid("无法生成头像。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WorkspaceFailure.invalid("无法编码头像。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceFailure.invalid("头像编码未完成。") }
        // A fresh JPEG keeps no original EXIF/location metadata.
        return output as Data
    }
}
