#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float2 uv;
    float3 normal;
};

struct Material {
    float3 ambientColor;
    float3 diffuseColor;
    float3 specularColor;
    float3 emissionColor;
    int ambientTextureIndex;
    int diffuseTextureIndex; // -1 = no texture
    int specularTextureIndex;
    int dissolveTextureIndex;
    int bumpTextureIndex;
    int illuminationModel;
    float dissolve;
    float specularExponent;
    float refractiveIndex;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
};

struct Uniforms {
    float4x4 mvpMatrix;
    float3x3 normalMatrix;
};

vertex VSOut vmain(
    const device Vertex* verts [[buffer(0)]],
    const device Uniforms* uniforms [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VSOut out;
    out.position = uniforms->mvpMatrix * float4(verts[vid].position, 1.0f);
    out.uv = verts[vid].uv;
    out.normal = uniforms->normalMatrix * verts[vid].normal;
    return out;
}

fragment float4 fmain(
    VSOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]],
    constant Material& material [[buffer(2)]]
) {
    float4 albedo = material.diffuseTextureIndex == -1 ? float4(material.diffuseColor, 1.0f) : float4(material.diffuseColor, 1.0) * tex.sample(samp, in.uv);
    float factor = (dot(in.normal, float3(0, 1, 0)) + 1.0) * 0.5f;
    float3 shaded = albedo.rgb * (factor * 0.5 + 0.5);
    return float4(shaded, albedo.a * material.dissolve);
}