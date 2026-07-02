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

public struct RasterizerUniforms {
    public var mvpMatrix: simd_float4x4
    public var normalMatrix: simd_float3x3
}

public struct RayTracerUniforms {
    let sampleIndex: Int32
    let sphereLightCount: Int32
    let fovScale: Float
    let cameraPosition: simd_float3
    let cameraForward: simd_float3
    let cameraUp: simd_float3
    let cameraRight: simd_float3
}

public struct RayTraceTriangleGPU {
    public var vertex0: Vertex
    public var vertex1: Vertex
    public var vertex2: Vertex
    public var materialIndex: Int32
}