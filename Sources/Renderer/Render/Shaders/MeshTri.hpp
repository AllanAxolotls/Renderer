#pragma once
#include "Vertex.hpp"

struct MeshTri {
    const Vertex vertex0;
    const Vertex vertex1;
    const Vertex vertex2;

    static inline float3 getNormal(device const MeshTri& meshTri) {
        return normalize(cross(meshTri.vertex1.position - meshTri.vertex0.position, meshTri.vertex2.position - meshTri.vertex0.position));
    }

    static inline float2 getInterpolatedUV(device const MeshTri& meshTri, float2 bary) {
        return (
            (1 - bary.x - bary.y) * meshTri.vertex0.uv
            + bary.x * meshTri.vertex1.uv
            + bary.y * meshTri.vertex2.uv
        );
    }

    static inline float3 getInterpolatedNormal(device const MeshTri& meshTri, float2 bary) {
        return normalize(
            (1 - bary.x - bary.y) * meshTri.vertex0.normal
            + bary.x * meshTri.vertex1.normal
            + bary.y * meshTri.vertex2.normal
        );
    }
};


