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

struct Vertex {
    float3 position;
    float2 uv;
    float3 normal;
};

struct Face {
    Vertex vertex0;
    Vertex vertex1;
    Vertex vertex2;
    int materialIndex;
};

struct Material {
    //float3 ambientColor; // currently unused
    float3 diffuseColor;
    //float3 specularColor; // currently unused
    float3 emissionColor;
    //short ambientTextureIndex; // currently unused
    short diffuseTextureIndex; // -1 = no texture
    //short specularTextureIndex; // currently unused
    short dissolveTextureIndex;
    //short bumpTextureIndex; // currently unused
    // need to add a normalTexture too
    //short illuminationModel; // currently unused
    float dissolve;
    //float emissionIntensity;
    float roughness;
    float metallic;
    //float refractiveIndex; // IOR, currently unused
};

struct TextureCollection {
    sampler samp;
    array<texture2d<float>, 128> textures;
};


struct BLASNode { // For empty leafs, use min: +INFINITY and max: -INFINITY
    float4 minBoundsX; float4 minBoundsY; float4 minBoundsZ;
    float4 maxBoundsX; float4 maxBoundsY; float4 maxBoundsZ;
    int4 childIndices;
    int4 faceOffsets;
    int4 faceCounts;
};

struct TLASInstance {
    int blasStartIndex;
    float4x4 modelMatrix;
    float4x4 invModelMatrix;
    float3x3 invNormalMatrix;
};

struct TLASNode {
    float4 minBoundsX; float4 minBoundsY; float4 minBoundsZ;
    float4 maxBoundsX; float4 maxBoundsY; float4 maxBoundsZ;

    int4 childIndices;
    int4 tlasInstanceIndices;
};


struct RaycastResult {
    float3 hit;
    //float3 normal;
    float distance;
    float3 barycentric;
    int faceIndex;
    //int instanceIndex;
};

inline bool intersectsAABB(float3 origin, float3 invDirection, float3 minBounds, float3 maxBounds) {
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

    return tmin <= tmax && tmax > 0;
}

inline float4 intersects4AABBs(
    float3 origin, float3 invDirection, 
    float4 minBoundsX, float4 minBoundsY, float4 minBoundsZ, 
    float4 maxBoundsX, float4 maxBoundsY, float4 maxBoundsZ
) {
    float4 t1 = (minBoundsX - float4(origin.x)) * invDirection.x;
    float4 t2 = (maxBoundsX - float4(origin.x)) * invDirection.x;
    float4 tmin = fmin(t1, t2);
    float4 tmax = fmax(t1, t2);

    float4 ty1 = (minBoundsY - float4(origin.y)) * invDirection.y;
    float4 ty2 = (maxBoundsY - float4(origin.y)) * invDirection.y;
    tmin = fmax(tmin, fmin(ty1, ty2));
    tmax = fmin(tmax, fmax(ty1, ty2));

    float4 tz1 = (minBoundsZ - float4(origin.z)) * invDirection.z;
    float4 tz2 = (maxBoundsZ - float4(origin.z)) * invDirection.z;
    tmin = fmax(tmin, fmin(tz1, tz2));
    tmax = fmin(tmax, fmax(tz1, tz2));

    bool4 hitCondition = (tmin <= tmax) && (tmax > 0.0f);
    return select(float4(INFINITY), tmin, hitCondition);
}

inline float4 intersects4AABBsAndCloserThanRayHit(
    float3 origin, float3 invDirection, float t,
    float4 minBoundsX, float4 minBoundsY, float4 minBoundsZ, 
    float4 maxBoundsX, float4 maxBoundsY, float4 maxBoundsZ
) {
    float4 t1 = (minBoundsX - float4(origin.x)) * invDirection.x;
    float4 t2 = (maxBoundsX - float4(origin.x)) * invDirection.x;
    float4 tmin = fmin(t1, t2);
    float4 tmax = fmax(t1, t2);

    float4 ty1 = (minBoundsY - float4(origin.y)) * invDirection.y;
    float4 ty2 = (maxBoundsY - float4(origin.y)) * invDirection.y;
    tmin = fmax(tmin, fmin(ty1, ty2));
    tmax = fmin(tmax, fmax(ty1, ty2));

    float4 tz1 = (minBoundsZ - float4(origin.z)) * invDirection.z;
    float4 tz2 = (maxBoundsZ - float4(origin.z)) * invDirection.z;
    tmin = fmax(tmin, fmin(tz1, tz2));
    tmax = fmin(tmax, fmax(tz1, tz2));

    bool4 hitCondition = (tmin <= tmax) && (tmax > 0.0f) && (tmin < t);
    return select(float4(INFINITY), tmin, hitCondition);
}

inline RaycastResult intersectsFace(float3 origin, float3 direction, device const Face& face) {
    float3 vertex0 = face.vertex0.position;
    float3 edge1 = face.vertex1.position - vertex0;
    float3 edge2 = face.vertex2.position - vertex0;
     // Backface Culling, keeps CCW-wound triangles
    float3 normal = cross(edge1, edge2);
    if (dot(normal, direction) > 0) { return RaycastResult{ .distance = INFINITY, }; }

    float3 directionCrossEdge2 = cross(direction, edge2);
    float det = dot(edge1, directionCrossEdge2);
    if (abs(det) < epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float invDet = 1.0 / det;
    float3 s = origin - vertex0;
    float u = invDet * dot(s, directionCrossEdge2);
    if (u < -epsilon || u - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float3 sCrossEdge1 = cross(s, edge1);
    float v = invDet * dot(direction, sCrossEdge1);
    if (v < -epsilon || u + v - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float t = invDet * dot(edge2, sCrossEdge1);
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return RaycastResult{
            //.hit = origin + direction * t, 
            //.normal = normal, 
            .distance = t,
            .barycentric = float3(1.0-u-v, u, v),
        };
    }

    return RaycastResult { .distance = INFINITY };
}

inline float intersectsFaceDistance(float3 origin, float3 direction, device const Face& face) {
    float3 vertex0 = face.vertex0.position;
    float3 edge1 = face.vertex1.position - vertex0;
    float3 edge2 = face.vertex2.position - vertex0;
     // Backface Culling, keeps CCW-wound triangles
    float3 normal = cross(edge1, edge2);
    if (dot(normal, direction) > 0) { return INFINITY; }

    float3 directionCrossEdge2 = cross(direction, edge2);
    float det = dot(edge1, directionCrossEdge2);
    if (abs(det) < epsilon) { return INFINITY; }

    float invDet = 1.0 / det;
    float3 s = origin - vertex0;
    float u = invDet * dot(s, directionCrossEdge2);
    if (u < -epsilon || u - 1 > epsilon) { return INFINITY; }

    float3 sCrossEdge1 = cross(s, edge1);
    float v = invDet * dot(direction, sCrossEdge1);
    if (v < -epsilon || u + v - 1 > epsilon) { return INFINITY; }

    float t = invDet * dot(edge2, sCrossEdge1);
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return t;
    }

    return INFINITY;
}

inline void processBLASLeaf(float3 origin, float3 direction, device const BLASNode& node, thread RaycastResult& closest, int i, device const Face* faces) {
    int stop = node.faceCounts[i] + node.faceOffsets[i];
    for (int j = node.faceOffsets[i]; j < stop; ++j) {
        device const Face& face = faces[j];
        RaycastResult result = intersectsFace(origin, direction, face);
        if (result.distance < closest.distance) {
            result.faceIndex = j;
            closest = result;
        }
    }
}

// BVH4 Traversal
RaycastResult traverseBLAS(
    float3 origin, float3 direction, float3 invDirection,
    device const BLASNode* blasNodes, int blasStartIndex, device const Face* faces
) {
    int nodeIndex = blasStartIndex;
    uint stackPtr = 0;
    int stack[16];

    RaycastResult closest = RaycastResult { .distance = INFINITY };

    while (nodeIndex != -1) {
        device const BLASNode& node = blasNodes[nodeIndex];
        float4 hits = intersects4AABBs(
            origin, invDirection,
            node.minBoundsX, node.minBoundsY, node.minBoundsZ,
            node.maxBoundsX, node.maxBoundsY, node.maxBoundsZ
        );
        bool4 validHit = hits < float4(closest.distance);

        /*
        int child0 = node.childIndices[0]; float dist0 = hits[0];
        int child1 = node.childIndices[1]; float dist1 = hits[1];
        int child2 = node.childIndices[2]; float dist2 = hits[2];
        int child3 = node.childIndices[3]; float dist3 = hits[3];
        int i0 = 0, i1 = 1, i2 = 2, i3 = 3;

        // Swapping does not seem to improve performance, it only adds ~30ms 
        #define SWAP(a, b, t_a, t_b, i_a, i_b) if (a > b) { float temp = a; a = b; b = temp; int temp_t = t_a; t_a = t_b; t_b = temp_t; int temp_i = i_a; i_a = i_b; i_b = temp_i; }
        SWAP(dist0, dist1, child0, child1, i0, i1);
        SWAP(dist2, dist3, child2, child3, i2, i3);
        SWAP(dist0, dist2, child0, child2, i0, i2);
        SWAP(dist1, dist3, child1, child3, i1, i3);
        SWAP(dist1, dist2, child1, child2, i1, i2);
        #undef SWAP

        if (validHit[0]) {
            if (child0 == -1) processBLASLeaf(origin, direction, node, closest, i0, faces); 
            else stack[stackPtr++] = child0;
        }
        if (validHit[1]) {
            if (child1 == -1) processBLASLeaf(origin, direction, node, closest, i1, faces); 
            else stack[stackPtr++] = child1;
        }
        if (validHit[2]) {
            if (child2 == -1) processBLASLeaf(origin, direction, node, closest, i2, faces); 
            else stack[stackPtr++] = child2;
        }
        if (validHit[3]) {
            if (child3 == -1) processBLASLeaf(origin, direction, node, closest, i3, faces); 
            else stack[stackPtr++] = child3;
        }*/

        int child0 = node.childIndices[0];
        if (validHit[0]) {
            if (child0 == -1) processBLASLeaf(origin, direction, node, closest, 0, faces); 
            else stack[stackPtr++] = child0;
        }
        int child1 = node.childIndices[1];
        if (validHit[1]) {
            if (child1 == -1) processBLASLeaf(origin, direction, node, closest, 1, faces); 
            else stack[stackPtr++] = child1;
        }
        int child2 = node.childIndices[2];
        if (validHit[2]) {
            if (child2 == -1) processBLASLeaf(origin, direction, node, closest, 2, faces); 
            else stack[stackPtr++] = child2;
        }
        int child3 = node.childIndices[3];
        if (validHit[3]) {
            if (child3 == -1) processBLASLeaf(origin, direction, node, closest, 3, faces); 
            else stack[stackPtr++] = child3;
        }

        nodeIndex = (stackPtr != 0) ? stack[--stackPtr] : -1;
    }

    closest.hit = origin + direction * closest.distance;

    return closest;
}

// BVH4 Traversal
RaycastResult traverseTLAS(
    float3 origin, float3 direction, float3 invDirection, 
    device const TLASNode* tlasNodes, device const TLASInstance* tlasInstances, 
    device const BLASNode* blasNodes, device const Face* faces
) {
    int nodeIndex = 0;
    uint stackPtr = 0;
    int stack[16];

    RaycastResult closest = RaycastResult { .distance = INFINITY };

    while (nodeIndex != -1) {
        device const TLASNode& node = tlasNodes[nodeIndex];
        float4 hits = intersects4AABBsAndCloserThanRayHit(
            origin, invDirection, closest.distance,
            node.minBoundsX, node.minBoundsY, node.minBoundsZ,
            node.maxBoundsX, node.maxBoundsY, node.maxBoundsZ
        );

        float4 origin4 = float4(origin, 1.0);
        float4 direction4 = float4(direction, 0.0);

        for (int i = 0; i < 4; i++) {
            float hit = hits[i];
            if (hit == INFINITY) continue;

            if (node.childIndices[i] == -1) { // is the hit a Leaf
                int instanceIndex = node.tlasInstanceIndices[i];

                if (instanceIndex != -1) {
                    device const TLASInstance& tlasInstance = tlasInstances[instanceIndex];
                    float3 localOrigin = (tlasInstance.invModelMatrix * origin4).xyz;
                    float3 localDirection = normalize((tlasInstance.invModelMatrix * direction4).xyz);
                    float3 localInvDirection = 1.0 / localDirection;
                    RaycastResult result = traverseBLAS(
                        localOrigin, localDirection, localInvDirection,
                        blasNodes, tlasInstance.blasStartIndex, faces
                    );

                    if (result.distance != INFINITY) {
                        float3 worldHit = (tlasInstance.modelMatrix * float4(result.hit, 1)).xyz;
                        result.distance = length(worldHit - origin);

                        if (result.distance < closest.distance) {
                            result.hit = worldHit;
                            //result.normal = normalize(tlasInstance.invNormalMatrix * result.normal);
                            //result.instanceIndex = instanceIndex;
                            closest = result;
                        }
                    }               
                } 
            } else { // Branch Node
                stack[stackPtr++] = node.childIndices[i];
            }
        }

        nodeIndex = -1;
        if (stackPtr != 0) {
            nodeIndex = stack[--stackPtr];
        }
    }

    return closest;
}

bool shadowTraverseBLAS(
    float3 origin, float3 direction, float3 invDirection,
    device const BLASNode* blasNodes, int blasStartIndex, device const Face* faces
) {
    int nodeIndex = blasStartIndex;
    uint stackPtr = 0;
    int stack[16];

    while (nodeIndex != -1) {
        device const BLASNode& node = blasNodes[nodeIndex];
        float4 hits = intersects4AABBs(
            origin, invDirection,
            node.minBoundsX, node.minBoundsY, node.minBoundsZ,
            node.maxBoundsX, node.maxBoundsY, node.maxBoundsZ
        );

        for (int i = 0; i < 4; i++) {
            if (hits[i] == INFINITY) continue;
            int child = node.childIndices[i];
            
            if (child == -1) {
                // Leaf: check triangles
                int stop = node.faceCounts[i] + node.faceOffsets[i];
                for (int j = node.faceOffsets[i]; j < stop; ++j) {
                    if (intersectsFaceDistance(origin, direction, faces[j]) != INFINITY) {
                        return true;
                    }
                }
            } else {
                stack[stackPtr++] = child;
            }
        }
        nodeIndex = (stackPtr != 0) ? stack[--stackPtr] : -1;
    }

    return false;
}

bool shadowTraverseTLAS(
    float3 origin, float3 direction, float3 invDirection, 
    device const TLASNode* tlasNodes, device const TLASInstance* tlasInstances, 
    device const BLASNode* blasNodes, device const Face* faces
) {
    int nodeIndex = 0;
    uint stackPtr = 0;
    int stack[16];

    while (nodeIndex != -1) {
        device const TLASNode& node = tlasNodes[nodeIndex];
        float4 hits = intersects4AABBs(
            origin, invDirection,
            node.minBoundsX, node.minBoundsY, node.minBoundsZ,
            node.maxBoundsX, node.maxBoundsY, node.maxBoundsZ
        );

        float4 origin4 = float4(origin, 1.0);
        float4 direction4 = float4(direction, 0.0);

        for (int i = 0; i < 4; i++) {
            if (hits[i] == INFINITY) continue;

            if (node.childIndices[i] == -1) { // is the hit a Leaf
                int instanceIndex = node.tlasInstanceIndices[i];

                if (instanceIndex != -1) {
                    device const TLASInstance& tlasInstance = tlasInstances[instanceIndex];
                    float3 localOrigin = (tlasInstance.invModelMatrix * origin4).xyz;
                    float3 localDirection = normalize((tlasInstance.invModelMatrix * direction4).xyz);
                    float3 localInvDirection = 1.0 / localDirection;
                    if (shadowTraverseBLAS(localOrigin, localDirection, localInvDirection, blasNodes, tlasInstance.blasStartIndex, faces)) {
                        return true;
                    }
                } 
            } else { // Branch Node
                stack[stackPtr++] = node.childIndices[i];
            }
        }

        nodeIndex = -1;
        if (stackPtr != 0) {
            nodeIndex = stack[--stackPtr];
        }
    }

    return false;
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
    texture2d<half, access::write> output [[texture(0)]], // display output
    texture2d<float, access::read> lastAccumTexture [[texture(1)]], // Light passes
    texture2d<float, access::write> accumTexture [[texture(2)]],
    
    device const Uniforms* uniforms [[buffer(0)]],
    device const Material* materials [[buffer(1)]],
    device const TLASNode* tlasNodes [[buffer(2)]],
    device const TLASInstance* tlasInstances [[buffer(3)]],
    device const BLASNode* blasNodes [[buffer(4)]],
    //device const Face* faces [[buffer(5)]],
    device const Face* faces [[buffer(5)]],
    device const TextureCollection& collection [[buffer(6)]],
    
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) return;

    int sampleIndex = uniforms->sampleIndex;
    uint pixelX = gid.x;
    uint pixelY = gid.y;

    // Apply jitter: use 0.5 for the first frame, random offset for frames afterwards
    uint rngState = pixelX * 1973 + pixelY * 9277 + sampleIndex * 26699;
    float2 randXY = random2(rngState);
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

        device const Face& hitFace = faces[result.faceIndex];
        device const Material& material = materials[hitFace.materialIndex];

        // Emissive Materials
        radiance += throughput * material.emissionColor.rgb;
        if (material.emissionColor.r + material.emissionColor.g + material.emissionColor.b != 0) {
            break;
        }

        // Stochastic Dissolve Check
        if (random(rngState) > material.dissolve) {
            // To avoid intersecting the same triangle, nudge the ray a bit
            bounce--;
            rayOrigin = result.hit + rayDirection * 1e-3; // Too small numbers like 1e-6 don't work
            continue; // Force the bounce loop to continue using the exact same direction, bypassing all lighting math, albedo sampling, and throughput loss.
        }

        // Interpolated UV
        float3 albedo;
        float3 normal;
        {
            float2 uv = result.barycentric.x * hitFace.vertex0.uv + result.barycentric.y * hitFace.vertex1.uv + result.barycentric.z * hitFace.vertex2.uv;
            if (material.dissolveTextureIndex != -1 && collection.textures[material.dissolveTextureIndex].sample(collection.samp, uv, gradient2d(0.0, 0.0)).a < 0.01f) {
                bounce--;
                rayOrigin = result.hit + rayDirection * 0.01f;
                continue; // Should not be consired a hit as there is no visible pixel, continue where left off
            }

            float4 texColor = float4(material.diffuseColor.rgb, 1.0f);
            if (material.diffuseTextureIndex != -1) {
                texColor *= collection.textures[material.diffuseTextureIndex].sample(collection.samp, uv, gradient2d(0.0, 0.0));
            }

            albedo = mix(material.diffuseColor.rgb, texColor.rgb, texColor.a);
            // In future, if not smooth shading, use result.normal, but don't forget that result.normal is not normalized
            normal = normalize(result.barycentric.x * hitFace.vertex0.normal + result.barycentric.y * hitFace.vertex1.normal + result.barycentric.z * hitFace.vertex2.normal);
            if (dot(normal, rayDirection) > 0.0) normal = -normal;
        }

        // Fresnel
        // Non-metals (dielectrics) reflect ~4% white light. Metals reflect their albedo tint.
        // Calculate base specular reflectivity (F0)
        float specularProbability;
        float3 F0;
        float3 F;
        {
            F0 = mix(float3(0.04), albedo, material.metallic);
            float cosTheta = clamp(dot(-rayDirection, normal), 0.0, 1.0);
            float3 maxFresnelAtEdge = max(float3(1.0 - material.roughness), F0); 
            float base = 1.0 - cosTheta;
            float baseSquared = base * base;
            F = F0 + (maxFresnelAtEdge - F0) * (baseSquared * baseSquared * base); // pow(base, 5.0)

            // Calculate scalar probability for path selection via luminance conversion
            specularProbability = clamp(0.2126 * F.r + 0.7152 * F.g + 0.0722 * F.b, 0.01, 0.99);
        }

        // Next Event Estimation
        float normalDotLight = max(dot(normal, sunDirection), 0.0);
        if (normalDotLight > 0.0) {
            bool inShadow = shadowTraverseTLAS(result.hit + normal * epsilon, sunDirection, invSunDirection, tlasNodes, tlasInstances, blasNodes, faces);
            if (!inShadow) {
                // Compute the Fresnel response relative to the incoming light vector
                float cosThetaLight = clamp(dot(sunDirection, normal), 0.0, 1.0);
                float base = clamp(1.0 - cosThetaLight, 0.0, 1.0);
                float baseSquared = base * base;
                float3 F_Light = F0 + (float3(1.0) - F0) * (baseSquared * baseSquared * base); // pow(base, 5.0)
                
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
            if (random(rngState) > p) break;
            throughput /= p;
        }

        // --- INDIRECT SURFACE SCATTERING & PATH SELECTION ---
        rayOrigin = result.hit + normal * epsilon; 
        float2 bounceRand = random2(rngState);

        if (random(rngState) < specularProbability) { // Specular
            // (GGX Importance Sampling)
            // Clamp roughness slightly to prevent division-by-zero on smooth mirrors
            float roughness = max(material.roughness, 0.001f);
            
            // Generate a microfacet normal oriented matching GGX distribution profile
            float3 halfwayVector = sampleGGX(bounceRand, roughness, normal);
            
            rayDirection = reflect(rayDirection, halfwayVector);

            // Back-face reflection safety check
            if (dot(normal, rayDirection) < 0.0) {
                rayDirection = rayDirection - 2.0 * dot(rayDirection, normal) * normal;
            }

            // Weight updates through calculated Fresnel energy split
            throughput *= F / specularProbability;
        } else { // Diffuse
            rayDirection = cosineWeightedHemisphere(normal, bounceRand);
            
            // Core Lambertian diffuse energy weight calculation
            float3 diffuseWeight = albedo * (float3(1.0) - F) * (1.0 - material.metallic);
            throughput *= diffuseWeight / (1.0 - specularProbability);
        }

        invRayDirection = 1.0 / rayDirection;
    }

    if (any(isnan(radiance)) || any(isinf(radiance))) {
        radiance = float3(0.0, 0.0, 0.0);
    }
    
    // This frame Color + previous frame Color
    float4 accumColor = float4(radiance.rgb, 1.0);
    if (sampleIndex > 0) {
        float4 prevColor = lastAccumTexture.read(gid);
        accumColor += prevColor;
    }

    accumTexture.write(accumColor, gid);
    float3 averageColor = accumColor.rgb / float(sampleIndex + 1); // sampleIndex + 1 = sampleCount
    float3 toneMappedColor = 1.0 - exp(-averageColor);
    output.write(half4(half3(toneMappedColor.rgb), 1.0), gid);
}