import simd

//! Must match Render/Shaders/MeshTri.hpp
struct MeshTri {
    let vertex0: Vertex
    let vertex1: Vertex
    let vertex2: Vertex

    @inlinable
    var normal: simd_float3 {
        simd_normalize(simd_cross(vertex1.position - vertex0.position, vertex2.position - vertex0.position))
    }

    @inlinable
    func centroid() -> simd_float3 {
        return (vertex0.position + vertex1.position + vertex2.position) / 3.0
    }

    @inlinable
    func getInterpolatedUV(bary: simd_float2) -> simd_float2 {
        return (
            (1.0 - bary.x - bary.y) * vertex0.uv
            + bary.x * vertex1.uv
            + bary.y * vertex2.uv
        )
    }

    @inlinable
    func getInterpolatedNormal(bary: simd_float2) -> simd_float3 {
        return simd_normalize(
            (1.0 - bary.x - bary.y) * vertex0.normal
            + bary.x * vertex1.normal
            + bary.y * vertex2.normal
        )
    }
}