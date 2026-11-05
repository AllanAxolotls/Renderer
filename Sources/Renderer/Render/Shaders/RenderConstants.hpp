#pragma once
#include "CppBridge.hpp"

// Both can either be 2 or 4
#define BLAS_BVH_NODE_TYPE 2
#define TLAS_BVH_NODE_TYPE 4



#if BLAS_BVH_NODE_TYPE == 2
#define BlasNode Blas2Node
#else
#define BlasNode Blas4Node
#endif

#if TLAS_BVH_NODE_TYPE == 2
#define TlasNode Tlas2Node
#else
#define TlasNode Tlas4Node
#endif



namespace RasterizerConstants {}

namespace RayTracerConstants {
     //! must match Constants/RenderConstants.swift: RayTracerConstants.maxTextureCount
    static constant int MaxTextures = 128;
    static constant int MaxLightBounces = 4;

    static constant float3 horizonColor = {207.0f/255.0f, 219.0f/255.0f, 230.0f/255.0f};
    static constant float3 zenithColor = {60.0f/255.0f, 138.0f/255.0f, 201.0f/255.0f};
    static constant float skyIntensity = 4.0f;
    static constant float3 sunDirection = {0.0f, 1.0f, 0.0f};
    static constant float3 invSunDirection = 1.0f / sunDirection;
    static constant float3 sunColor = make_float3(10.0f, 9.5f, 8.5f) * 0.2f;
    static constant float sunIntensity = 256.0f;
}