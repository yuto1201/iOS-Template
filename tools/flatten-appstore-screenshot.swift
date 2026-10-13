// Rewrites one Simulator capture as an opaque RGB PNG for App Store Connect.
// simctl writes RGBA PNGs even when every pixel is opaque; any pixel that is not fully opaque is refused, never blended.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: flatten-appstore-screenshot.swift INPUT OUTPUT") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("capture is not a readable image") }
let width = image.width, height = image.height
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { fail("capture has no color space") }

var pixels = [UInt8](repeating: 0, count: width * height * 4)
let opaque = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: bounds)
    return stride(from: 3, to: buffer.count, by: 4).allSatisfy { buffer[$0] == 255 }
}
guard opaque else { fail("capture contains a pixel that is not fully opaque") }

guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("cannot create an opaque image") }
context.draw(image, in: bounds)
guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot write the opaque capture")
}
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write the opaque capture") }
