// ... (Keep your direct lighting / shadow ray calculation) ...

        // --- NEW: MATERIAL PROPERTIES & BOUNCE DIRECTION ---
        
        // Define roughness and specular variables based on your material struct
        // (If using classic wavefront .mtl, specularExponent maps to shininess)
        // Convert specularExponent (0 to 1000+) to a clean roughness value between 0.01 and 1.0
        float roughness = clamp(1.0 - (material.specularExponent / 1000.0), 0.01, 1.0);
        float3 specularColor = material.specularColor;

        // Determine if this surface behaves like a metal or a dielectric
        // Usually, if specularColor is high and diffuse is low, it behaves like a metal.
        float3 F0 = specularColor; // Fresnel reflection at normal incidence
        
        // Use Schlick's approximation for Fresnel reflection tendency
        float3 V = -rayDirection; // Vector back towards the camera/previous bounce
        float3 N = normal;
        if (dot(N, V) < 0.0) N = -N; // Faceforward correction
        
        float cosTheta = max(dot(N, V), 0.0);
        float3 F = F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);

        // Decide stochastically whether to pick a Diffuse or Specular reflection path
        seed += float(bounce) * 143.137;
        float2 bounceRand = random2(seed + float(bounce) * 12345.6789);
        float selectRand = random(seed + 45.67);

        // Probability of picking a specular reflection over diffuse based on Fresnel reflection intensity
        float specularProbability = clamp(max(F.r, max(F.g, F.b)), 0.1, 0.9);

        float3 bounceDirection;
        if (selectRand < specularProbability) {
            // --- SPECULAR REFLECTION PATH ---
            float3 perfectReflection = reflect(rayDirection, N);
            
            // Blur the reflection vector using the roughness setting
            float3 fuzzyReflection = cosineWeightedHemisphere(perfectReflection, bounceRand);
            bounceDirection = normalize(mix(perfectReflection, fuzzyReflection, roughness));
            
            // Adjust throughput by the specular color and weight it by selection probability
            throughput *= (F / specularProbability);
        } else {
            // --- DIFFUSE REFLECTION PATH ---
            bounceDirection = cosineWeightedHemisphere(N, bounceRand);
            
            // Adjust throughput by the diffuse albedo and weight it by selection probability
            throughput *= (albedo * (1.0 - F) / (1.0 - specularProbability));
        }

        // Catch edge-case bounces leaking inside geometry
        if (dot(bounceDirection, N) < 0.0) {
            break; 
        }

        // Prep the ray for its next bounce
        rayOrigin = result.hit + N * epsilon; 
        rayDirection = bounceDirection;
        invRayDirection = 1.0 / rayDirection;

        // --- END NEW MATERIAL PROPERTIES ---

        // Russian Roulette (Keep this below the throughput adjustments)
        if (bounce > 3) { 
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05f, 0.95f);
            if (random(seed + bounce * 991.74) > p) break;
            throughput /= p;
        }
    } // End of bounce loop