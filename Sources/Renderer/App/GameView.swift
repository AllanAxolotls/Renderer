import MetalKit

final class GameView : MTKView {
    override var acceptsFirstResponder: Bool { true }

    var onEvent: ((NSEvent) -> Void)?

    override func keyDown(with event: NSEvent) { onEvent?(event) }
    override func keyUp(with event: NSEvent) { onEvent?(event) }
    override func mouseDown(with event: NSEvent) { onEvent?(event) }
    override func rightMouseDown(with event: NSEvent) { onEvent?(event) }
    override func rightMouseUp(with event: NSEvent) { onEvent?(event) }
    override func rightMouseDragged(with event: NSEvent) { onEvent?(event) }
    override func mouseMoved(with event: NSEvent) { onEvent?(event) }

    func configure() {
        clearColor = WindowConstants.clearColor
        framebufferOnly = false
        depthStencilPixelFormat = .depth32Float
        colorPixelFormat = .bgra8Unorm_srgb
        autoResizeDrawable = true
        window?.makeFirstResponder(self) 
    }
}