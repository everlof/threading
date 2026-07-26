// Input ABI, in declaration order from main.swift:
// values[0] density, values[1] opacity, values[2] speed.

float skalmanRainHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float skalmanRainLayer(
    float2 uv,
    float time,
    float density,
    float scale,
    float speed,
    float seed,
    float groundY
) {
    float2 p = uv;
    p.x *= scale;
    p.y *= scale * 0.58;
    p.x += p.y * 0.17;

    float2 cell = floor(p);
    float2 local = fract(p);
    float random = skalmanRainHash(cell + seed);
    float active = smoothstep(1.0 - density, 1.0, random);

    float fall = fract(time * speed * (0.58 + random * 0.9) + random);
    float y = fract(local.y - fall);
    float x = abs(local.x - (0.12 + random * 0.76));
    float width = 0.018 + (1.0 - scale / 58.0) * 0.018;
    float streakLength = 0.18 + random * 0.42;

    float streak = smoothstep(width, 0.0, x)
        * smoothstep(streakLength, streakLength * 0.45, y)
        * smoothstep(0.0, 0.035, y);
    float head = smoothstep(
        width * 2.8,
        0.0,
        length(float2(y - streakLength * 0.5, x * 2.0))
    );
    float aboveGround = 1.0 - smoothstep(groundY - 0.025, groundY + 0.004, uv.y);
    return active * (streak + head * 0.32) * (0.45 + random * 0.55)
        * aboveGround;
}

float skalmanRainSplash(
    float2 uv,
    float time,
    float density,
    float columns,
    float speed,
    float seed,
    float groundY
) {
    float columnPosition = uv.x * columns;
    float column = floor(columnPosition);
    float localX = fract(columnPosition) - 0.5;
    float random = skalmanRainHash(float2(column, seed));
    float active = smoothstep(
        1.0 - density,
        1.0,
        skalmanRainHash(float2(column + 17.0, seed * 2.7))
    );

    // One short impact phase per column. Scaling y by the column count gives the splash the
    // same proportions at every window size rather than stretching it with the viewport.
    float age = fract(time * speed * (0.24 + random * 0.22) + random);
    float2 p = float2(
        localX,
        (uv.y - groundY) * columns
    );
    float life = 1.0 - smoothstep(0.0, 0.46, age);

    // A flattened ring races out along the contact plane.
    float ringRadius = 0.05 + age * 0.46;
    float ringDistance = abs(length(float2(p.x, p.y * 5.5)) - ringRadius);
    float ring = smoothstep(0.045, 0.006, ringDistance)
        * smoothstep(0.14, 0.0, abs(p.y))
        * life;

    // Two crown droplets peel away from the impact and fall back into the wet edge.
    float crownAge = min(age / 0.46, 1.0);
    float lift = sin(crownAge * 3.14159265) * (0.17 + random * 0.10);
    float spread = 0.045 + crownAge * (0.22 + random * 0.09);
    float crownLeft = smoothstep(
        0.065,
        0.008,
        length(p - float2(-spread, -lift))
    );
    float crownRight = smoothstep(
        0.065,
        0.008,
        length(p - float2(spread, -lift * 0.84))
    );

    // The first bright contact point makes the falling streak and its splash read as one event.
    float contact = smoothstep(
        0.10,
        0.0,
        length(float2(p.x, p.y * 2.4))
    ) * (1.0 - smoothstep(0.0, 0.11, age));

    return active * (ring * 0.78 + (crownLeft + crownRight) * life + contact);
}

float4 skalmanExtensionFragment(
    float2 uv,
    constant SkalmanSurfaceUniforms &uniforms
) {
    float density = clamp(uniforms.values[0], 0.0, 1.0);
    float opacity = clamp(uniforms.values[1], 0.0, 0.65);
    float speed = max(uniforms.values[2], 0.0);
    if (density <= 0.001 || speed <= 0.001) {
        return float4(0.0);
    }

    float aspect = max(uniforms.size.x / max(uniforms.size.y, 1.0), 0.4);
    float2 rainUV = float2(uv.x * aspect, uv.y);
    float time = uniforms.time;
    float groundY = 0.935;

    float farRain = skalmanRainLayer(
        rainUV, time, density * 0.48, 22.0, speed * 0.72, 7.0, groundY
    );
    float midRain = skalmanRainLayer(
        rainUV, time, density * 0.72, 36.0, speed, 19.0, groundY
    );
    float nearRain = skalmanRainLayer(
        rainUV, time, density, 54.0, speed * 1.35, 41.0, groundY
    );
    float rain = farRain * 0.28 + midRain * 0.52 + nearRain * 0.82;

    float farSplash = skalmanRainSplash(
        rainUV, time, density * 0.58, 18.0, speed * 0.76, 11.0, groundY
    );
    float nearSplash = skalmanRainSplash(
        rainUV, time, density, 31.0, speed * 1.08, 37.0, groundY
    );
    float splash = farSplash * 0.46 + nearSplash * 0.92;

    // A shallow wet edge anchors the impacts. It is intentionally subtle: the extension is an
    // overlay over working UI, not a scene which may cover its controls.
    float wetEdge = smoothstep(groundY - 0.008, groundY + 0.018, uv.y)
        * (1.0 - smoothstep(groundY + 0.085, groundY + 0.15, uv.y))
        * density * density;

    // A subtle veil makes a near-spent account feel stormier without washing out text.
    float veil = density * density * 0.035
        * (0.55 + 0.45 * sin((uv.y + time * 0.025) * 31.0));
    float alpha = clamp(
        rain * opacity
            + splash * opacity * 0.92
            + wetEdge * opacity * 0.10
            + veil,
        0.0,
        0.62
    );
    float3 coldLight = mix(
        float3(0.52, 0.64, 0.74),
        float3(0.88, 0.94, 1.0),
        clamp(rain + splash * 1.3, 0.0, 1.0)
    );
    return float4(coldLight, alpha);
}
