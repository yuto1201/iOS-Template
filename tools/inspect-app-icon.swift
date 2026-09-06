import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AppIconError: Error {
    case invalidArguments
    case invalidImage
    case transparentImage
    case writeFailed
}

struct Inspection {
    let image: CGImage
    let width: Int
    let height: Int
    let encodedHasAlpha: Bool
}

func inspect(_ url: URL) throws -> Inspection {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw AppIconError.invalidImage
    }

    let width = image.width
    let height = image.height
    guard width == 1024, height == 1024 else {
        throw AppIconError.invalidImage
    }

    let byteCount = width * height * 4
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    defer { pixels.deallocate() }
    guard let context = CGContext(
        data: pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw AppIconError.invalidImage
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = pixels.bindMemory(to: UInt8.self, capacity: byteCount)
    for index in stride(from: 3, to: byteCount, by: 4) where bytes[index] != 255 {
        throw AppIconError.transparentImage
    }

    let alphaInfo = image.alphaInfo
    let encodedHasAlpha = [
        CGImageAlphaInfo.alphaOnly,
        .first,
        .last,
        .premultipliedFirst,
        .premultipliedLast,
    ].contains(alphaInfo)
    return Inspection(image: image, width: width, height: height, encodedHasAlpha: encodedHasAlpha)
}

func writeOpaquePNG(_ inspection: Inspection, to url: URL) throws {
    let byteCount = inspection.width * inspection.height * 4
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    defer { pixels.deallocate() }
    guard let context = CGContext(
        data: pixels,
        width: inspection.width,
        height: inspection.height,
        bitsPerComponent: 8,
        bytesPerRow: inspection.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw AppIconError.invalidImage
    }
    let bounds = CGRect(x: 0, y: 0, width: inspection.width, height: inspection.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    context.draw(inspection.image, in: bounds)
    guard let opaqueImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw AppIconError.writeFailed
    }
    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AppIconError.writeFailed
    }
}

func emit(_ inspection: Inspection) throws {
    let value: [String: Any] = [
        "encodedHasAlpha": inspection.encodedHasAlpha,
        "heightPixels": inspection.height,
        "opaque": true,
        "widthPixels": inspection.width,
    ]
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
struct AppIconInspector {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 3 else { throw AppIconError.invalidArguments }
            switch arguments[1] {
            case "inspect":
                guard arguments.count == 3 else { throw AppIconError.invalidArguments }
                try emit(inspect(URL(fileURLWithPath: arguments[2])))
            case "prepare":
                guard arguments.count == 4 else { throw AppIconError.invalidArguments }
                let inspection = try inspect(URL(fileURLWithPath: arguments[2]))
                let output = URL(fileURLWithPath: arguments[3])
                try writeOpaquePNG(inspection, to: output)
                let prepared = try inspect(output)
                guard !prepared.encodedHasAlpha else { throw AppIconError.writeFailed }
                try emit(prepared)
            default:
                throw AppIconError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("app icon inspection failed\n".utf8))
            Foundation.exit(1)
        }
    }
}
