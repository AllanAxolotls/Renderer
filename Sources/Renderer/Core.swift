import Cocoa

let FOV: Float = 90
let FOVRad = FOV * .pi / 180
let zNear: Float = 0.1
let zFar: Float = 1000

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
