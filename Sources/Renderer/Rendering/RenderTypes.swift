import Metal
import MetalKit
import simd

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

public struct Uniforms {
    let sampleIndex: Int32
    let fovScale: Float
    let cameraPosition: simd_float3
    let cameraForward: simd_float3
    let cameraUp: simd_float3
    let cameraRight: simd_float3
}

public struct RayTraceTriangleGPU {
    public var vertex1: Vertex
    public var vertex2: Vertex
    public var vertex3: Vertex
    public var edge1: simd_float3
    public var edge2: simd_float3
    public var normal: simd_float3
    public var materialIndex: Int32
}

// For Rasterization
public struct MaterialGPU {
    var dissolve: Float
}
