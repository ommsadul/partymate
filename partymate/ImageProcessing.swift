import UIKit

enum ImageProcessing {
    /// Shrinks a picked photo to a sensible upload size and converts it to JPEG.
    static func jpegForUpload(_ data: Data, maxDimension: CGFloat = 1024, quality: CGFloat = 0.82) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longestSide)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        // Render at 1x so the pixel size matches targetSize, not the screen's scale.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
