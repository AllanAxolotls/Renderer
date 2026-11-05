#include "CppBridge.hpp"
#include "Ray.hpp"
#include "RenderConstants.hpp"
#include "MeshTri.hpp"
#include "Tlas.hpp"
#include "BaseMaterial.hpp"
#include "Random.hpp"

struct Uniforms {
    uint sampleIndex;
    float fovScale; // = tan( (FOV (in degrees) -> FOV (in radians)) * 0.5 )
    float3 cameraPosition;
    float3 cameraForward;
    float3 cameraUp;
    float3 cameraRight;
};

struct TextureCollection {
    sampler samp;
    array<texture2d<float>, RayTracerConstants::MaxTextures> textures;
};

inline float3 getLook(
    const uint2 gid,
    const uint width,
    const uint height,
    constant Uniforms& uniforms,
    thread uint& rngState
) {
    bool isFirstSample = uniforms.sampleIndex == 0;
    float offsetX = select(random(rngState), 0.5f, isFirstSample);
    float offsetY = select(random(rngState), 0.5f, isFirstSample);

    float aspectRatio = (float)width / (float)height;
    float ndcX = ( (float)gid.x + offsetX) / (float)width * 2.0f - 1.0f;
    float ndcY = 1.0f - (( (float)gid.y + offsetY) / (float)height) * 2.0f;
    float projectedX = ndcX * aspectRatio * uniforms.fovScale;
    float projectedY = ndcY * uniforms.fovScale;

    return normalize(
        uniforms.cameraForward +
        projectedX * uniforms.cameraRight +
        projectedY * uniforms.cameraUp
    );
}

inline RaycastResult raycast(
    thread const Ray& ray,
    device const MeshTri*      meshTris,
    device const BlasNode*     blasNodes,
    device const TlasInstance* tlasInstances,
    device const TlasNode*     tlasNodes
) {
    return Tlas::raycast(ray, tlasNodes, tlasInstances, blasNodes, meshTris);
}
inline bool shadowRaycast(
    thread const Ray& ray,
    device const MeshTri*      meshTris,
    device const BaseMaterial* materials,
    device const BlasNode*     blasNodes,
    device const TlasInstance* tlasInstances,
    device const TlasNode*     tlasNodes
) {
    return Tlas::shadowRaycast(ray, tlasNodes, tlasInstances, blasNodes, meshTris, materials);
}


inline void getTangentSpace(float3 normal, thread float3& tangent, thread float3& bitangent) {
    float3 helper = abs(normal.x) > 0.99f ? make_float3(0.0f, 1.0f, 0.0f) : make_float3(1.0f, 0.0f, 0.0f);
    tangent = normalize(cross(normal, helper));
    bitangent = cross(normal, tangent);
}

// Samples a microfacet normal (Halfway vector H) according to the GGX distribution
inline float3 sampleGGX(float2 randVal, float roughness, float3 normal) {
    float a = roughness * roughness; // Disney reparameterization
    float phi = 2.0 * M_PI_F * randVal.x;
    
    // GGX distribution sampling equations
    float cosTheta = sqrt(clamp((1.0f - randVal.y) / (1.0f + (a * a - 1.0f) * randVal.y), 0.0f, 1.0f));
    float sinTheta = sqrt(clamp(1.0f - cosTheta * cosTheta, 0.0f, 1.0f));
    
    // Transform from spherical to local Cartesian coordinates
    float3 localH = make_float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    
    // Orient local H into world space relative to the normal
    float3 tangent, bitangent;
    getTangentSpace(normal, tangent, bitangent);
    return normalize(tangent * localH.x + bitangent * localH.y + normal * localH.z);
}

inline float3 cosineWeightedHemisphere(float3 normal, float2 rand) {
    float phi = 2.0f * M_PI_F * rand.x;
    float r = sqrt(rand.y);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = sqrt(1.0f - rand.y);
    float3 up = abs(normal.z) < 0.999f ? make_float3(0.0f, 0.0f, 1.0f) : make_float3(1.0f, 0.0f, 0.0f);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    return normalize(tangent * x + bitangent * y + normal * z);
}

float3 tracePath(
    Ray ray,
    thread uint& rngState,
    device const MeshTri* meshTris,
    device const BaseMaterial* materials,
    device const TextureCollection& collection,
    device const BlasNode* blasNodes,
    device const TlasInstance* tlasInstances,
    device const TlasNode* tlasNodes
) {
    float3 radiance = {0.0f, 0.0f, 0.0f};
    float3 throughput = {1.0f, 1.0f, 1.0f};
    bool specularBounce = true;

    for (uint bounce = 0; bounce < RayTracerConstants::MaxLightBounces; bounce++) {
        RaycastResult result = raycast(ray, meshTris, blasNodes, tlasInstances, tlasNodes);

        // Check if it's an enviroment/sky hit
        if (result.didNotHit()) {
            float3 look = ray.direction;
            float t = 0.5f * (look.y + 1.0f);
            float3 skyColor = mix(RayTracerConstants::horizonColor, RayTracerConstants::zenithColor, t);
            float sunAmount = pow(max(dot(look, RayTracerConstants::sunDirection), 0.0f), RayTracerConstants::sunIntensity);
            float3 skyRadiance = skyColor * RayTracerConstants::skyIntensity + RayTracerConstants::sunColor * sunAmount;
            radiance += throughput * skyRadiance;
            break;
        }

        device const MeshTri& meshTri = meshTris[result.primitiveId];
        device const BaseMaterial& material = materials[result.materialId];

        float3 normal = meshTri.getInterpolatedNormal(meshTri, result.barycentric);
        float3 albedo = material.diffuseColor.rgb;
        throughput *= albedo;

        float3 randomReflectionDirection = cosineWeightedHemisphere(normal, float2(random2(rngState)));
        ray.direction = randomReflectionDirection;
        ray.origin = result.getHit() + normal * 0.001f; // Offset to avoid self-intersection
        specularBounce = false;
    }

    return radiance;
}

kernel void raytrace(
    texture2d<half,  access::write> output        [[texture            (0) ]], // sample average
    texture2d<float, access::write> accum         [[texture            (1) ]], // raw accumulated light
    texture2d<float, access::read > prevAccum     [[texture            (2) ]], // previous raytrace accumulated light

    constant Uniforms&              uniforms      [[buffer             (0) ]],
    device const MeshTri*           meshTris      [[buffer             (1) ]],
    device const BaseMaterial*      materials     [[buffer             (2) ]],
    device const TextureCollection& collection    [[buffer             (3) ]],
    device const BlasNode*          blasNodes     [[buffer             (4) ]],
    device const TlasInstance*      tlasInstances [[buffer             (5) ]],
    device const TlasNode*          tlasNodes     [[buffer             (6) ]],
    uint2                           gid           [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();
    if ((gid.x >= width) || (gid.y >= height)) return;

    uint rngState = randomStartingState(gid, uniforms.sampleIndex);
    Ray ray = Ray(uniforms.cameraPosition, getLook(gid, width, height, uniforms, rngState));

    float3 radiance = tracePath(ray, rngState, meshTris, materials, collection, blasNodes, tlasInstances, tlasNodes);

    // To avoid dead pixels
    if (any(isnan(radiance)) || any(isinf(radiance))) {
        radiance = {0.0f, 0.0f, 0.0f};
    } 

    // Mix current and last frame
    float4 accumColor = make_float4(radiance.rgb, 1.0f);
    if (uniforms.sampleIndex > 0) {
        float4 prevColor = (uniforms.sampleIndex == 0) 
            ? float4(0.0f) 
            : prevAccum.read(gid);

        accumColor += prevColor;
    }

    accum.write(accumColor, gid);
    float3 averageColor = accumColor.rgb / float(uniforms.sampleIndex + 1);
    output.write(make_half4(make_half3(averageColor.rgb), 1.0f), gid);
}
