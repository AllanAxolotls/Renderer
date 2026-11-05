import simd

public struct Vertex {
    public var position: simd_float3
    public var normal: simd_float3
    public var uv: simd_float2

    init(
        position: simd_float3 = simd_float3(0, 0, 0), 
        normal: simd_float3 = simd_float3(0, 1, 0), 
        uv: simd_float2 = simd_float2(0, 0)
    ) {
        self.position = position
        self.normal = normal
        self.uv = uv
    }
}