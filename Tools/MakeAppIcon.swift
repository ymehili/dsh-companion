import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Reuse Mac artwork. Only flatten its transparent corners: iOS app icons must be opaque.
guard CommandLine.arguments.count == 3 else { fatalError("Expected source and new output path") }
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: outputURL.path) else { fatalError("Refusing to overwrite existing icon") }
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot decode Mac PNG") }
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                              bytesPerRow: 4096, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot create opaque icon surface") }
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot encode icon PNG") }
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon PNG") }
print("Mac DSH artwork prepared as an opaque 1024px iPhone icon")
