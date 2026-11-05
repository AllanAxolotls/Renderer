#pragma once
#include "CppBridge.hpp"

#define MaterialFlag_IsSky (1 << 0)

struct BaseMaterial {
    float4 diffuseColor;
    float4 emissionColor;
    float roughness;
    float metallic;
    float refractiveIndex;
    uint flags;
    unsigned short diffuseTextureIndex;
    short dissolveTextureIndex;
};

// for Rasterizer
inline bool materialHasFlag(constant BaseMaterial& material, uint mask) {
    return (material.flags & mask) == mask;
}
// for RayTracer
inline bool deviceMaterialHasFlag(device const BaseMaterial& material, uint mask) {
    return (material.flags & mask) == mask;
}
