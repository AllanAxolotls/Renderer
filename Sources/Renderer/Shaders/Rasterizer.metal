#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float2 uv;
    float3 normal;
};

struct Material {
    float dissolve; // 1.0 = fully opaque, 0.0 = fully transparent
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
};

vertex VSOut vmain(
    const device Vertex* verts [[buffer(0)]],
    constant float4x4& transform [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VSOut out;
    out.position = transform * float4(verts[vid].position, 1.0f);
    out.uv = verts[vid].uv;
    out.normal = verts[vid].normal;
    return out;
}

fragment float4 fmain(
    VSOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]],
    constant Material& material [[buffer(2)]]
) {
    float4 texColor = tex.sample(samp, in.uv);
    float factor = (dot(in.normal, float3(0, 1, 0)) + 1.0) * 0.5;
    float3 shaded = texColor.rgb * (factor * 0.5 + 0.5);
    return float4(shaded, texColor.a * material.dissolve);
}