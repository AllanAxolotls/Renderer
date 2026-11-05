import Cocoa
import Metal

enum WindowConstants {
    static let initialWidth: CGFloat = 1920/2
    static let initialHeight: CGFloat = 1080/2
    static let initialSize = NSSize(width: initialWidth, height: initialHeight)
    static let initialTitle = "[ Rasterizer - RayTracer ]"

    static let clearColor = MTLClearColorMake(0xc5 / 255.0, 0xe5 / 255.0, 1.0, 1)
}