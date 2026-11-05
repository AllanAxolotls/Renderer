#pragma once

#include "CppBridge.hpp"

// LCG (Linear Congruential Generator)
// Hash and Code Implementation by Jarzynski and Olano
// Source: https://jcgt.org/published/0009/03/02/

static inline uint nextRandom(thread uint& state) {
    state = state * 747796405 + 2891336453;
    uint result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
    result = (result >> 22) ^ result;
    return result;
}

static inline float random(thread uint& state) {
    return nextRandom(state) / 4294967295.0; // 2^32 - 1
}

static inline float2 random2(thread uint& seed) {
    return make_float2(random(seed), random(seed));
}

static inline uint randomStartingState(uint2 gid, uint sampleIndex) {
    // These are randomly picked numbers
    return gid.x * 1973 + gid.y * 9277 + sampleIndex * 26699;
}