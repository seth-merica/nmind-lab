#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Nmind void, drawn on the GPU for every pixel. The screen is folded into a kaleidoscope
// (never six-fold) and mapped to log-polar space, so the view becomes an endless polygon tunnel
// of square cells. Each cell holds a folded neon pattern (a kaleidoscopic IFS); focus sharpens
// and brightens it, depth adds folds and color, and `flow` carries you inward.
//
// Safety: the app eases every input over a second or more and caps `flow` so each ring passes
// a point under two times a second. The heartbeat swell (one per beat, 35 to 180 a minute, so
// under 3 a second) lifts brightness by at most about 22 percent, and the ripple is a moving ring.

static float3 pal(float t) {
    return 0.5 + 0.5 * cos(6.2831853 * (t + float3(0.0, 0.33, 0.67)));
}

static float3 neon(float t) {
    float3 c = pal(t);
    return c * c * 1.6;
}

[[ stitchable ]] half4 nmindVoid(float2 position, half4 currentColor,
                                 float2 size, float centerY, float time, float flow,
                                 float focus, float deep, float beat, float folds,
                                 float hue, float iters, float wash, float bright, float kseed,
                                 float beatPhase, float ripple, float heartCalm) {
    float F = clamp(focus, 0.0, 1.0);
    float m = min(size.x, size.y);
    float2 c = float2(size.x * 0.5, size.y * centerY);
    float zoom = 1.0 - 0.045 * beat;
    float2 p = (position - c) / m * zoom;
    float r = length(p) + 1e-5;
    float a = atan2(p.y, p.x) + time * 0.03;

    float seg = 6.2831853 / max(folds, 3.0);
    float hs = seg * 0.5;
    float af = abs(a - seg * floor(a / seg) - hs);   // angle from the nearest edge normal
    float rp = r * cos(af);                          // polygon cross-section
    float cell = 0.55 / hs;                          // cells per unit of log radius
    float u = -log(rp) * cell + flow;
    float v = af / hs;
    float fu = fract(u);
    float2 q = float2(v * 2.0 - 1.0, abs(fu - 0.5) * 4.0 - 1.0);
    float cpp = 2.0 * 0.55 / (r * m * hs);           // pattern units per pixel, for smooth lines

    float ang = 0.35 + 0.25 * sin(kseed) + 0.05 * sin(time * 0.1);
    float ca = cos(ang), sa = sin(ang);
    float2 off = float2(0.55 + 0.15 * cos(kseed * 1.7), 0.42 + 0.12 * sin(kseed * 0.9));
    float sc = 1.45, s = 1.0;
    float2 z = q;
    float3 light = float3(0.0);
    float width = mix(0.05, 0.022, F);
    float w = max(width, cpp * 1.2);
    for (int i = 0; i < 5; i++) {
        float wt = clamp(iters - float(i), 0.0, 1.0);   // the last fold fades in, so nothing pops
        if (wt <= 0.0) break;
        z = abs(z) - off;
        z = float2(ca * z.x - sa * z.y, sa * z.x + ca * z.y) * sc;
        s *= sc;
        float d = abs(abs(z.x) + abs(z.y) - 0.6) / s;
        float g = exp(-d / w) * (width / w) + 0.06 * mix(0.5, 1.0, F) * exp(-d / (w * 5.0));
        light += g * neon(hue + float(i) * 0.31 + u * 0.015) * (0.9 - 0.12 * float(i)) * wt;
        float jd = length(z) / s;
        float jw = mix(0.05, 0.08, F);
        light += exp(-(jd / jw) * (jd / jw)) * 0.5 * F * pow(pal(hue + 0.5 + float(i) * 0.13), 2.5) * 1.6 * wt;
    }

    // tunnel rings and edges
    float rw = max(0.02, cpp * 1.2);
    float ringd = min(fu, 1.0 - fu) * 2.0;
    light += exp(-ringd / rw) * 0.9 * neon(hue + 0.5 + u * 0.03) * 0.95 * mix(0.4, 1.0, F);
    float spd = (1.0 - v) * 2.0;
    light += exp(-spd / rw) * 0.5 * neon(hue + 0.25) * 0.95 * mix(0.4, 1.0, F);

    // fog toward the centre, then the light at the end of the tunnel
    float fog = pow(clamp((r - 0.012) / mix(0.12, 0.05, deep), 0.0, 1.0), 1.5);
    light *= fog * mix(0.3, 1.0, F) * (1.0 + 0.22 * beat) * bright;
    // the core swells with each heartbeat and grows as your heart slows
    float coreR = mix(0.02, 0.07, deep * F) * (1.0 + 0.35 * beat) * (1.0 + 0.6 * heartCalm);
    float cr = r / coreR;
    light += exp(-cr * cr) * mix(0.25, 1.2, max(deep * F, 0.3 * heartCalm)) * (1.0 + 0.5 * beat)
             * float3(1.0, 0.9, 0.88) * bright;

    // one soft ripple rolls out from the core on every beat
    float wr = mix(0.03, 0.75, beatPhase);
    float rd = (r - wr) / mix(0.012, 0.05, beatPhase);
    float fade = (1.0 - beatPhase) * (1.0 - beatPhase);
    light += exp(-rd * rd) * fade * 0.55 * ripple * float3(1.0, 0.55, 0.75) * bright;
    light *= clamp(1.15 - r * 0.9, 0.4, 1.0);

    float gray = (light.r + light.g + light.b) / 3.0;
    light = mix(light, float3(gray), clamp(wash, 0.0, 1.0));
    float3 outc = 1.0 - exp(-light * mix(0.9, 1.6, F));
    float3 bg = float3(6.0, 6.0, 20.0) / 255.0;
    outc = bg + outc * (1.0 - bg);
    return half4(half3(outc), 1.0h);
}
