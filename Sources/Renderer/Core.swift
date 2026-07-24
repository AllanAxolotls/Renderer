import Cocoa

let FOV: Float = 90
let FOVRad = FOV * .pi / 180
let zNear: Float = 0.1 // The Near Clipping Plane
let zFar: Float = 10000 // The Far Clipping Plane

@MainActor var renderMode: RenderMode = .Rasterizer

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
