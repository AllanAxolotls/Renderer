import Metal
import MetalKit

public enum RenderMode {
    case Rasterizer
    case Raytracer
}

@MainActor protocol Renderer {
    var scene: Scene { get set }

    func draw(
        view: MTKView,
        commandQueue: MTLCommandQueue,
    )
}

