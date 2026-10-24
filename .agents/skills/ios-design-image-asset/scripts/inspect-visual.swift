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
            case "image":
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                    throw InspectionError.unreadableImage
                }
                result = ["widthPixels": width.intValue, "heightPixels": height.intValue]
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
}
