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

    // Recieved Light
    float3 radiance = {0.0f, 0.0f, 0.0f};

    // Which Colors don't get absorbed
    float3 throughput = {1.0f, 1.0f, 1.0f};

    for (uint bounce = 0; bounce < RayTracerConstants::MaxLightBounces; bounce++) {
        RaycastResult hitResult = raycast(ray, meshTris, blasNodes, tlasInstances, tlasNodes);

        // Sky
        if (hitResult.didNotHit()) {
            float t = 0.5f * (ray.direction.y + 1.0f);
            float3 skyColor = mix(RayTracerConstants::horizonColor, RayTracerConstants::zenithColor, t);
            float sunAmount = pow(max(dot(ray.direction, RayTracerConstants::sunDirection), 0.0f), RayTracerConstants::sunIntensity);
            radiance += throughput * (skyColor * RayTracerConstants::skyIntensity + RayTracerConstants::sunColor * sunAmount);
            break;
        }

        // Emissive Materials (if it emits light, leave early)
        device const BaseMaterial& material = materials[hitResult.materialId];
        radiance += throughput * material.emissionColor.rgb;
        if (material.emissionColor.r + material.emissionColor.g + material.emissionColor.b != 0) {
            break;
        }

        device const MeshTri& meshTri = meshTris[hitResult.primitiveId];
        float2 uv = MeshTri::getInterpolatedUV(meshTri, hitResult.barycentric);

        // SkyBoxes (should not be shaded, leave early)
        if (deviceMaterialHasFlag(material, MaterialFlag_IsSky)) {
            output.write(make_half4(1.0, 0.0, 0.0, 1.0), gid);
            return;

            float4 texColor = collection.textures[material.diffuseTextureIndex].sample(collection.samp, uv, gradient2d(0.0f, 0.0f));
            float3 skyEmissive = material.diffuseColor.rgb * texColor.rgb;
            float t = 0.5f * (ray.direction.y + 1.0f);
            float3 skyColor = mix(RayTracerConstants::horizonColor, RayTracerConstants::zenithColor, t);
            radiance += throughput * mix(skyColor * RayTracerConstants::skyIntensity, skyEmissive, 0.5f);
            break;
        }

        // Stochastic Dissolve Check
        float stochastic_dissolve = random(rngState);
        float dissolve = material.dissolveTextureIndex == -1 
            ? material.diffuseColor.w
            : collection.textures[material.dissolveTextureIndex].sample(collection.samp, uv, gradient2d(0.0f, 0.0f)).a;
        
        if (stochastic_dissolve > dissolve) {
            // To avoid intersecting the same triangle, nudge the ray a bit
            bounce--;
            ray.origin = hitResult.getHit() + ray.direction * 1e-3; // making this number any smaller makes it get stuck in a loop when faces are nearly perpendicular to the camera
            continue;
        }

        float4 texColor = make_float4(material.diffuseColor.rgb, 1.0f);
        texColor *= collection.textures[material.diffuseTextureIndex].sample(collection.samp, uv, gradient2d(0.0, 0.0));
        float3 albedo = mix(material.diffuseColor.rgb, texColor.rgb, texColor.a);
        
        // Fresnel
        // Non-metals (dielectrics) reflect ~4% white light. Metals reflect their albedo tint
        float specularProbability;
        float3 F0;
        float3 F;
        float3 normal = MeshTri::getInterpolatedNormal(meshTri, hitResult.barycentric);
        if (dot(normal, ray.direction) > 0.0) normal = -normal;

        {
            F0 = mix(float3(0.04f), albedo, material.metallic);
            float cosTheta = clamp(dot(-ray.direction, normal), 0.0f, 1.0f);
            float3 maxFresnelAtEdge = max(float3(1.0f - material.roughness), F0); 
            float base = 1.0f - cosTheta;
            float baseSquared = base * base;
            F = F0 + (maxFresnelAtEdge - F0) * (baseSquared * baseSquared * base); // powf(base, 5.0f)

            // Calculate scalar probability for path selection via luminance conversion
            specularProbability = clamp(0.2126f * F.r + 0.7152f * F.g + 0.0722f * F.b, 0.01f, 0.99f);
        }

        /*
        float3 displayNormal = (normal + float3(1.0f)) * 0.5f;
        output.write(
            make_half4(make_half3(albedo * displayNormal), 1.0), 
            gid
        );
        return;
        */

        // Next Event Estimation
        float normalDotLight = max(dot(normal, RayTracerConstants::sunDirection), 0.0f);
        if (normalDotLight > 0.0f) {
            const Ray shadowRay = Ray(hitResult.getHit() + normal * epsilon, RayTracerConstants::sunDirection);
            bool inShadow = shadowRaycast(shadowRay, meshTris, materials, blasNodes, tlasInstances, tlasNodes);
            if (!inShadow) {
                // Compute the Fresnel response relative to the incoming light vector
                float cosThetaLight = clamp(dot(RayTracerConstants::sunDirection, normal), 0.0f, 1.0f);
                float base = clamp(1.0f - cosThetaLight, 0.0f, 1.0f);
                float baseSquared = base * base;
                float3 maxFresnelAtEdge = max(float3(1.0f - material.roughness), F0);
                float3 F_Light = F0 + (maxFresnelAtEdge - F0) * (baseSquared * baseSquared * base);
                
                // Direct light split: White specular highlight vs colored diffuse reflection
                float3 directSpecular = F_Light; 
                float3 directDiffuse = albedo * (float3(1.0f) - F_Light) * (1.0f - material.metallic);
                
                radiance += throughput * (directDiffuse + directSpecular) * RayTracerConstants::sunColor * normalDotLight;
            }
        }
       
        // Russian Roulette
        // This is for colors that are too dark and can be discarded, a nice optimisation basically
        if (bounce > 3) {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05f, 0.95f);
            if (random(rngState) > p) break;
            throughput /= p;
        }

        // Indirect Surface Scattering and Path Selection
        ray.origin = hitResult.getHit() + normal * epsilon;
        float2 bounceRand = random2(rngState);

        if (random(rngState) < specularProbability) { // Specular Reflectance
            // (GGX Importance Sampling)
            // Clamp roughness slightly to prevent division-by-zero on smooth mirrors
            float roughness = max(material.roughness, 0.001f);
            
            // Generate a microfacet normal oriented matching GGX distribution profile
            float3 halfwayVector = sampleGGX(bounceRand, roughness, normal);
            
            ray.direction = reflect(ray.direction, halfwayVector);

            // Back-face reflection safety check
            if (dot(normal, ray.direction) < 0.0) {
                break;
            }

            // Weight updates through calculated Fresnel energy split
            throughput *= F / specularProbability;
        } else { // Diffuse Reflectance
            ray.direction = cosineWeightedHemisphere(normal, bounceRand);
            
            // Core Lambertian diffuse energy weight calculation
            float3 diffuseWeight = albedo * (float3(1.0f) - F) * (1.0f - material.metallic);
            throughput *= diffuseWeight / (1.0f - specularProbability);
        }

        ray.invDirection = 1.0f / ray.direction;
    }

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
