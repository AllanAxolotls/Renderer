#include <metal_stdlib>
using namespace metal;

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    float2 uvs[3] = {float2(0,1), float2(2,1), float2(0,-1)};

    FullscreenOut out;
    out.position = float4(positions[id],0,1);
    out.uv = uvs[id];
    return out;
}

fragment float4 upscaleFragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float4 color = image.sample(samp, in.uv);
    float4 toneMappedColor = 1.0 - exp(-color);
    return float4(toneMappedColor.rgb, 1.0);
}