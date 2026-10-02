// Eight low-to-high frequency readings occupy values[0...7]. Silence and the default
// unavailable fallback are zero. No autonomous time animation: every bar is measured audio.
float4 threadingExtensionFragment(float2 uv, constant ThreadingSurfaceUniforms &uniforms) {
    int band = min(int(uv.x * 8.0), 7);
    float energy = clamp(uniforms.values[band], 0.0, 1.0);
    float column = fract(uv.x * 8.0);
    float edge = smoothstep(0.02, 0.12, column) * (1.0 - smoothstep(0.88, 0.98, column));
    float fromBottom = 1.0 - uv.y;
    float height = energy * 0.35;
    float fill = (1.0 - smoothstep(height, height + 0.015, fromBottom)) * step(0.001, energy);
    float3 colour = mix(float3(0.15, 0.50, 0.52), float3(0.40, 0.35, 0.65), float(band) / 7.0);
    return float4(colour, fill * edge * 0.22);
}
