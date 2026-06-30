#include <metal_stdlib>
using namespace metal;

constant float epsilon = 1e-6;
constant float3 horizonColor = float3(207.0/255.0, 219.0/255.0, 230.0/255.0);
constant float3 zenithColor = float3(60.0/255.0, 138.0/255.0, 201.0/255.0);
constant float skyIntensity = 4.0;
constant float3 sunDirection = float3(1.0, 0, 0.0); // Note: the direction is inverted, technically it should be: -sunDirection
constant float3 invSunDirection = 1.0 / sunDirection;
constant float3 sunColor = float3(10.0, 9.5, 8.5) * 0.5;
constant float sunIntensity = 256.0;
constant int maxLightBounces = 10;

struct Uniforms {
    int sampleIndex;
    int sphereLightCount;
    float fovScale;
    float3 cameraPosition;
    float3 cameraForward;
    float3 cameraUp;
    float3 cameraRight;
};

struct SphereLight {
    float3 position;
    float3 emission;
    float radius;
};

struct Vertex {
    float3 position;
    float2 uv;
    float3 normal;
};

struct Face {
    Vertex vertex1;
    Vertex vertex2;
    Vertex vertex3;
    float3 edge1;
    float3 edge2;
    float3 normal;
    int materialIndex;
};

struct Material {
    float3 ambientColor; // currently unused
    float3 diffuseColor;
    float3 specularColor; // currently unused
    float3 emissionColor;
    int ambientTextureIndex; // currently unused
    int diffuseTextureIndex; // -1 = no texture
    int specularTextureIndex; // currently unused
    int dissolveTextureIndex;
    int bumpTextureIndex; // currently unused
    // need to add a normalTexture too
    int illuminationModel; // currently unused
    float dissolve;
    float roughness;
    float metallic;
    float refractiveIndex; // IOR, currently unused
};

struct TextureCollection {
    array<texture2d<float>, 128> textures;
};

struct BLASNode {
    float3 minBounds;
    float3 maxBounds;
    int leftIndex;
    int escapeIndex;
    int faceOffset;
    int faceCount;
};

struct TLASInstance {
    int blasStartIndex;
    float4x4 modelMatrix;
    float4x4 invModelMatrix;
    float3x3 invNormalMatrix;
};

struct TLASNode {
    float3 minBounds;
    float3 maxBounds;
    int leftIndex;
    int escapeIndex;
    int instanceIndex; // TLAS Instance
};

struct RaycastResult {
    float3 hit;
    float3 normal;
    float distance;
    float3 barycentric;
    int faceIndex;
    int instanceIndex;
};

bool intersectsAABB(float3 origin, float3 invDirection, float3 minBounds, float3 maxBounds) {
    // X-axis slab
    float t1 = (minBounds.x - origin.x) * invDirection.x;
    float t2 = (maxBounds.x - origin.x) * invDirection.x;
    float tmin = fmin(t1, t2);
    float tmax = fmax(t1, t2);

    // Y-axis slab
    float ty1 = (minBounds.y - origin.y) * invDirection.y;
    float ty2 = (maxBounds.y - origin.y) * invDirection.y;
    tmin = fmax(tmin, fmin(ty1, ty2));
    tmax = fmin(tmax, fmax(ty1, ty2));

    // Z-axis slab
    float tz1 = (minBounds.z - origin.z) * invDirection.z;
    float tz2 = (maxBounds.z - origin.z) * invDirection.z;
    tmin = fmax(tmin, fmin(tz1, tz2));
    tmax = fmin(tmax, fmax(tz1, tz2));

    // The final overlap check: 
    // Returns true if the largest entry time is less than or equal to the earliest exit time
    return tmin <= tmax;
}

RaycastResult intersectsFace(float3 origin, float3 direction, Face face) {
    // Backface Culling, keeps CCW-wound triangles
    float3 normal = face.normal;
    if (dot(normal, direction) > 0) { return RaycastResult{ .distance = INFINITY, }; }

    float3 edge1 = face.edge1;
    float3 edge2 = face.edge2;
    float3 directionCrossEdge2 = cross(direction, edge2);
    float det = dot(edge1, directionCrossEdge2);
    if (abs(det) < epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float invDet = 1.0 / det;
    float3 vertex1 = face.vertex1.position;
    float3 s = origin - vertex1;
    float u = invDet * dot(s, directionCrossEdge2);
    if (u < -epsilon || u - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float3 sCrossEdge1 = cross(s, edge1);
    float v = invDet * dot(direction, sCrossEdge1);
    if (v < -epsilon || u + v - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float t = invDet * dot(edge2, sCrossEdge1);
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return RaycastResult{
            .hit = origin + direction * t, 
            .normal = normal, 
            .distance = t,
            .barycentric = float3(1.0-u-v, u, v),
        };
    }

    return RaycastResult { .distance = INFINITY };
}

// BVH traversal, Bottom Level Acceleration Structure
RaycastResult traverseBLAS(
    float3 origin, float3 look, float3 inverseLook,
    device BLASNode* blasNodes, int blasStartIndex,
    device Face* faces
) {
    RaycastResult closestResult = RaycastResult{ .distance = INFINITY };
    int nodeIndex = blasStartIndex;

    while (nodeIndex != -1) {
        BLASNode node = blasNodes[nodeIndex];
        if (intersectsAABB(origin, inverseLook, node.minBounds, node.maxBounds) ) {
            if (node.leftIndex == -1) { // if it's a leaf
                for (int i = node.faceOffset; i < node.faceCount + node.faceOffset; ++i) {
                    Face face = faces[i];
                    RaycastResult result = intersectsFace(origin, look, face);
                    if (result.distance < closestResult.distance) {
                        result.faceIndex = i;
                        closestResult = result;
                    }
                }
                nodeIndex = node.escapeIndex;
            } else {
                nodeIndex = node.leftIndex;
            }
        } else {
            nodeIndex = node.escapeIndex;
        }
    }
    return closestResult;
}

// Top Level Acceleration Structure
RaycastResult traverseTLAS(
    float3 origin, float3 look, float3 inverseLook,
    device TLASNode* tlasNodes, device TLASInstance* instances, 
    device BLASNode* blasNodes, device Face* faces
) {
    RaycastResult closestResult = RaycastResult{ .distance = INFINITY };
    int nodeIndex = 0;
    while (nodeIndex != -1) {
        TLASNode node = tlasNodes[nodeIndex];
        if (intersectsAABB(origin, inverseLook, node.minBounds, node.maxBounds)) {
            if (node.leftIndex == -1) { // if it's a leaf
                TLASInstance instance = instances[node.instanceIndex];
                float3 localOrigin = (instance.invModelMatrix * float4(origin, 1)).xyz;
                float3 localLook = normalize((instance.invModelMatrix * float4(look, 0)).xyz);
                float3 localInverseLook = 1.0 / localLook;
                RaycastResult result = traverseBLAS(localOrigin, localLook, localInverseLook, blasNodes, instance.blasStartIndex, faces);

                if (result.distance != INFINITY) {
                    float3 worldHit = (instance.modelMatrix * float4(result.hit, 1)).xyz;
                    result.distance = length(worldHit - origin);
                   
                    if (result.distance < closestResult.distance) {
                        result.hit = worldHit;
                        result.normal = normalize(instance.invNormalMatrix * result.normal);
                        result.instanceIndex = node.instanceIndex;
                        closestResult = result;
                    }
                }
                nodeIndex = node.escapeIndex;
            } else {
                nodeIndex = node.leftIndex;
            }
        } else {
            nodeIndex = node.escapeIndex;
        }
    }
    return closestResult;
}


float3 cosineWeightedHemisphere(float3 normal, float2 rand) {
    float phi = 2.0 * M_PI_F * rand.x;
    float r = sqrt(rand.y);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = sqrt(1.0 - rand.y);
    float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    return normalize(tangent * x + bitangent * y + normal * z);
}

uint nextRandom(thread uint& state) {
    state = state * 747796405 + 2891336453;
    uint result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
    result = (result >> 22) ^ result;
    return result;
}

float random(thread uint& state) {
    return nextRandom(state) / 4294967295.0; // 2^32 - 1
}

float2 random2(thread uint& seed) {
    return float2(random(seed), random(seed));
}

// Generates a local coordinate system (Tangent, Bitangent) from a Normal
void getTangentSpace(float3 normal, thread float3& tangent, thread float3& bitangent) {
    float3 helper = abs(normal.x) > 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
    tangent = normalize(cross(normal, helper));
    bitangent = cross(normal, tangent);
}

// Samples a microfacet normal (Halfway vector H) according to the GGX distribution
float3 sampleGGX(float2 randVal, float roughness, float3 normal) {
    float a = roughness * roughness; // Disney reparameterization
    float phi = 2.0 * M_PI_F * randVal.x;
    
    // GGX distribution sampling equations
    float cosTheta = sqrt(clamp((1.0 - randVal.y) / (1.0 + (a * a - 1.0) * randVal.y), 0.0, 1.0));
    float sinTheta = sqrt(clamp(1.0 - cosTheta * cosTheta, 0.0, 1.0));
    
    // Transform from spherical to local Cartesian coordinates
    float3 localH = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    
    // Orient local H into world space relative to the normal
    float3 tangent, bitangent;
    getTangentSpace(normal, tangent, bitangent);
    return normalize(tangent * localH.x + bitangent * localH.y + normal * localH.z);
}

kernel void raytrace(
    //texture2d<half, access::write> output [[texture(0)]], // Display Output
    texture2d<half, access::write> output [[texture(0)]], // noisy texture output
    texture2d<float, access::read_write> accumTexture [[texture(1)]], // Light passes
    sampler samp [[sampler(0)]],
    
    device Uniforms* uniforms [[buffer(0)]],
    device Material* materials [[buffer(1)]],
    device TLASNode* tlasNodes [[buffer(2)]],
    device TLASInstance* tlasInstances [[buffer(3)]],
    device BLASNode* blasNodes [[buffer(4)]],
    device Face* faces [[buffer(5)]],
    device TextureCollection& collection [[buffer(6)]],
    device SphereLight* sphereLights [[buffer(7)]],
    
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) return;

    int sampleIndex = uniforms->sampleIndex;
    uint pixelX = gid.x;
    uint pixelY = gid.y;

    // Apply jitter: use 0.5 for the first frame, random offset for successive frames
    uint seed = pixelX * 1973 + pixelY * 9277 + sampleIndex * 26699;
    float2 randXY = random2(seed);
    float offsetX = (uniforms->sampleIndex == 0) ? 0.5 : randXY.x;
    float offsetY = (uniforms->sampleIndex == 0) ? 0.5 : randXY.y;

    float ndcX = ((float)pixelX + offsetX) / (float)width * 2.0 - 1.0;
    float ndcY = 1.0 - (((float)pixelY + offsetY) / (float)height) * 2.0;
    float aspectRatio = (float)width / (float)height;
    float projectedX = ndcX * aspectRatio * uniforms->fovScale;
    float projectedY = ndcY * uniforms->fovScale;

    float3 radiance = float3(0.0, 0.0, 0.0); // Recieved Light
    float3 throughput = float3(1.0, 1.0, 1.0); // Which colors get filtered out or not
    float3 rayOrigin = uniforms->cameraPosition;
    float3 rayDirection = normalize(uniforms->cameraForward + projectedX * uniforms->cameraRight + projectedY * uniforms->cameraUp);
    float3 invRayDirection = 1.0 / rayDirection;

    int sphereLightCount = uniforms->sphereLightCount; 

    for (uint bounce = 0; bounce < maxLightBounces; bounce++) {
        // Raycast
        RaycastResult result = traverseTLAS(rayOrigin, rayDirection, invRayDirection, tlasNodes, tlasInstances, blasNodes, faces);
        
        // Sky
        if (result.distance == INFINITY) {
            float t = 0.5 * (rayDirection.y + 1.0);
            float3 skyColor = mix(horizonColor, zenithColor, t);
            float sunAmount = pow(max(dot(rayDirection, sunDirection), 0.0), sunIntensity);
            radiance += throughput * (skyColor * skyIntensity + sunColor * sunAmount);
            break;
        }

        Face hitFace = faces[result.faceIndex];
        Material material = materials[hitFace.materialIndex];

        // Emissive Materials
        if (length(material.emissionColor.rgb) > epsilon) {
            radiance += throughput * material.emissionColor.rgb;
            break;
        }

        // Stochastic Dissolve Check
        if (random(seed) > material.dissolve) {
            // To avoid intersecting the same triangle, nudge the ray a bit
            rayOrigin = result.hit + rayDirection * epsilon;
            continue; // Force the bounce loop to continue using the exact same direction, bypassing all lighting math, albedo sampling, and throughput loss.
        }

        // Raycast Hit Color
        float3 albedo;
        if (material.diffuseTextureIndex == -1) {
            albedo = material.diffuseColor.rgb;
        } else {
            // Interpolated UV
            float2 uv = result.barycentric.x * hitFace.vertex1.uv + result.barycentric.y * hitFace.vertex2.uv + result.barycentric.z * hitFace.vertex3.uv;
            float pixelDissolve = material.dissolveTextureIndex == -1 ? material.dissolve : 
                collection.textures[material.dissolveTextureIndex].sample(samp, uv).a;

            // Weird logic for dissolve, might need to change in the future
            if (pixelDissolve < 0.01f) {
                bounce--;
                rayOrigin = result.hit + rayDirection * 0.01f;
                continue; // Should not be consired a hit as there is no visible pixel, continue where left off
            }
            texture2d<float> tex = collection.textures[material.diffuseTextureIndex];
            float4 texColor = tex.sample(samp, uv);
            albedo = mix(material.diffuseColor.rgb, texColor.rgb, texColor.a); // Alpha Blend Texture with Material Color
        }

        
        float3 normal = normalize(result.barycentric.x * hitFace.vertex1.normal + result.barycentric.y * hitFace.vertex2.normal + result.barycentric.z * hitFace.vertex3.normal);
        if (dot(normal, rayDirection) > 0.0) normal = -normal;

        // Fresnel
        // Non-metals (dielectrics) reflect ~4% white light. Metals reflect their albedo tint.
        // Calculate base specular reflectivity (F0)
        float3 F0 = mix(float3(0.04), albedo, material.metallic);
        float cosTheta = clamp(dot(-rayDirection, normal), 0.0, 1.0);
        float3 maxFresnelAtEdge = max(float3(1.0 - material.roughness), F0); 
        float3 F = F0 + (maxFresnelAtEdge - F0) * pow(1.0 - cosTheta, 5.0);

        // Calculate scalar probability for path selection via luminance conversion
        float specularProbability = clamp(0.2126 * F.r + 0.7152 * F.g + 0.0722 * F.b, 0.01, 0.99);

        // Next Event Estimation
        float normalDotLight = max(dot(normal, sunDirection), 0.0);
        if (normalDotLight > 0.0) {
            RaycastResult shadowResult = traverseTLAS(result.hit + normal * epsilon, sunDirection, invSunDirection, tlasNodes, tlasInstances, blasNodes, faces);
            bool sunVisible = shadowResult.distance == INFINITY;
            if (sunVisible) {
                // Compute the Fresnel response relative to the incoming light vector
                float cosThetaLight = clamp(dot(sunDirection, normal), 0.0, 1.0);
                float3 F_Light = F0 + (float3(1.0) - F0) * pow(clamp(1.0 - cosThetaLight, 0.0, 1.0), 5.0);
                
                // Direct light split: White specular highlight vs colored diffuse reflection
                float3 directSpecular = F_Light; 
                float3 directDiffuse = albedo * (float3(1.0) - F_Light) * (1.0 - material.metallic);
                
                radiance += throughput * (directDiffuse + directSpecular) * sunColor * normalDotLight;
            }
        }

        // Russian Roulette
        if (bounce > 3) { // This is for colors that are too dark and can be discarded, a nice optimisation basically
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05f, 0.95f);
            if (random(seed) > p) break;
            throughput /= p;
        }

        // --- INDIRECT SURFACE SCATTERING & PATH SELECTION ---
        rayOrigin = result.hit + normal * epsilon; 
        float2 bounceRand = random2(seed);

        if (random(seed) < specularProbability) {
            // 1. SPECULAR ROUTE (GGX Importance Sampling)
            // Clamp roughness slightly to prevent division-by-zero on smooth mirrors
            float roughness = max(material.roughness, 0.001f);
            
            // Generate a microfacet normal oriented matching GGX distribution profile
            float3 halfwayVector = sampleGGX(bounceRand, roughness, normal);
            
            // Reflect incoming ray over the microfacet normal
            rayDirection = reflect(rayDirection, halfwayVector);

            // Back-face reflection safety check
            if (dot(normal, rayDirection) < 0.0) {
                rayDirection = rayDirection - 2.0 * dot(rayDirection, normal) * normal;
            }

            // Weight updates through calculated Fresnel energy split
            throughput *= F / specularProbability;
        } else {
            // 2. DIFFUSE ROUTE (Cosine Weighted Hemisphere)
            rayDirection = cosineWeightedHemisphere(normal, bounceRand);
            
            // Core Lambertian diffuse energy weight calculation
            float3 diffuseWeight = albedo * (float3(1.0) - F) * (1.0 - material.metallic);
            throughput *= diffuseWeight / (1.0 - specularProbability);
        }

        invRayDirection = 1.0 / rayDirection;
    }

    // This frame Color + previous frame Color
    float4 accumColor = float4(radiance.rgb, 1.0);
    if (sampleIndex > 0) {
        float4 prevColor = accumTexture.read(gid);
        accumColor += prevColor;
    }

    accumTexture.write(accumColor, gid);
    float3 averageColor = accumColor.rgb / float(sampleIndex + 1); // sampleIndex + 1 = sampleCount
    float3 toneMappedColor = 1.0 - exp(-averageColor);
    output.write(half4(half3(toneMappedColor.rgb), 1.0), gid);
}