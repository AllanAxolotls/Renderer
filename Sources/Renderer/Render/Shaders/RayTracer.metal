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

inline float3 sampleHemisphere(float3 normal, float2 rand) {
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

// Microfacet Distribution Function (GGX)
// Distribution of microfacets describing how much they align
inline float D(float3 h, float3 n, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float nDotH = max(dot(n, h), 0.0f);
    float nDotH2 = nDotH * nDotH;
    float denominator = nDotH2 * (a2 - 1.0f) + 1.0f;
    return a2 / (M_PI_F * denominator * denominator);
}

// Correct Dielectric F0 calculation based on IOR
inline float dielectricF0(float ior) {
    float t = (ior - 1.0f) / (ior + 1.0f);
    return t * t;
}

// Fresnel Reflectance at Normal Incidence (F0)
// Most dielectrics are around 0.04 unlike metals
inline float3 F0(const device BaseMaterial& material) {
    return mix(make_float3(0.04f), material.diffuseColor.rgb, material.metallic);
}

// Fresnel Term (Schlick's Approximation)
// How much light reflects off a surface versus how much enters it based on viewing angle
template <typename T>
inline T F(float cosTheta, T f0) {
    float angle = 1.0f - clamp(cosTheta, 0.0f, 1.0f);
    float angle2 = angle * angle;
    float angle5 = angle2 * angle2 * angle;
    return f0 + (1.0f - f0) * angle5;
}

// Monodirectional Shadow Masking Function
inline float G_1(float3 v, float3 n, float k) {
    float nDotV = max(dot(n, v), 0.0f);
    return nDotV / (nDotV * (1.0f - k) + k);
}

// Bidirectional Shadow Masking Function
inline float G(float3 wi, float3 wo, float3 n, float roughness) {
    float r = roughness + 1.0f;
    float k = (r * r) / 8.0f;
    float ggx1 = G_1(wi, n, k);
    float ggx2 = G_1(wo, n, k);
    return ggx1 * ggx2;
}

// Cook-Torrance BRDF
float3 f_r(float3 wi, float3 wo, float3 n, const device BaseMaterial& material) {
    float nDotL = max(dot(n, wi), 0.0f);
    float nDotV = max(dot(n, wo), 0.0f);
    if (nDotL < 0.0f || nDotV < 0.0f) return {0.0f, 0.0f, 0.0f};
    
    float3 h = normalize(wi + wo);
    float roughness = max(material.roughness, 0.001f);
    float d = D(h, n, roughness);

    float hDotV = max(dot(h, wo), 0.0f);
    float3 f0 = F0(material);
    float3 f = F(hDotV, f0);
    float g = G(wi, wo, n, roughness);

    float3 specular = (d * g * f) / max(4.0f * nDotL * nDotV, 0.001f);

    float3 kS = f;
    float3 kD = (1.0f - kS) * (1.0f - material.metallic);

    float3 albedo = material.diffuseColor.rgb;
    float3 diffuse = (albedo / M_PI_F) * kD;
    return diffuse + specular;
}

// Walter et al. Microfacet Transmission (BTDF)
float3 f_t(float3 wi, float3 wo, float3 n, float eta, float roughness) {
    float3 h = normalize(-(eta * wi + wo));
    
    float nDotWi = dot(n, wi);
    float nDotWo = dot(n, wo);
    float hDotWi = dot(h, wi);
    float hDotWo = dot(h, wo);
    if (nDotWi == 0.0f || nDotWo == 0.0f || hDotWi == 0.0f || hDotWo == 0.0f) return {0.0f, 0.0f, 0.0f};
    
    float d = D(h, n, roughness);
    float g = G(wi, wo, n, roughness);
    float cosTheta = abs(hDotWo);
    float3 f0 = {0.04f, 0.04f, 0.04f};
    float3 f = F(cosTheta, f0);
    float3 transmissionFactor = 1.0f - f;

    float denomTerm = hDotWo + eta * hDotWi;
    float denominator = denomTerm * denomTerm * abs(nDotWo);
    if (denominator == 0.0f) return {0.0f, 0.0f, 0.0f};

    float3 numerator = (eta * eta) * d * g * transmissionFactor * abs(hDotWi) * abs(hDotWo);
    return numerator / denominator;
}

// BSDF combining Cook-Torrance BRDF and Walter et al. BTDF 
float3 f_s(float3 wi, float3 wo, float3 n, const device BaseMaterial& material, thread float& outPdf) {
    float transmission = 1.0f - material.diffuseColor.a;
    bool isTransmitting = transmission > 0.0f;

    float nDotWi = dot(n, wi);
    float nDotWo = dot(n, wo);
    bool sameSide = (nDotWi * nDotWo) > 0.0f;
    float roughness = max(material.roughness, 0.001f);

    if (sameSide) {
        float3 brdf = f_r(wi, wo, n, material);
        outPdf = max(nDotWi, 0.0f) / M_PI_F;
        return brdf;
    } else {
        if (!isTransmitting) {
            outPdf = 0.0f;
            return {0.0f, 0.0f, 0.0f};
        }

        bool entering = nDotWo > 0.0f;
        float iorIncident = entering ? 1.0f : (material.refractiveIndex > 0.0f ? material.refractiveIndex : 1.5f);
        float iorTransmitted = entering ? (material.refractiveIndex > 0.0f ? material.refractiveIndex : 1.5f) : 1.0f;
        float eta = iorIncident / iorTransmitted;

        float3 h = normalize(-(eta * wi + wo));
        float hDotWi = dot(h, wi);
        float hDotWo = dot(h, wo);
        
        // Walter et al. Transmission PDF
        float d = D(h, n, roughness);
        float denom = hDotWi + eta * hDotWo;
        outPdf = (d * abs(hDotWo) * eta * eta * abs(hDotWi)) / (denom * denom);

        float3 btdf = f_t(wi, wo, n, eta, roughness);
        return btdf * material.diffuseColor.rgb * transmission;
    }
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

        // Emission
        float3 emission = material.emissionColor.rgb;
        float maxEmission = max(emission.x, max(emission.y, emission.z));
        radiance += throughput * emission;
        if (maxEmission > 0.0f) {
            break;
        }

        float2 uv = meshTri.getInterpolatedUV(meshTri, result.barycentric);
       
        // Stochastic Dissolve Check for texture cut-outs
        if (material.dissolveTextureIndex != -1) {
            float dissolve = collection.textures[material.dissolveTextureIndex].sample(collection.samp, uv, gradient2d(0.0f, 0.0f)).a;
            if (random(rngState) > dissolve) {
                // To avoid intersecting the same triangle, nudge the ray a bit
                bounce--;
                ray.origin = result.getHit() + ray.direction * 1e-3; // making this number any smaller makes it get stuck in a loop when faces are nearly perpendicular to the camera
                continue;
            }
        }

        float4 texColor = make_float4(material.diffuseColor.rgb, 1.0f);
        texColor *= collection.textures[material.diffuseTextureIndex].sample(collection.samp, uv, gradient2d(0.0, 0.0));
        float3 albedo = mix(material.diffuseColor.rgb, texColor.rgb, texColor.a);

        // BSDF
        float3 sampleWeight = {1.0f, 1.0f, 1.0f};
        float ior = (material.refractiveIndex > 0.0f) ? material.refractiveIndex : 1.5f;
        bool isSmoothSpecular = material.roughness < 0.05f;

        float3 normal = meshTri.getInterpolatedNormal(meshTri, result.barycentric);
        float3 wi;
        float3 wo = -ray.direction;
        bool isTransmitting = (1.0f - material.diffuseColor.a) > 0.0f;

        if (isTransmitting) {
            bool entering = dot(normal, wo) > 0.0f;
            float3 correctNormal = entering ? normal : -normal;
            float eta = entering ? (1.0f / ior) : ior;

            // Compute Fresnel reflectance to stochastically choose Reflection vs Transmission (PBRT Dielectric)
            float cosi = abs(dot(correctNormal, wo));
            float fresnel = F(cosi, dielectricF0(entering ? ior : (1.0f / ior)));

            if (random(rngState) < fresnel) {
                // Specular Reflection
                wi = normalize(reflect(-wo, correctNormal));
                sampleWeight = make_float3(1.0f); // Energy conserved for pure dielectric reflection
            } else {
                // Transmission / Refraction
                float3 refracted = refract(-wo, correctNormal, eta);

                if (all(refracted == 0)) {
                    // Total Internal Reflection fallback
                    wi = normalize(reflect(-wo, correctNormal));
                    sampleWeight = make_float3(1.0f);
                } else {
                    wi = refracted;
                    // Scale throughput by albedo tint for colored glass
                    sampleWeight = albedo; 
                }
            }
        } else if (isSmoothSpecular || material.metallic > 0.5f) {
            wi = normalize(reflect(-wo, normal));
            float hDotV = max(dot(normalize(wi + wo), wo), 0.0f);
            float3 f0 = mix(make_float3(0.04f), albedo, material.metallic);
            sampleWeight = F(hDotV, f0);
        } else {
            // Diffuse / Rough Lambertian
            wi = sampleHemisphere(normal, float2(random2(rngState)));
            float pdf = max(dot(normal, wi), 0.0f) / M_PI_F;
            if (pdf < 0.0001f) break;

            float cosTheta = max(dot(normal, wi), 0.0f);
            sampleWeight = (albedo / M_PI_F) * cosTheta / pdf;
        }

        throughput *= sampleWeight;

        // Russian Roulette
        if (bounce >= 3) {
            float pCont = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95f);
            if (random(rngState) > pCont) break;
            throughput /= pCont;
        }

        // To prevent self-intersection, offset the ray slightly
        ray = Ray(result.getHit() + wi * 0.002f, wi);
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
