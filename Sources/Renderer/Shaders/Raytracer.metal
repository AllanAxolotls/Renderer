#include <metal_stdlib>
using namespace metal;

constant float epsilon = 1e-6;
constant half3 horizonColor = half3(207.0/255.0, 219.0/255.0, 230.0/255.0);
constant half3 zenithColor = half3(60.0/255.0, 138.0/255.0, 201.0/255.0);
constant float3 lightAngle = float3(0, -1, 0);

struct Uniforms {
    float fovScale;
    int headNodeIndex;
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
    //float3 normal;
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
    if (dot(normal, direction) > 0) { return RaycastResult{
        .distance = INFINITY,
    }; }

    float3 edge1 = face.edge1;
    float3 edge2 = face.edge2;
    float3 direction_cross_edge2 = cross(direction, edge2);
    float det = dot(edge1, direction_cross_edge2);
    if (metal::abs(det) < epsilon) { return RaycastResult{
        .distance = INFINITY,
    }; }

    float inv_det = 1.0 / det;
    float3 vertex1 = face.vertex1.position;
    float3 s = origin - vertex1;
    float u = inv_det * dot(s, direction_cross_edge2);
    if (u < -epsilon || u - 1 > epsilon) { return RaycastResult{
        .distance = INFINITY,
    }; }

    float3 s_cross_edge1 = cross(s, edge1);
    float v = inv_det * dot(direction, s_cross_edge1);
    if (v < -epsilon || u + v - 1 > epsilon) { return RaycastResult{
        .distance = INFINITY,
    }; }

    float t = inv_det * dot(edge2, s_cross_edge1);
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return RaycastResult{
            .hit = origin + direction * t, 
            .hitFace = face,
            //.normal = normal, 
            .distance = t,
            .barycentric = float3(1.0-u-v, u, v)
        };
    }

    return RaycastResult {
        .distance = INFINITY
    };
}

RaycastResult traverseBVH(float3 origin, float3 look, int headNodeIndex, device Face* leafFaces, device BVHNode* bvhNodes) {
    int stack[64];
    int stackPtr = 0;
    stack[stackPtr++] = headNodeIndex;

    RaycastResult closestResult = RaycastResult{
        .distance = INFINITY, 
    };

    float3 inverseLook = 1.0 / look;
    while (stackPtr > 0) {
        int nodeIndex = stack[--stackPtr];
        BVHNode node = bvhNodes[nodeIndex];

        if (!intersectsAABB(origin, inverseLook, node.boundsMin, node.boundsMax)) {
            continue;
        }

        for (int i = node.faceOffset; i < node.faceCount + node.faceOffset; ++i) {
            Face face = leafFaces[i];
            RaycastResult result = intersectsFace(origin, look, face);
            if (result.distance < closestResult.distance) {
                closestResult = result;
                closestResult.leafFaceIndex = i;
            }
        }

        if (node.leftIndex != -1) {
            stack[stackPtr++] = node.leftIndex;
        }
        if (node.rightIndex != -1) {
            stack[stackPtr++] = node.rightIndex;
        }
    }

    return closestResult;
}

kernel void raytrace(
    texture2d<half, access::write> output [[texture(0)]],
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

    if (gid.x >= width || gid.y >= height)
        return;

    uint pixelX = gid.x;
    uint pixelY = gid.y;
    float ndcX = ((float)pixelX + 0.5) / (float)width * 2.0 - 1.0;
    float ndcY = 1.0 - (((float)pixelY + 0.5) / (float)height) * 2.0;
    float aspectRatio = (float)width / (float)height;
    float projectedX = ndcX * aspectRatio * uniforms->fovScale;
    float projectedY = ndcY * uniforms->fovScale;
    float3 look = normalize(uniforms->cameraForward + projectedX * uniforms->cameraRight + projectedY * uniforms->cameraUp);

    // Raycast, Traverse BVH
    RaycastResult result = traverseBVH(uniforms->cameraPosition, look, uniforms->headNodeIndex, leafFaces, bvhNodes);

    if (result.distance == INFINITY) {
        float t = 0.5 * (look.y + 1.0);
        half3 color3 = (1.0 - t) * horizonColor + t * zenithColor;
        half4 color = half4(color3.xyz, 1.0);
        output.write(color, gid);
        return;
    }

    Vertex vertex1 = result.hitFace.vertex1;
    Vertex vertex2 = result.hitFace.vertex2;
    Vertex vertex3 = result.hitFace.vertex3;
    float3 normal1 = vertex1.normal;
    float3 normal2 = vertex2.normal;
    float3 normal3 = vertex3.normal;
    float2 uv1 = vertex1.uv;
    float2 uv2 = vertex2.uv;
    float2 uv3 = vertex3.uv;
    float3 interpolatedNormal = normalize(
        result.barycentric.x * normal1 +
        result.barycentric.y * normal2 +
        result.barycentric.z * normal3
    );
    
    float angleIntensity = fmax(0, dot(lightAngle, interpolatedNormal)) * 0.75;
    float lightIntensity = 1.25 - angleIntensity;
    if (angleIntensity == 0) {
        RaycastResult shadowResult = traverseBVH(result.hit + float3(0, 1000, 0), float3(0, -1.0, 0), uniforms->headNodeIndex, leafFaces, bvhNodes);
        float darkness = (shadowResult.distance != INFINITY) * (shadowResult.leafFaceIndex != result.leafFaceIndex) * 0.3;
        lightIntensity -= darkness;
    }
    
    Material material = materials[result.hitFace.materialIndex];

    if (material.ambientTextureIndex == -1) {
        output.write(half4(half3(material.ambientColor * lightIntensity), 1.0), gid);
        return;
    }

    texture2d<float> tex = collection.textures[material.ambientTextureIndex];
    float2 interpolatedUV = result.barycentric.x * uv1 + result.barycentric.y * uv2 + result.barycentric.z * uv3;
    half4 texColor = half4(tex.sample(samp, interpolatedUV));
    half3 alphaBlendedColor = texColor.xyz * texColor.w + half3(material.ambientColor.xyz) * (1.0 - texColor.w);
    output.write(half4(alphaBlendedColor * lightIntensity, 1.0), gid);
}