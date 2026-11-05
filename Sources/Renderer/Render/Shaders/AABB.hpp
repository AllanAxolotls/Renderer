#ifndef AABB_METAL
#define AABB_METAL

#include "CppBridge.hpp"

struct AABB {
    float3 minBounds;
    float3 maxBounds;
};

struct AABB4 {
    float4 minBoundsX; float4 maxBoundsX;
    float4 minBoundsY; float4 maxBoundsY;
    float4 minBoundsZ; float4 maxBoundsZ;
};

#endif