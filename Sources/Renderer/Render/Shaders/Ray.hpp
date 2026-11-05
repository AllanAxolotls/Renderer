#pragma once

#include "AABB.hpp"
#include "MeshTri.hpp"

constant float epsilon = 1e-6;

struct RaycastResult {
    float4 hit; // .w holds the distance of the origin to the hit
    float2 barycentric;
    int primitiveId;
    int materialId;
    int instanceId;

    inline float getDistance() const { return hit.w; }
    inline void setDistance(float newValue) { hit.w = newValue; }
    inline float3 getHit() const { return hit.xyz; } 
    inline void setHit(float3 newValue) { hit = make_float4(newValue, hit.w); }
    inline bool didHit() const { return hit.w != INFINITY; }
    inline bool didNotHit() const { return hit.w == INFINITY; }

    RaycastResult(float3 h, float d, float2 b, int primId, int matId, int instId) : 
        hit(make_float4(h.x, h.y, h.z, d)), 
        barycentric(b), 
        primitiveId(primId),
        materialId(matId),
        instanceId(instId)
    {}
    RaycastResult() : 
        hit(make_float4(0, 0, 0, INFINITY)), 
        barycentric(0), 
        primitiveId(-1),
        materialId(-1),
        instanceId(-1)
    {}
};

struct RayHit {
    float distance;
    float2 barycentric;
    int primitiveId;
    int materialId;
    int instanceId;

    inline bool didHit() const { return distance != INFINITY; }
    inline bool didNotHit() const { return distance == INFINITY; }

    RayHit(float t, float u, float v) : 
        distance(t), 
        barycentric(make_float2(u, v)),
        primitiveId(-1),
        materialId(-1),
        instanceId(-1)
    {}
    RayHit() : distance(INFINITY), primitiveId(-1), materialId(-1), instanceId(-1) {}
};

struct Ray {
    float3 origin;
    float3 direction;
    float3 invDirection;

    Ray() = default;
    Ray(float3 o, float3 d) : origin(o), direction(d), invDirection(1.0 / d) {}

    inline bool intersectsAABB(const device AABB& aabb) const {
        // X-axis slab
        float tx1 = (aabb.minBounds.x - origin.x) * invDirection.x;
        float tx2 = (aabb.maxBounds.x - origin.x) * invDirection.x;
        float tmin = fmin(tx1, tx2);
        float tmax = fmax(tx1, tx2);

        // Y-axis slab
        float ty1 = (aabb.minBounds.y - origin.y) * invDirection.y;
        float ty2 = (aabb.maxBounds.y - origin.y) * invDirection.y;
        tmin = fmax(tmin, fmin(ty1, ty2));
        tmax = fmin(tmax, fmax(ty1, ty2));

        // Z-axis slab
        float tz1 = (aabb.minBounds.z - origin.z) * invDirection.z;
        float tz2 = (aabb.maxBounds.z - origin.z) * invDirection.z;
        tmin = fmax(tmin, fmin(tz1, tz2));
        tmax = fmin(tmax, fmax(tz1, tz2));

        return (tmin <= tmax) && (tmax > 0);
    }
    
    inline bool intersectsAABBWithSmallerT(const device AABB& aabb, float t) const {
        // X-axis slab
        float tx1 = (aabb.minBounds.x - origin.x) * invDirection.x;
        float tx2 = (aabb.maxBounds.x - origin.x) * invDirection.x;
        float tmin = fmin(tx1, tx2);
        float tmax = fmax(tx1, tx2);

        // Y-axis slab
        float ty1 = (aabb.minBounds.y - origin.y) * invDirection.y;
        float ty2 = (aabb.maxBounds.y - origin.y) * invDirection.y;
        tmin = fmax(tmin, fmin(ty1, ty2));
        tmax = fmin(tmax, fmax(ty1, ty2));

        // Z-axis slab
        float tz1 = (aabb.minBounds.z - origin.z) * invDirection.z;
        float tz2 = (aabb.maxBounds.z - origin.z) * invDirection.z;
        tmin = fmax(tmin, fmin(tz1, tz2));
        tmax = fmin(tmax, fmax(tz1, tz2));

        return (tmin <= tmax) && (tmax > 0) && (tmin < t);
    }

    inline float4 intersectsAABB4(const device AABB4& aabb4) const {
        const float4 tx1 = (aabb4.minBoundsX - float4(origin.x)) * invDirection.x;
        const float4 tx2 = (aabb4.maxBoundsX - float4(origin.x)) * invDirection.x;
        float4 tmin = fmin(tx1, tx2);
        float4 tmax = fmax(tx1, tx2);

        const float4 ty1 = (aabb4.minBoundsY - float4(origin.y)) * invDirection.y;
        const float4 ty2 = (aabb4.maxBoundsY - float4(origin.y)) * invDirection.y;
        tmin = fmax(tmin, fmin(ty1, ty2));
        tmax = fmin(tmax, fmax(ty1, ty2));

        const float4 tz1 = (aabb4.minBoundsZ - float4(origin.z)) * invDirection.z;
        const float4 tz2 = (aabb4.maxBoundsZ - float4(origin.z)) * invDirection.z;
        tmin = fmax(tmin, fmin(tz1, tz2));
        tmax = fmin(tmax, fmax(tz1, tz2));

        const bool4 hitCondition = (tmin <= tmax) && (tmax > 0.0f);
        return select(float4(INFINITY), tmin, hitCondition);
    }

    inline float4 intersectsAABB4WithSmallerT(const device AABB4& aabb4, float t) const {
        const float4 tx1 = (aabb4.minBoundsX - float4(origin.x)) * invDirection.x;
        const float4 tx2 = (aabb4.maxBoundsX - float4(origin.x)) * invDirection.x;
        float4 tmin = fmin(tx1, tx2);
        float4 tmax = fmax(tx1, tx2);
    
        const float4 ty1 = (aabb4.minBoundsY - float4(origin.y)) * invDirection.y;
        const float4 ty2 = (aabb4.maxBoundsY - float4(origin.y)) * invDirection.y;
        tmin = fmax(tmin, fmin(ty1, ty2));
        tmax = fmin(tmax, fmax(ty1, ty2));
    
        const float4 tz1 = (aabb4.minBoundsZ - float4(origin.z)) * invDirection.z;
        const float4 tz2 = (aabb4.maxBoundsZ - float4(origin.z)) * invDirection.z;
        tmin = fmax(tmin, fmin(tz1, tz2));
        tmax = fmin(tmax, fmax(tz1, tz2));
    
        const bool4 hitCondition = (tmin <= tmax) && (tmax > 0.0f) && (tmin < t);
        return select(float4(INFINITY), tmin, hitCondition);
    }

    inline RayHit intersectsTriangle(const device MeshTri& triangle) const {
        const float3 position0 = triangle.vertex0.position;
        const float3 edge1 = triangle.vertex1.position - position0;
        const float3 edge2 = triangle.vertex2.position - position0;

        // Backface Culling, keeps CCW-sound triangles
        const float3 normal = cross(edge1, edge2);
        if (dot(normal, direction) > 0) return RayHit();

        const float3 directionCrossEdge2 = cross(direction, edge2);
        const float det = dot(edge1, directionCrossEdge2);
        if (abs(det) < epsilon) { return RayHit(); }

        const float invDet = 1.0 / det;
        const float3 s = origin - position0;
        const float u = invDet * dot(s, directionCrossEdge2);
        if (u < -epsilon || u - 1 > epsilon) { return RayHit(); }

        const float3 sCrossEdge1 = cross(s, edge1);
        const float v = invDet * dot(direction, sCrossEdge1);
        if (v < -epsilon || u + v - 1 > epsilon) { return RayHit(); }

        const float t = invDet * dot(edge2, sCrossEdge1);
        if (t > epsilon) {
            return RayHit(t, u, v);
        }

        return RayHit();
    }

    inline float intersectsTriangleWithDistance(const device MeshTri& triangle) const {
        const float3 position0 = triangle.vertex0.position;
        const float3 edge1 = triangle.vertex1.position - position0;
        const float3 edge2 = triangle.vertex2.position - position0;

        // Backface Culling, keeps CCW-wound triangles
        const float3 normal = cross(edge1, edge2);
        if (dot(normal, direction) > 0) return INFINITY;
    
        const float3 directionCrossEdge2 = cross(direction, edge2);
        const float det = dot(edge1, directionCrossEdge2);
        if (abs(det) < epsilon) { return INFINITY; }
    
        const float invDet = 1.0 / det;
        const float3 s = origin - position0;
        const float u = invDet * dot(s, directionCrossEdge2);
        if (u < -epsilon || u - 1 > epsilon) return INFINITY;
    
        const float3 sCrossEdge1 = cross(s, edge1);
        const float v = invDet * dot(direction, sCrossEdge1);
        if (v < -epsilon || u + v - 1 > epsilon) return INFINITY;
    
        const float t = invDet * dot(edge2, sCrossEdge1);
        if (t > epsilon) return t;
    
        return INFINITY;
    }
};
