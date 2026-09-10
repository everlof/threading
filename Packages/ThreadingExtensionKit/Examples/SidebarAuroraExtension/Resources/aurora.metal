// Input ABI, in declaration order from main.swift:
// values[0] energy (0...1, from workload.intensity), values[1] opacity, values[2] hour (0...1).
//
// A backdrop is judged by what it does to the words on top of it, so this stays low-frequency
// and low-contrast on purpose: broad ribbons, no hard edges, and a veil that never exceeds the
// stated opacity. The host composites the whole surface below its own ceiling as well.

float threadingAuroraNoise(float2 p) {
    return sin(p.x) * cos(p.y * 1.3) + sin(p.x * 0.5 + p.y * 0.7);
}

float4 threadingExtensionFragment(
    float2 uv,
    constant ThreadingSurfaceUniforms &uniforms
) {
    float energy = clamp(uniforms.values[0], 0.0, 1.0);
    float opacity = clamp(uniforms.values[1], 0.0, 0.6);
    float hour = fract(uniforms.values[2]);
    float time = uniforms.time * (0.05 + energy * 0.15);

    // Three ribbons drifting at different rates; energy widens and brightens them.
    float2 p = float2(uv.x * 2.2, uv.y * 3.5);
    float ribbonA = threadingAuroraNoise(p + float2(time, -time * 0.4));
    float ribbonB = threadingAuroraNoise(p * 1.7 + float2(-time * 0.6, time * 0.3) + 3.1);
    float ribbonC = threadingAuroraNoise(p * 0.6 + float2(time * 0.2, time * 0.5) + 7.7);
    float glow = ribbonA * 0.5 + ribbonB * 0.3 + ribbonC * 0.2;
    glow = smoothstep(-0.4 - energy * 0.6, 1.2, glow);

    // Night leans teal and violet; day leans toward a pale gold. Both stay desaturated
    // enough that light or dark rows read on them.
    float night = 0.5 + 0.5 * cos(hour * 6.2831853);
    float3 nightColour = mix(float3(0.10, 0.55, 0.60), float3(0.45, 0.25, 0.70), ribbonB * 0.5 + 0.5);
    float3 dayColour = mix(float3(0.85, 0.70, 0.35), float3(0.55, 0.65, 0.85), ribbonA * 0.5 + 0.5);
    float3 colour = mix(dayColour, nightColour, night);

    // Fade toward the top so the brand row stays the calmest part of the column.
    float verticalFade = smoothstep(0.0, 0.35, uv.y);
    float alpha = glow * opacity * (0.35 + energy * 0.65) * verticalFade;
    return float4(colour, clamp(alpha, 0.0, opacity));
}
