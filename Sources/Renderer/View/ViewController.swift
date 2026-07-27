import Metal
import MetalKit
import QuartzCore
import GameController

class ViewController: NSViewController, MTKViewDelegate {
    let device: MTLDevice!
    public var gameView: GameView!
    public var commandQueue: MTLCommandQueue!

    public var scene: Scene!
    public var currentRenderer: Renderer!
    public var rasterRenderer: RasterRenderer!
    public var raytracerRenderer: RayTracerRenderer!
    public var lastUsedRenderMode: RenderMode = .Rasterizer

    init(device: MTLDevice, scene: Scene) {
        self.device = device
        self.scene = scene
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        commandQueue = device.makeCommandQueue()

        rasterRenderer = RasterRenderer(device: device, scene: scene)
        raytracerRenderer = RayTracerRenderer(device: device, scene: scene)
        currentRenderer = rasterRenderer

        gameView = GameView(frame: .zero, device: device)
        gameView.clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1)
        gameView.delegate = self
        gameView.framebufferOnly = false
        gameView.depthStencilPixelFormat = .depth32Float
        gameView.colorPixelFormat = .bgra8Unorm_srgb
        gameView.autoResizeDrawable = true
        self.view = gameView

        DispatchQueue.main.async { self.gameView.window?.makeFirstResponder(self.gameView) }
    }
    func draw(in view: MTKView) {
        switch renderMode {
            case .Rasterizer: 
                if lastUsedRenderMode != .Rasterizer {
                    currentRenderer = rasterRenderer
                }
            case .Raytracer: 
                if lastUsedRenderMode != .Raytracer { 
                    currentRenderer = raytracerRenderer
                }
        }

        if !(raytracingPaused && renderMode == .Raytracer) { gameView.updateControls(camera: &scene.camera) }
        currentRenderer.draw(view: view, commandQueue: commandQueue)
        lastUsedRenderMode = renderMode
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setScreenSize(newWidth: size.width, newHeight: size.height)
        rasterRenderer.updateProjectionMatrix()
    }
}


