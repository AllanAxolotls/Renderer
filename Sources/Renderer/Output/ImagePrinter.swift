import Foundation
import Cocoa


func savePixelDataToDesktop(name: String, width: Int, height: Int, pixelData: Data) {
    let fileManager = FileManager.default
    guard let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
        print("Could not find Desktop directory.")
        return
    }
    
    let fileURL = desktopURL.appendingPathComponent(name)
    
    pixelData.withUnsafeBytes { rawBytesPtr in
        guard let baseAddress = rawBytesPtr.baseAddress else {
            print("Failed to get base address from pixelData.")
            return
        }
        
        // 1. Create a bitmap representation directly from your raw bytes
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            print("Failed to create NSBitmapImageRep.")
            return
        }
        
        // 2. Copy your pixel buffer into the bitmap
        memcpy(bitmapRep.bitmapData, baseAddress, pixelData.count)
        
        // 3. Convert to PNG format
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Failed to generate PNG representation.")
            return
        }
        
        // 4. Write directly to disk
        do {
            try pngData.write(to: fileURL)
            print("Image successfully saved to: \(fileURL.path)")
        } catch {
            print("Failed to write PNG file to disk: \(error)")
        }
    }
}