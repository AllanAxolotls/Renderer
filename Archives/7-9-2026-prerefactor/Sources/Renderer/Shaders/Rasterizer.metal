#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float3 normal;
    float2 uv;
};

struct MaterialData {
    float4 diffuseColor; // .w = dissolve
    float4 emissionColor; // .w = emissionIntensity
    float4 params; // .x=roughness, .y=metallic, .z=IOR, .w=bitflag (0=Normal, 1=isSky)
    short diffuseTextureIndex;
    short dissolveTextureIndex; // -1 = no texture
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
    texture2d<float> dissolveTex [[texture(1)]],
    sampler samp [[sampler(0)]],
    constant MaterialData& materialData [[buffer(2)]]
) {
    float4 albedo = materialData.diffuseColor * tex.sample(samp, in.uv);

    if (materialData.dissolveTextureIndex != -1) {
        albedo.a *= dissolveTex.sample(samp, in.uv).a;
    }

    if (albedo.a < 0.01f) {
        discard_fragment();
    }

    if (as_type<int>(materialData.params.w) == 1) return albedo;

    float3 n = normalize(in.normal);
    float lighting = clamp(dot(n, float3(0, 1, 0)) * 0.5f + 0.5f, 0.0f, 1.0f);
    float3 shaded = albedo.rgb * (0.5f + 0.5f * lighting);

    return float4(shaded, albedo.a);
}