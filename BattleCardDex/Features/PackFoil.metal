#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 packFoil(float2 position, half4 color, float2 size, float time, float2 touch, float intensity) {
    float2 uv = position / max(size, float2(1.0));
    float2 p = uv - 0.5;
    float a = sin(p.x * 13.0 + p.y * 4.0 + sin(p.y * 21.0) * 0.8);
    float b = sin(p.x * -7.0 + p.y * 17.0 + sin(p.x * 18.0));
    float grain = sin(p.x * 94.0 + p.y * 63.0) * sin(p.y * 81.0 - p.x * 37.0);
    float ridges = a * 0.55 + b * 0.32 + grain * 0.13;
    float2 light = mix(float2(0.2 + 0.12 * sin(time * 0.7), 0.14), touch, 0.45);
    float highlight = pow(max(0.0, 1.0 - distance(uv + float2(ridges * 0.018, 0.0), light) * 2.1), 5.0);
    float sweep = pow(max(0.0, 1.0 - abs((uv.x + uv.y * 0.42) - (0.25 + fmod(time * 0.08, 1.25))) * 9.0), 3.0);
    float shade = ridges * 0.075 + highlight * 0.30 + sweep * 0.15;
    float3 spectrum = 0.5 + 0.5 * cos(6.28318 * (float3(0.0, 0.33, 0.67) + uv.x * 0.22 + ridges * 0.05));
    color.rgb = half3(clamp(float3(color.rgb) * (1.0 + shade * intensity) + spectrum * sweep * 0.055 * intensity, 0.0, 1.0));
    return color;
}
