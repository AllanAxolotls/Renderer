import CoreGraphics
import UniformTypeIdentifiers
import ImageIO

func createImage(width: Int, height: Int, pixelData: Data) -> CGImage? {
    let bitsPerComponent = 8
    let bitsPerPixel = 32
    let bytesPerRow = width * 4
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    guard let provider = CGDataProvider(data: pixelData as CFData) else {
        return nil
    }
    
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: bitsPerComponent,
        bitsPerPixel: bitsPerPixel,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

func saveImageToDesktop(_ image: CGImage) {
    let fileManager = FileManager.default
    
    guard let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
        print("Could not find Desktop directory.")
        return
    }
    
    let fileURL = desktopURL.appendingPathComponent(outputImageName)
    
    if #available(macOS 11.0, *) {
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            print("Could not create image destination.")
            return
        }

        CGImageDestinationAddImage(destination, image, nil)
    
        if CGImageDestinationFinalize(destination) {
            print("Image saved to \(fileURL.path)")
        } else {
            print("Failed to save image.")
        }
    } else {
        print("Failed to save image, version 11.0 of macos required!")
    }
}