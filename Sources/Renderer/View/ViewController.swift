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
            case .Rasterizer: 
                currentRenderer = rasterRenderer
                raytracerRenderer.invalidateAccumulation()

                gameView.autoResizeDrawable = true
                gameView.drawableSize = CGSize(
                    width: view.bounds.width * (view.window?.screen?.backingScaleFactor ?? 1), 
                    height: view.bounds.height * (view.window?.screen?.backingScaleFactor ?? 1)
                )

            case .Raytracer: 
                currentRenderer = raytracerRenderer

                // To downscale the image size when Raytracing
                gameView.autoResizeDrawable = false
                let scaleFactor: CGFloat = 0.25
                gameView.drawableSize = CGSize(
                    width: view.bounds.width * (view.window?.screen?.backingScaleFactor ?? 1) * scaleFactor, 
                    height: view.bounds.height * (view.window?.screen?.backingScaleFactor ?? 1) * scaleFactor
                )
        }
        gameView.updateControls(camera: &scene.camera)
        currentRenderer.draw(view: view, commandQueue: commandQueue)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setScreenSize(newWidth: size.width, newHeight: size.height)
        rasterRenderer.updateProjectionMatrix()
    }
}


