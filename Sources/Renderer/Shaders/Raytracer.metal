#include <metal_stdlib>
using namespace metal;

constant float epsilon = 1e-6;
constant float3 horizonColor = float3(207.0/255.0, 219.0/255.0, 230.0/255.0);
constant float3 zenithColor = float3(60.0/255.0, 138.0/255.0, 201.0/255.0);
constant float skyIntensity = 4.0;
constant float3 sunDirection = float3(0.0, 1.0, 0.0); // Note: the direction is inverted, technically it should be: -sunDirection
constant float3 sunColor = float3(10.0, 9.5, 8.5) * 0.5;
constant float sunIntensity = 256.0;
//constant float3 lightAngle = float3(0, -1, 0);
constant int maxLightBounces = 10;

struct Uniforms {
    int sampleIndex; // Which light-pass it is
    int headNodeIndex;
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
    Vertex vertex1;
    Vertex vertex2;
    Vertex vertex3;
    float3 edge1;
    float3 edge2;
    float3 normal;
    int materialIndex;
};

struct Material {
    float3 ambientColor;
    int ambientTextureIndex; // if -1 then no texture
    float dissolve;
};

struct TextureCollection {
    array<texture2d<float>, 128> textures;
};

struct SubMesh {
    int vertexOffset;
    int vertexCount;
    int faceOffset;
    int faceCount;
    int materialIndex;
};

struct BVHNode {
    float3 boundsMin;
    float3 boundsMax;
    int leftIndex;
    int rightIndex;
    int faceOffset;
    int faceCount;
};

struct RaycastResult {
    float3 hit;
    Face hitFace;
    float3 normal;
    int leafFaceIndex;
    float distance;
    float3 barycentric;
};

bool intersectsAABB(float3 origin, float3 invDirection, float3 min, float3 max) {
    float tmin = (min.x - origin.x) * invDirection.x;
    float tmax = (max.x - origin.x) * invDirection.x;
    if (tmin > tmax) { 
        float tmp = tmin;
        tmin = tmax;
        tmax = tmp;
    }
    
    float tymin = (min.y - origin.y) * invDirection.y;
    float tymax = (max.y - origin.y) * invDirection.y;
    if (tymin > tymax) { 
        float tmp = tymin;
        tymin = tymax;
        tymax = tmp; 
    }

    if (tmin > tymax || tymin > tmax) { return false; }

    if (tymin > tmin) { tmin = tymin; }
    if (tymax < tmax) { tmax = tymax; }

    float tzmin = (min.z - origin.z) * invDirection.z;
    float tzmax = (max.z - origin.z) * invDirection.z;
    if (tzmin > tzmax) { 
        float tmp = tzmin;
        tzmin = tzmax;
        tzmax = tmp;
    }

    if (tmin > tzmax || tzmin > tmax) { return false; }
    return true;
}

RaycastResult intersectsFace(float3 origin, float3 direction, Face face) {
    // Backface Culling, keeps CCW-wound triangles
    float3 normal = face.normal;
    if (dot(normal, direction) > 0) { return RaycastResult{ .distance = INFINITY, }; }

    float3 edge1 = face.edge1;
    float3 edge2 = face.edge2;
    float3 direction_cross_edge2 = cross(direction, edge2);
    float det = dot(edge1, direction_cross_edge2);
    if (metal::abs(det) < epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float inv_det = 1.0 / det;
    float3 vertex1 = face.vertex1.position;
    float3 s = origin - vertex1;
    float u = inv_det * dot(s, direction_cross_edge2);
    if (u < -epsilon || u - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float3 s_cross_edge1 = cross(s, edge1);
    float v = inv_det * dot(direction, s_cross_edge1);
    if (v < -epsilon || u + v - 1 > epsilon) { return RaycastResult{ .distance = INFINITY, }; }

    float t = inv_det * dot(edge2, s_cross_edge1);
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return RaycastResult{
            .hit = origin + direction * t, 
            .hitFace = face,
            .normal = normal, 
            .distance = t,
            .barycentric = float3(1.0-u-v, u, v)
        };
    }

    return RaycastResult { .distance = INFINITY };
}

RaycastResult traverseBVH(float3 origin, float3 look, int headNodeIndex, device Face* leafFaces, device BVHNode* bvhNodes) {
    int stack[64];
    int stackPtr = 0;
    stack[stackPtr++] = headNodeIndex;

    RaycastResult closestResult = RaycastResult{ .distance = INFINITY };

    float3 inverseLook = 1.0 / look;
    while (stackPtr > 0) {
        int nodeIndex = stack[--stackPtr];
        BVHNode node = bvhNodes[nodeIndex];

        if (!intersectsAABB(origin, inverseLook, node.boundsMin, node.boundsMax)) { continue; }

        for (int i = node.faceOffset; i < node.faceCount + node.faceOffset; ++i) {
            Face face = leafFaces[i];
            RaycastResult result = intersectsFace(origin, look, face);
            if (result.distance < closestResult.distance) {
                closestResult = result;
                closestResult.leafFaceIndex = i;
            }
        }

        if (node.leftIndex != -1) { stack[stackPtr++] = node.leftIndex; }
        if (node.rightIndex != -1) { stack[stackPtr++] = node.rightIndex; }
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

float hash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352d;
    x ^= x >> 15;
    x *= 0x846ca68b;
    x ^= x >> 16;
    return float(x) / 4294967295.0;
}

float random(float seed) {
    return hash(seed);
}

float2 random2(float seed) {
    return float2(hash(seed), hash(seed * 1.3247 + 13.37));
}

kernel void raytrace(
    texture2d<half, access::write> output [[texture(0)]], // Display Output
    texture2d<float, access::read_write> accumTexture [[texture(1)]], // Light passes
    sampler samp [[sampler(0)]],
    
    device Uniforms* uniforms [[buffer(0)]],
    device Material* materials [[buffer(1)]],
    device BVHNode* bvhNodes [[buffer(2)]],
    device Face* leafFaces [[buffer(3)]],
    device TextureCollection& collection [[buffer(4)]],
    
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) return;

    int sampleIndex = uniforms->sampleIndex;
    uint pixelX = gid.x;
    uint pixelY = gid.y;

    float seed = float(gid.x * 1973 + gid.y * 9277 + sampleIndex * 26699);
    float2 randXY = random2(seed);
    // Apply jitter: use 0.5 for the first frame, random offset for successive frames
    float offsetX = (uniforms->sampleIndex == 0) ? 0.5 : randXY.x;
    float offsetY = (uniforms->sampleIndex == 0) ? 0.5 : randXY.y;

    float ndcX = ((float)pixelX + offsetX) / (float)width * 2.0 - 1.0;
    float ndcY = 1.0 - (((float)pixelY + offsetY) / (float)height) * 2.0;
    float aspectRatio = (float)width / (float)height;
    float projectedX = ndcX * aspectRatio * uniforms->fovScale;
    float projectedY = ndcY * uniforms->fovScale;
    float3 look = normalize(uniforms->cameraForward + projectedX * uniforms->cameraRight + projectedY * uniforms->cameraUp);

    float3 radiance = float3(0.0, 0.0, 0.0);
    float3 throughput = float3(1.0, 1.0, 1.0);
    float3 rayOrigin = uniforms->cameraPosition;
    float3 rayDirection = look;
    for (uint bounce = 0; bounce < maxLightBounces; bounce++) {
        RaycastResult result = traverseBVH(rayOrigin, rayDirection, uniforms->headNodeIndex, leafFaces, bvhNodes);
        if (result.distance == INFINITY) {
            float t = 0.5 * (rayDirection.y + 1.0);
            float3 skyColor = mix(horizonColor, zenithColor, t);
            float sunAmount = pow(max(dot(rayDirection, sunDirection), 0.0), sunIntensity);
            radiance += throughput * (skyColor * skyIntensity + sunColor * sunAmount);
            break;
        }

        Material material = materials[result.hitFace.materialIndex];
        float3 albedo;

        if (material.ambientTextureIndex == -1) {
            albedo = material.ambientColor.xyz;
        } else {
            texture2d<float> tex = collection.textures[material.ambientTextureIndex];
            // Interpolated UV
            float2 uv = result.barycentric.x * result.hitFace.vertex1.uv + result.barycentric.y * result.hitFace.vertex2.uv + result.barycentric.z * result.hitFace.vertex3.uv;
            float4 texColor = tex.sample(samp, uv);
            albedo = mix(material.ambientColor.xyz, texColor.xyz, texColor.w); // Alpha Blend Texture with Material Color
        }

        // Interpolated Normal
        float3 normal = normalize(result.barycentric.x * result.hitFace.vertex1.normal + result.barycentric.y * result.hitFace.vertex2.normal + result.barycentric.z * result.hitFace.vertex3.normal);
        float normalDotLight = max(dot(normal, sunDirection), 0.0);
        if (normalDotLight > 0.0) {
            RaycastResult shadowResult = traverseBVH(result.hit + normal * 0.01, sunDirection, uniforms->headNodeIndex, leafFaces, bvhNodes);
            bool sunVisible = shadowResult.distance == INFINITY;
            if (sunVisible) radiance += throughput * albedo * sunColor * normalDotLight;
        }

        // Russian Roulette
        if (bounce > 3) { // This is for colors that are too dark and can be discarded, a nice optimisation basically
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05f, 0.95f);
            if (random(seed + bounce * 991.74) > p) break;
            throughput /= p;
        }

        throughput *= albedo;
        seed += float(bounce) * 143.137; 
        float2 bounceRand = random2(seed + float(bounce) * 12345.6789);
        if (dot(normal, rayDirection) > 0.0) normal = -normal;
        float3 bounceDirection = cosineWeightedHemisphere(normal, bounceRand);
        rayOrigin = result.hit + normal * 0.01; // Add tiny bit of normal so that the next bounce doesn't intersect with the same face
        rayDirection = bounceDirection;
    }

    float4 accumColor = float4(radiance.xyz, 1.0);
    if (sampleIndex > 0) {
        float4 prevColor = accumTexture.read(gid);
        accumColor += prevColor;
    }

    accumTexture.write(accumColor, gid);
    float3 averageColor = accumColor.xyz / float(sampleIndex + 1); // sampleIndex + 1 = sampleCount
    float3 toneMappedColor = 1.0 - exp(-averageColor);
    output.write(half4(half3(toneMappedColor.xyz), 1.0), gid);
}