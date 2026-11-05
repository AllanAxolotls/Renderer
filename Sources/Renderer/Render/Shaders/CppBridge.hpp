#pragma once

#if defined(__METAL_VERSION__)
    #include <metal_stdlib>
    using namespace metal;

    #define make_half1 half1
    #define make_half2 half2
    #define make_half3 half3
    #define make_half4 half4

    #define make_float1 float1
    #define make_float2 float2
    #define make_float3 float3
    #define make_float4 float4
#else
    #include <simd/simd.h>

    #define device
    #define constant const
    #define thread
    #define threadgroup
    #define threadgroup_imageblock
    #define stage_in
    #define kernel
    #define M_PI_F 3.141f

    using bool1 = simd::int1;
    using bool2 = simd::int2;
    using bool3 = simd::int3;
    using bool4 = simd::int4;

    using uint  = simd::uint1;
    using uint1 = simd::uint1;
    using uint2 = simd::uint2;
    using uint3 = simd::uint3;
    using uint4 = simd::uint4;
    
    using int1 = simd::int1;
    using int2 = simd::int2;
    using int3 = simd::int3;
    using int4 = simd::int4;

    using half  = simd::half1;
    using half1 = simd::half1;
    using half2 = simd::half2;
    using half3 = simd::half3;
    using half4 = simd::half4;
    #define make_half1 simd::make_half1
    #define make_half2 simd::make_half2
    #define make_half3 simd::make_half3
    #define make_half4 simd::make_half4

    using float1 = simd::float1;
    using float2 = simd::float2;
    using float3 = simd::float3;
    using float4 = simd::float4;
    #define make_float1 simd::make_float1
    #define make_float2 simd::make_float2
    #define make_float3 simd::make_float3
    #define make_float4 simd::make_float4
    
    using float3x3 = simd::float3x3;
    using float4x4 = simd::float4x4;

    inline float dot(float3 a, float3 b) { return simd_dot(a, b); }
    inline float3 cross(float3 a, float3 b) { return simd_cross(a, b); }
    inline float length(float3 v) { return simd_length(v); }
    inline float3 normalize(float3 v) { return simd_normalize(v); }
    inline float3 reflect(float3 x, float3 n) { return simd_reflect(x, n); }
    inline float3 refract(float3 i, float3 n, float eta) { return simd_refract(i, n, eta); }

    template <typename T, typename Mask>
    inline T select(T a, T b, Mask mask) { return simd_select(a, b, mask); }
    
    template <typename T>
    inline T min(T a, T b) { return a < b ? a : b; }

    template <typename T>
    inline T max(T a, T b) { return a > b ? a : b; }
    
    template <typename T>
    inline T mix(T a, T b, float t) { return simd_mix(a, b, t); }

    template <typename T>
    inline T fmin(T a, T b) { return std::fmin(a, b); }

    template <typename T>
    inline T fmax(T a, T b) { return std::fmax(a, b); }

    template <typename T>
    inline T clamp(T val, T lo, T hi) { return val < lo ? lo : (val > hi ? hi : val); }

    template <typename T>
    inline bool any(T val) { return simd_any(val); }

    template <typename T>
    inline bool all(T val) { return simd_all(val); }

    template <typename T>
    inline bool isnan(T val) {}

    template <typename T>
    inline bool isinf(T val) {}

    inline float rsqrt(float x) { return 1.0f / std::sqrt(x); }
    inline float saturate(float x) { return clamp(x, 0.0f, 1.0f); }
    inline float mix(float x, float y, float a) { return x + (y - x) * a; }

    struct sampler {};

    struct gradient2d {
        gradient2d(float x, float y) {}
    };

    enum access : uint { read, write };
    template <typename ColorChannelFormat, access Access=read>
    struct texture2d {
        uint get_width();
        uint get_height();

        template <typename PixelFormat>
        void write(PixelFormat, uint2);

        template <typename PixelFormat>
        PixelFormat read(uint2);

        template <typename PixelFormat>
        PixelFormat sample(sampler, float2);

        template <typename PixelFormat>
        PixelFormat sample(sampler, float2, gradient2d);
    };

    template <typename T, int ElementCount>
    struct array { 
        T elements[ElementCount]; 
        T operator[] (int subscript) const {
            return elements[subscript];
        }
    };

   

#endif