#pragma once

#include "RenderConstants.hpp"
#include "MeshTri.hpp"
#include "Ray.hpp"

struct Blas2Node {
    AABB aabb;
    int2 leafIndices;
    uint triangleIndex;
    uint triangleCount;
};

struct Blas4Node {
    AABB4 aabb4;
    int4 leafIndices;
    uint4 triangleIndices;
    uint4 triangleCounts;
};

namespace Blas2 {
    inline bool intersectsNode(
        thread const Ray& ray,
        thread const RayHit& rayHit,
        device const Blas2Node& node
    ) {
        return ray.intersectsAABBWithSmallerT(node.aabb, rayHit.distance);
    }

    inline void processLeaf(
        thread const Ray& ray,
        thread RayHit& rayHit,
        device const Blas2Node& node,
        device const MeshTri* triangleBuffer,
        const uint baseMeshTri
    ) {
        int startAt = node.triangleIndex;
        int stopAt = startAt + node.triangleCount;

        for (int i = startAt; i < stopAt; i++) {
            int primitiveId = i + baseMeshTri;
            device const MeshTri& triangle = triangleBuffer[primitiveId];
            const RayHit result = ray.intersectsTriangle(triangle);

            if (result.distance < rayHit.distance) {
                rayHit.distance = result.distance;
                rayHit.primitiveId = primitiveId;
                rayHit.barycentric = result.barycentric;
            }
        }
    }

    inline RayHit traverse(
        thread const Ray& ray,
        device const Blas2Node* nodeBuffer,
        device const MeshTri* triangleBuffer,
        const uint baseNode,
        const uint baseMeshTri
    ) {
        RayHit rayHit = RayHit();

        int nodeIndex = baseNode;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Blas2Node& node = nodeBuffer[nodeIndex];
            
            if (!Blas2::intersectsNode(ray, rayHit, node)) {
                stackPtr--;
                nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
                continue;
            }

            Blas2::processLeaf(ray, rayHit, node, triangleBuffer, baseMeshTri);

            const int leftIndex = node.leafIndices.x;
            const int rightIndex = node.leafIndices.y;
            if (leftIndex != -1) stack[stackPtr++] = leftIndex + baseNode;
            if (rightIndex != -1) stack[stackPtr++] = rightIndex + baseNode;

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return rayHit;
    }

    inline bool shadowIntersectsNode(
        thread const Ray& ray,
        device const Blas2Node& node
    ) {
        return ray.intersectsAABB(node.aabb);
    }

    inline bool shadowProcessLeaf(
        thread const Ray& ray,
        device const Blas2Node& node,
        device const MeshTri* triangleBuffer,
        const uint baseMeshTri
    ) {
        int startAt = node.triangleIndex;
        int stopAt = startAt + node.triangleCount;

        for (int i = startAt; i < stopAt; i++) {
            int primitiveId = i + baseMeshTri;
            device const MeshTri& triangle = triangleBuffer[primitiveId];
            float t = ray.intersectsTriangleWithDistance(triangle);
            if (t != INFINITY) return true;
        }

        return false;
    }

    inline bool shadowTraverse(
        thread const Ray& ray,
        device const Blas2Node* nodeBuffer,
        device const MeshTri* triangleBuffer,
        const uint baseNode,
        const uint baseMeshTri
    ) {
        int nodeIndex = baseNode;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Blas2Node& node = nodeBuffer[nodeIndex];
            
            if (!Blas2::shadowIntersectsNode(ray, node)) {
                stackPtr--;
                nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
                continue;
            }

            bool hit = Blas2::shadowProcessLeaf(ray, node, triangleBuffer, baseMeshTri);
            if (hit) return true;

            const int leftIndex = node.leafIndices.x;
            const int rightIndex = node.leafIndices.y;
            if (leftIndex != -1) stack[stackPtr++] = leftIndex + baseNode;
            if (rightIndex != -1) stack[stackPtr++] = rightIndex + baseNode;

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return false;
    }
}

namespace Blas4 {
    inline float4 intersectsNode(
        thread const Ray& ray,
        thread const RayHit& rayHit,
        device const Blas4Node& node
    ) {
        return ray.intersectsAABB4WithSmallerT(node.aabb4, rayHit.distance);
    }

    inline void processLeaf(
        thread const Ray& ray,
        thread RayHit& rayHit,
        device const Blas4Node& node,
        const int lane,
        device const MeshTri* triangleBuffer,
        const uint baseMeshTri
    ) {
        int startAt = node.triangleIndices[lane];
        int stopAt = startAt + node.triangleCounts[lane];

        for (int i = startAt; i < stopAt; i++) {
            int primitiveId = i + baseMeshTri;
            device const MeshTri& triangle = triangleBuffer[primitiveId];
            const RayHit result = ray.intersectsTriangle(triangle);

            if (result.distance < rayHit.distance) {
                rayHit.distance = result.distance;
                rayHit.primitiveId = primitiveId;
                rayHit.barycentric = result.barycentric;
            }
        }
    }

    inline RayHit traverse(
        thread const Ray& ray,
        device const Blas4Node* nodeBuffer,
        device const MeshTri* triangleBuffer,
        const uint baseNode,
        const uint baseMeshTri
    ) {
        RayHit rayHit = RayHit();
        int nodeIndex = baseNode;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Blas4Node& node = nodeBuffer[nodeIndex];

            float4 hits = Blas4::intersectsNode(ray, rayHit, node);

            #pragma unroll
            for (int lane = 0; lane < 4; lane++) {
                if (hits[lane] == INFINITY) continue;
                
                int leafIndex = node.leafIndices[lane];
                if (leafIndex == -1) {
                    Blas4::processLeaf(ray, rayHit, node, lane, triangleBuffer, baseMeshTri);
                } else {
                    stack[stackPtr++] = leafIndex + baseNode;
                }
            }

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return rayHit;
    }

    inline float4 shadowIntersectsNode(
        thread const Ray& ray,
        device const Blas4Node& node
    ) {
        return ray.intersectsAABB4(node.aabb4);
    }

    inline bool shadowProcessLeaf(
        thread const Ray& ray,
        device const Blas4Node& node,
        const int lane,
        device const MeshTri* triangleBuffer,
        const uint baseMeshTri
    ) {
        int startAt = node.triangleIndices[lane];
        int stopAt = startAt + node.triangleCounts[lane];

        for (int i = startAt; i < stopAt; i++) {
            int primitiveId = i + baseMeshTri;
            device const MeshTri& triangle = triangleBuffer[primitiveId];
            float t = ray.intersectsTriangleWithDistance(triangle);
            if (t != INFINITY) return true;
        }

        return false;
    }

    inline bool shadowTraverse(
        thread const Ray& ray,
        device const Blas4Node* nodeBuffer,
        device const MeshTri* triangleBuffer,
        const uint baseNode,
        const uint baseMeshTri
    ) {
        int nodeIndex = baseNode;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Blas4Node& node = nodeBuffer[nodeIndex];

            float4 hits = Blas4::shadowIntersectsNode(ray, node);

            #pragma unroll
            for (int lane = 0; lane < 4; lane++) {
                if (hits[lane] == INFINITY) continue;
                
                int leafIndex = node.leafIndices[lane];
                if (leafIndex == -1) {
                    bool hit = Blas4::shadowProcessLeaf(ray, node, lane, triangleBuffer, baseMeshTri);
                    if (hit) return true;
                } else {
                    stack[stackPtr++] = leafIndex + baseNode;
                }
            }

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return false;
    }
}

namespace Blas {
    static RayHit raycast(
        thread Ray ray,
        device const BlasNode* nodeBuffer,
        device const MeshTri* triangleBuffer,
        int baseNode,
        int baseMeshTri
    ) {
        #if BLAS_BVH_NODE_TYPE == 2
        return Blas2::traverse(ray, nodeBuffer, triangleBuffer, baseNode, baseMeshTri);
        #else
        return Blas4::traverse(ray, nodeBuffer, triangleBuffer, baseNode, baseMeshTri);
        #endif
    }

    static bool shadowRaycast(
        thread Ray ray,
        device const BlasNode* nodeBuffer,
        device const MeshTri* triangleBuffer,
        int baseNode,
        int baseMeshTri
    ) {
        #if BLAS_BVH_NODE_TYPE == 2
        return Blas2::shadowTraverse(ray, nodeBuffer, triangleBuffer, baseNode, baseMeshTri);
        #else
        return Blas4::shadowTraverse(ray, nodeBuffer, triangleBuffer, baseNode, baseMeshTri);
        #endif
    }
}