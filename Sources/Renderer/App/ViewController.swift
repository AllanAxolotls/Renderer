import Cocoa
import MetalKit

final class ViewController : NSViewController, MTKViewDelegate {
    private var updateCallback: (() -> ())? = nil
    private var renderCallback: ((MTKView) -> ())? = nil
    private var drawableSizeChangedCallback: ((CGSize) -> ())? = nil

    private unowned let gameView: GameView

    init(gameView: GameView) {
        self.gameView = gameView
        super.init(nibName: nil, bundle: nil)
        gameView.configure()
        gameView.delegate = self
    }

    func setCallbacks(
        updateCallback: @escaping () -> (),
        renderCallback: @escaping (MTKView) -> (),
        drawableSizeChangedCallback: @escaping (CGSize) -> ()
    ) {
        self.updateCallback = updateCallback
        self.renderCallback = renderCallback
        self.drawableSizeChangedCallback = drawableSizeChangedCallback
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        self.view = gameView
    }

    func draw(in view: MTKView) {
        // Main Update
        updateCallback?()

        // Render Update
        renderCallback?(view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSizeChangedCallback?(size)
    }
}