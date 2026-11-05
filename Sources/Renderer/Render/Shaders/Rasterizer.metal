#include <metal_stdlib>
using namespace metal;

#define DISPLAY_NORMAL false

#include "Vertex.hpp"
#include "BaseMaterial.hpp"

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
    texture2d<float> diffuseTexture [[texture(0)]],
    texture2d<float> dissolveTexture [[texture(1)]],
    sampler samp [[sampler(0)]],
    constant BaseMaterial& material [[buffer(2)]]
) {
    if (DISPLAY_NORMAL) {
        return float4(in.normal * 0.5f + 0.5f, 1.0f);
    }

    float4 albedo = material.diffuseColor * diffuseTexture.sample(samp, in.uv);

    if (material.dissolveTextureIndex != -1) {
        albedo.a *= dissolveTexture.sample(samp, in.uv).a;
    }

    // Alpha Masking/Discarding
    if (albedo.a < 0.01f) {
        discard_fragment();
    }

    if (materialHasFlag(material, MaterialFlag_IsSky)) return albedo;

    float3 n = normalize(in.normal);
    float lighting = clamp( dot(n, float3(0, 1, 0)) * 0.5f + 0.5f, 0.0f, 1.0f );
    float3 shaded = albedo.rgb * (0.5f + 0.5f * lighting);

    return float4(shaded, albedo.a);
}