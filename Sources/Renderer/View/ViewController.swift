import Metal
import MetalKit
import QuartzCore

class ViewController: NSViewController, MTKViewDelegate {
    private var device: MTLDevice!
    public var gameView: GameView!
    public var commandQueue: MTLCommandQueue!

    public var scene: Scene!
    public var currentRenderer: Renderer!
    public var rasterRenderer: RasterRenderer!
    public var raytracerRenderer: RayTracerRenderer!

    override func loadView() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()
        scene = Scene(device: device)
        scene.initBVH()

        currentRenderer = rasterRenderer
        rasterRenderer = RasterRenderer(device: device, scene: scene)
        raytracerRenderer = RayTracerRenderer(device: device, scene: scene)

        gameView = GameView(frame: .zero, device: device)
        gameView.clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1)
        gameView.delegate = self
        gameView.framebufferOnly = true
        gameView.depthStencilPixelFormat = .depth32Float
        gameView.autoResizeDrawable = true
        self.view = gameView

        DispatchQueue.main.async { self.gameView.window?.makeFirstResponder(self.gameView) }
    }
    func draw(in view: MTKView) {
        switch renderMode {
            case .Rasterizer: currentRenderer = rasterRenderer
            case .Raytracer: currentRenderer = raytracerRenderer
        }
        gameView.updateControls(camera: &scene.camera)
        currentRenderer.draw(view: view, commandQueue: commandQueue)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setScreenSize(newWidth: size.width, newHeight: size.height)
        update_projection_matrix()
    }
}


