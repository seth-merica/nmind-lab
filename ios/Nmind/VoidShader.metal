#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Nmind void, drawn on the GPU for every pixel as a real 3D tunnel seen in perspective.
//
// The tunnel is a polygon tube (never six-sided) that you fly down. For each pixel the shader
// finds the depth of the wall it sees: a wall at depth z appears at a screen distance f*R/z from
// that section's centre. The tube bends: near sections are centred on the screen's home point,
// far ones on the target, so the far end of the tunnel follows the target and the tunnel curves
// toward it. The body of the tube follows a trailing copy of the target, so when the target
// jumps (your eyes steer it) the light at the end snaps there and the tunnel sweeps round after. The wall carries a folded neon pattern (a kaleidoscopic IFS) in
// panels that shrink with distance; ribs mark each panel row, walls are lit by a lamp at your
// eye and fade into fog, and the light at the end sits on the target.
//
// Safety: the app eases every input over a second or more and caps `flow` so each rib passes
// a point at most 2.3 times a second (under the 3 a second limit). The heartbeat swell (one per beat, 35 to 180 a minute, so
// under 3 a second) lifts brightness by at most about 22 percent, and the ripple is a moving ring.

static float3 pal(float t) {
    return 0.5 + 0.5 * cos(6.2831853 * (t + float3(0.0, 0.33, 0.67)));
}

static float3 neon(float t) {
    float3 c = pal(t);
    return c * c * 1.6;
}

[[ stitchable ]] half4 nmindVoid(float2 position, half4 currentColor,
                                 float2 size, float2 home, float2 target, float2 lag, float time, float flow,
                                 float focus, float deep, float beat, float folds,
                                 float hue, float iters, float wash, float bright, float kseed,
                                 float beatPhase, float ripple, float heartCalm) {
    float F = clamp(focus, 0.0, 1.0);
    float m = min(size.x, size.y);
    float2 h = size * home;
    float zoom = 1.0 - 0.045 * beat;                 // the beat pulls you forward a touch
    float2 p = (position - h) / m * zoom;
    float2 T = (target - home) * size / m;           // the far end, relative to home
    float2 Tl = (lag - home) * size / m;             // the tunnel's body, trailing the far end

    const float f = 0.5, R = 1.0, zc = 1.6, zmax = 90.0;
    float seg = 6.2831853 / max(folds, 3.0);
    float hs = seg * 0.5;
    float roll = time * 0.03;

    // depth of the wall under this pixel, on a tube that bends toward the target
    float z = 3.0, rp = 0.1, af = 0.0;
    float2 d = p;
    for (int i = 0; i < 7; i++) {
        float bz = 1.0 - exp(-z / zc);
        float fz = 1.0 - exp(-z / 6.0);
        float2 c = Tl * bz + (T - Tl) * fz * fz;      // body swings after the far end
        d = p - c;
        float rr = length(d) + 1e-5;
        float a = atan2(d.y, d.x) + roll;
        af = abs(a - seg * floor(a / seg) - hs);     // angle from the nearest panel's normal
        rp = rr * cos(af);                           // polygon cross-section
        z = min(zmax, f * R / max(rp, 1e-4));
    }
    float r = length(d) + 1e-5;

    // wall coordinates: around the tube and along it. Panels are a little longer than wide.
    float L = 3.2 * R * tan(hs);                     // panel length along the tube
    float u = z / L + flow;                          // you move forward, so the wall comes at you
    float v = af / hs;
    float fu = fract(u);
    float2 q = float2(v * 2.0 - 1.0, abs(fu - 0.5) * 4.0 - 1.0);
    // pattern units per pixel, for smooth lines at every distance
    float cppA = 4.0 * f * R / (L * rp * rp * m);
    float cppV = 2.0 / (r * m * hs);
    float cpp = max(cppA, cppV);
    float detail = clamp(1.6 - cpp * 6.0, 0.0, 1.0);  // far panels fade to an even glow

    float ang = 0.35 + 0.25 * sin(kseed) + 0.05 * sin(time * 0.1);
    float ca = cos(ang), sa = sin(ang);
    float2 off = float2(0.55 + 0.15 * cos(kseed * 1.7), 0.42 + 0.12 * sin(kseed * 0.9));
    float sc = 1.45, s = 1.0;
    float2 zz = q;
    float3 pat = float3(0.0);
    float width = mix(0.05, 0.022, F);
    float w = max(width, cpp * 1.2);
    for (int i = 0; i < 5; i++) {
        float wt = clamp(iters - float(i), 0.0, 1.0);   // the last fold fades in, so nothing pops
        if (wt <= 0.0) break;
        zz = abs(zz) - off;
        zz = float2(ca * zz.x - sa * zz.y, sa * zz.x + ca * zz.y) * sc;
        s *= sc;
        float dd = abs(abs(zz.x) + abs(zz.y) - 0.6) / s;
        float g = exp(-dd / w) * (width / w) + 0.06 * mix(0.5, 1.0, F) * exp(-dd / (w * 5.0));
        pat += g * neon(hue + float(i) * 0.31 + u * 0.015) * (0.9 - 0.12 * float(i)) * wt;
        float jd = length(zz) / s;
        float jw = mix(0.05, 0.08, F);
        pat += exp(-(jd / jw) * (jd / jw)) * 0.5 * F * pow(pal(hue + 0.5 + float(i) * 0.13), 2.5) * 1.6 * wt;
    }
    float3 even = neon(hue + u * 0.015) * 0.18;
    float3 wall = mix(even, pat, detail);

    // ribs across the tube at each panel row, and seams where the panels meet
    float rw = max(0.035, cpp * 1.2);
    float ringd = min(fu, 1.0 - fu) * 2.0;
    float rib = exp(-ringd / rw);
    float seam = exp(-((1.0 - v) * 2.0) / rw);
    wall += rib * neon(hue + 0.5 + u * 0.03) * mix(0.45, 1.0, F);
    wall += seam * 0.55 * neon(hue + 0.25) * mix(0.45, 1.0, F);
    // the panel faces are slightly dished: brighter at their middles, darker by the seams
    wall *= 0.65 + 0.35 * (1.0 - v * v);

    // light: a lamp at your eye lights the near walls; fog swallows the far ones
    float lamp = R / sqrt(R * R + z * z * 0.35);
    float fog = exp(-z * mix(0.12, 0.05, deep));     // deeper worlds let you see further
    float3 light = wall * (0.06 + 1.1 * lamp) * fog;
    // the far end glows with the world's color, so depth reads as distance into light
    float far = 1.0 - fog;
    light += far * far * neon(hue + 0.08) * 0.22 * mix(0.6, 1.0, F);
    light *= mix(0.35, 1.0, F) * (1.0 + 0.22 * beat) * bright;

    // the light at the end of the tunnel, on the target. It swells with each heartbeat and
    // grows as your heart slows.
    float rt = length(p - T);
    float coreR = mix(0.022, 0.075, deep * F) * (1.0 + 0.35 * beat) * (1.0 + 0.6 * heartCalm);
    float cr = rt / coreR;
    light += exp(-cr * cr) * mix(0.3, 1.25, max(deep * F, 0.3 * heartCalm)) * (1.0 + 0.5 * beat)
             * float3(1.0, 0.9, 0.88) * bright;

    // one soft ripple rolls out from the light on every beat
    float wr = mix(0.03, 0.75, beatPhase);
    float rd = (rt - wr) / mix(0.012, 0.05, beatPhase);
    float fade = (1.0 - beatPhase) * (1.0 - beatPhase);
    light += exp(-rd * rd) * fade * 0.55 * ripple * float3(1.0, 0.55, 0.75) * bright;

    float gray = (light.r + light.g + light.b) / 3.0;
    light = mix(light, float3(gray), clamp(wash, 0.0, 1.0));
    float3 outc = 1.0 - exp(-light * mix(0.9, 1.6, F));
    float3 bg = float3(6.0, 6.0, 20.0) / 255.0;
    outc = bg + outc * (1.0 - bg);
    return half4(half3(outc), 1.0h);
}
