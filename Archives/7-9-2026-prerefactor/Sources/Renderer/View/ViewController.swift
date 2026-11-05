import Metal
import MetalKit
import QuartzCore
import GameController

class ViewController: NSViewController, MTKViewDelegate {
    let device: MTLDevice!
    public var gameView: GameView!

    public var renderHandler: RenderHandler
    public var scene: Scene? { didSet { renderHandler.setScene(scene) } }

    init(device: MTLDevice, scene: Scene? = nil) {
        self.device = device
        self.scene = scene
        self.renderHandler = RenderHandler(device: device, scene: scene)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
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
        if let scene = scene {
            // Block movement when in RayTracer Mode and the RayTracer is paused
            if !(renderHandler.rayTracerRenderer.isPaused && renderHandler.currentRenderMode == .RayTracer) { gameView.updateCamera(&scene.camera) }
        }

        if gameView.renderModeDirty {
            renderHandler.switchRenderMode()
            gameView.renderModeDirty = false
        }

        if gameView.renderPausedDirty {
            if renderHandler.currentRenderMode == .RayTracer { renderHandler.flipRayTracerPaused()  }
            gameView.renderPausedDirty = false
        }

        renderHandler.draw(in: view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setScreenSize(newWidth: size.width, newHeight: size.height)
        renderHandler.rasterRenderer.updateProjectionMatrix()
    }
}


