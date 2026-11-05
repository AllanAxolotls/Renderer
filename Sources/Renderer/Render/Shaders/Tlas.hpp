#pragma once

#include "BaseMaterial.hpp"
#include "Blas.hpp"
#include "CppBridge.hpp"
#include "MeshTri.hpp"
#include "Ray.hpp"
#include "RenderConstants.hpp"

struct Tlas2Node {
    AABB aabb;
    int2 leafIndices;
    int instanceIndex;
};

struct Tlas4Node {
    AABB4 aabb4;
    int4 leafIndices;
    int4 instanceIndices;
};

struct TlasInstance {
    float4x4 modelMatrix;
    float4x4 invModelMatrix;
    int baseBlasNode;
    int baseMeshTri;
    int materialId;
};

namespace Tlas2 {
    inline bool intersectsNode(
        thread const Ray& ray,
        thread const RayHit& rayHit,
        device const Tlas2Node& node
    ) {
        return ray.intersectsAABBWithSmallerT(
            node.aabb, 
            rayHit.distance
        );
    }

    inline void processLeaf(
        thread const Ray& ray,
        thread RayHit& rayHit,
        device const Tlas2Node& node,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer
    ) {
        int instanceIndex = node.instanceIndex;
        if (instanceIndex == -1) return;

        device const TlasInstance& tlasInstance = tlasInstanceBuffer[instanceIndex];
        float4 origin4 = make_float4(ray.origin, 1.0f);
        float4 direction4 = make_float4(ray.direction, 0.0f);
        float3 localOrigin = make_float3(tlasInstance.invModelMatrix * origin4);
        float3 localDirection = normalize(make_float3(tlasInstance.invModelMatrix * direction4));

        RayHit blasResult = Blas::raycast(
            Ray(localOrigin, localDirection), 
            blasNodeBuffer, 
            triangleBuffer, 
            tlasInstance.baseBlasNode, 
            tlasInstance.baseMeshTri
        );

        if (blasResult.didHit()) {
            const float3 localHitPoint = localOrigin + localDirection * blasResult.distance;
            const float3 worldHitPoint = make_float3(tlasInstance.modelMatrix * make_float4(localHitPoint, 1.0f));
            blasResult.distance = length(worldHitPoint - ray.origin);
            blasResult.materialId = tlasInstance.materialId;
            blasResult.instanceId = instanceIndex;
        
            if (blasResult.distance < rayHit.distance) {
                rayHit = blasResult;
            }
        }
    }

    inline RayHit traverse(
        thread const Ray& ray,
        device const Tlas2Node* nodeBuffer,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer
    ) {
        RayHit rayHit = RayHit();
        int nodeIndex = 0;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Tlas2Node& node = nodeBuffer[nodeIndex];
            
            if (!Tlas2::intersectsNode(ray, rayHit, node)) {
                stackPtr--;
                nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
                continue;
            }

            Tlas2::processLeaf(ray, rayHit, node, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer);

            const int leftIndex = node.leafIndices.x;
            const int rightIndex = node.leafIndices.y;
            if (leftIndex != -1) stack[stackPtr++] = leftIndex;
            if (rightIndex != -1) stack[stackPtr++] = rightIndex;

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return rayHit;
    }

    inline bool shadowIntersectsNode(
        thread const Ray& ray,
        device const Tlas2Node& node
    ) {
        return ray.intersectsAABB(node.aabb);
    }

    inline bool shadowProcessLeaf(
        thread const Ray& ray,
        device const Tlas2Node& node,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer,
        device const BaseMaterial* materialBuffer
    ) {
        int instanceIndex = node.instanceIndex;
        if (instanceIndex == -1) return false;

        device const TlasInstance& tlasInstance = tlasInstanceBuffer[instanceIndex];
        if (deviceMaterialHasFlag(materialBuffer[tlasInstance.materialId], MaterialFlag_IsSky)) return false;

        float4 origin4 = make_float4(ray.origin, 1.0f);
        float4 direction4 = make_float4(ray.direction, 0.0f);
        float3 localOrigin = make_float3(tlasInstance.invModelMatrix * origin4);
        float3 localDirection = normalize(make_float3(tlasInstance.invModelMatrix * direction4));

        return Blas::shadowRaycast(
            Ray(localOrigin, localDirection), 
            blasNodeBuffer, 
            triangleBuffer, 
            tlasInstance.baseBlasNode, 
            tlasInstance.baseMeshTri
        );
    }

    inline bool shadowTraverse(
        thread const Ray& ray,
        device const Tlas2Node* nodeBuffer,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer,
        device const BaseMaterial* materialBuffer
    ) {
        int nodeIndex = 0;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Tlas2Node& node = nodeBuffer[nodeIndex];
            
            if (!Tlas2::shadowIntersectsNode(ray, node)) {
                stackPtr--;
                nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
                continue;
            }

            bool hit = Tlas2::shadowProcessLeaf(ray, node, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer, materialBuffer);
            if (hit) return true;

            const int leftIndex = node.leafIndices.x;
            const int rightIndex = node.leafIndices.y;
            if (leftIndex != -1) stack[stackPtr++] = leftIndex;
            if (rightIndex != -1) stack[stackPtr++] = rightIndex;

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return false;
    }
}

namespace Tlas4 {
    inline float4 intersectsNode(
        thread const Ray& ray,
        thread const RayHit& rayHit,
        device const Tlas4Node& node
    ) {
        return ray.intersectsAABB4WithSmallerT(
            node.aabb4, 
            rayHit.distance
        );
    }

    inline void processLeaf(
        thread const Ray& ray,
        thread RayHit& rayHit,
        device const Tlas4Node& node, 
        const int lane,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer
    ) {
        int instanceIndex = node.instanceIndices[lane];
        if (instanceIndex == -1) return;

        device const TlasInstance& tlasInstance = tlasInstanceBuffer[instanceIndex];
        const float4 origin4 = make_float4(ray.origin, 1.0f);
        const float4 direction4 = make_float4(ray.direction, 0.0f);
        const float3 localOrigin = make_float3(tlasInstance.invModelMatrix * origin4);
        const float3 localDirection = normalize(make_float3(tlasInstance.invModelMatrix * direction4));

        RayHit blasResult = Blas::raycast(
            Ray(localOrigin, localDirection), 
            blasNodeBuffer, 
            triangleBuffer, 
            tlasInstance.baseBlasNode, 
            tlasInstance.baseMeshTri
        );

        if (blasResult.didHit()) {
            const float3 localHitPoint = localOrigin + localDirection * blasResult.distance;
            const float3 worldHitPoint = make_float3(tlasInstance.modelMatrix * make_float4(localHitPoint, 1.0f));
            blasResult.distance = length(worldHitPoint - ray.origin);
            blasResult.materialId = tlasInstance.materialId;
            blasResult.instanceId = instanceIndex;
        
            if (blasResult.distance < rayHit.distance) {
                rayHit = blasResult;
            }
        }
    }

    inline RayHit traverse(
        thread const Ray& ray,
        device const Tlas4Node* nodeBuffer, 
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer
    ) {
        RayHit rayHit = RayHit();
        int nodeIndex = 0;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Tlas4Node& node = nodeBuffer[nodeIndex];

            float4 hits = Tlas4::intersectsNode(ray, rayHit, node);

            #pragma unroll
            for (int lane = 0; lane < 4; lane++) {
                if (hits[lane] == INFINITY) continue;
                
                int leafIndex = node.leafIndices[lane];
                if (leafIndex == -1) {
                    Tlas4::processLeaf(ray, rayHit, node, lane, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer);
                } else {
                    stack[stackPtr++] = leafIndex;
                }
            }

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return rayHit;
    }

    inline float4 shadowIntersectsNode(
        thread const Ray& ray,
        device const Tlas4Node& node
    ) {
        return ray.intersectsAABB4(node.aabb4);
    }

    inline bool shadowProcessLeaf(
        thread const Ray& ray,
        device const Tlas4Node& node, 
        const int lane,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer,
        device const BaseMaterial* materialBuffer
    ) {
        int instanceIndex = node.instanceIndices[lane];
        if (instanceIndex == -1) return false;

        device const TlasInstance& tlasInstance = tlasInstanceBuffer[instanceIndex];
        if (deviceMaterialHasFlag(materialBuffer[tlasInstance.materialId], MaterialFlag_IsSky)) return false;

        const float4 origin4 = make_float4(ray.origin, 1.0f);
        const float4 direction4 = make_float4(ray.direction, 0.0f);
        const float3 localOrigin = make_float3(tlasInstance.invModelMatrix * origin4);
        const float3 localDirection = normalize(make_float3(tlasInstance.invModelMatrix * direction4));

        return Blas::shadowRaycast(
            Ray(localOrigin, localDirection), 
            blasNodeBuffer, 
            triangleBuffer, 
            tlasInstance.baseBlasNode, 
            tlasInstance.baseMeshTri
        );
    }

    inline bool shadowTraverse(
        thread const Ray& ray,
        device const Tlas4Node* nodeBuffer, 
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer,
        device const BaseMaterial* materialBuffer
    ) {
        int nodeIndex = 0;
        int stack[16];
        int stackPtr = 0;

        while (nodeIndex != -1) {
            device const Tlas4Node& node = nodeBuffer[nodeIndex];

            float4 hits = Tlas4::shadowIntersectsNode(ray, node);

            #pragma unroll
            for (int lane = 0; lane < 4; lane++) {
                if (hits[lane] == INFINITY) continue;
                
                int leafIndex = node.leafIndices[lane];
                if (leafIndex == -1) {
                    bool hit = Tlas4::shadowProcessLeaf(ray, node, lane, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer, materialBuffer);
                    if (hit) return true;
                } else {
                    stack[stackPtr++] = leafIndex;
                }
            }

            stackPtr--;
            nodeIndex = (stackPtr < 0) ? -1 : stack[stackPtr];
        }

        return false;
    }
}

namespace Tlas {
    static RaycastResult raycast(
        thread const Ray& ray,
        device const TlasNode* nodeBuffer,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer
    ) {
        RayHit rayHit;
        #if TLAS_BVH_NODE_TYPE == 2
        rayHit = Tlas2::traverse(ray, nodeBuffer, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer);
        #else
        rayHit = Tlas4::traverse(ray, nodeBuffer, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer);
        #endif

        return RaycastResult {
            ray.origin + ray.direction * rayHit.distance,
            rayHit.distance,
            rayHit.barycentric,
            rayHit.primitiveId,
            rayHit.materialId,
            rayHit.instanceId
        };
    }

    /// Returns true if the Ray hit something
    static bool shadowRaycast(
        thread const Ray& ray,
        device const TlasNode* nodeBuffer,
        device const TlasInstance* tlasInstanceBuffer,
        device const BlasNode* blasNodeBuffer,
        device const MeshTri* triangleBuffer,
        device const BaseMaterial* materialBuffer
    ) {
        #if TLAS_BVH_NODE_TYPE == 2
        return Tlas2::shadowTraverse(ray, nodeBuffer, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer, materialBuffer);
        #else
        return Tlas4::shadowTraverse(ray, nodeBuffer, tlasInstanceBuffer, blasNodeBuffer, triangleBuffer, materialBuffer);
        #endif
    }
}