import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

enum InspectionError: Error {
    case invalidArguments
    case unreadableImage
    case unreadableVideo
}

@main
struct VisualInspector {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw InspectionError.invalidArguments }
            let mode = CommandLine.arguments[1]
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            let result: [String: Any]
            switch mode {
            case "image", "image-alpha":
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                    throw InspectionError.unreadableImage
                }
                var measured: [String: Any] = ["widthPixels": width.intValue, "heightPixels": height.intValue]
                if mode == "image-alpha" {
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw InspectionError.unreadableImage }
                    measured.merge(try inspectAlpha(image)) { _, new in new }
                }
                result = measured
            case "video":
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                    throw InspectionError.unreadableVideo
                }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
                let width = Int(abs(transformed.width).rounded())
                let height = Int(abs(transformed.height).rounded())
                guard width > 0, height > 0 else { throw InspectionError.unreadableVideo }
                result = ["widthPixels": width, "heightPixels": height, "durationSeconds": duration.seconds]
            default:
                throw InspectionError.invalidArguments
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("visual inspection failed\n".utf8))
            Foundation.exit(1)
        }
    }

    // #477: hasAlpha only says the alpha channel exists, so the pixels are drawn into an RGBA buffer and read.
    // A fringe pixel is semi-transparent and near white (each unpremultiplied channel at least 240).
    static func inspectAlpha(_ image: CGImage) throws -> [String: Any] {
        let width = image.width
        let height = image.height
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw InspectionError.unreadableImage }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw InspectionError.unreadableImage }
        var transparentPixels = 0
        var translucentPixels = 0
        var fringePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 0 {
                transparentPixels += 1
            } else if alpha < 255 {
                translucentPixels += 1
                let nearWhite = (0..<3).allSatisfy { channel in
                    Int(pixels[offset + channel]) * 255 >= 240 * alpha
                }
                if nearWhite { fringePixels += 1 }
            }
        }
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        let transparentCorners = corners.filter { x, y in pixels[y * bytesPerRow + x * 4 + 3] == 0 }.count
        return [
            "hasAlpha": hasAlpha,
            "transparentPixels": transparentPixels,
            "translucentPixels": translucentPixels,
            "fringePixels": fringePixels,
            "transparentCorners": transparentCorners,
        ]
    }
}
