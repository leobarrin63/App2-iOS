#include <metal_stdlib>
using namespace metal;

/* Traduction directe des shaders GLSL de MainActivity.kt (Android) en
   MSL. Pas de uSTM (matrice de SurfaceTexture) : sur iOS la texture
   video issue d'AVPlayerItemVideoOutput n'a pas cette particularite. */

struct VNOut {
    float4 position [[position]];
    float2 vN;
};

vertex VNOut vsPlein(uint vid [[vertex_id]],
                      constant float2 *pos [[buffer(0)]]) {
    VNOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.vN = pos[vid];
    return o;
}

struct EnvUniforms {
    float4x4 uRot;   // seule la partie 3x3 haut-gauche est utilisee
    float2 uTan;
    float3 uEye;
    float uT;
};

static inline float h11(float p) { return fract(sin(p * 127.1) * 43758.5453); }
static inline float h21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

fragment float4 fsEnv(VNOut in [[stage_in]], constant EnvUniforms &u [[buffer(0)]]) {
    float3 d = normalize((u.uRot * float4(in.vN.x * u.uTan.x, in.vN.y * u.uTan.y, -1.0, 0.0)).xyz);
    float el = d.y;
    float3 col = mix(float3(0.010, 0.024, 0.050), float3(0.003, 0.007, 0.018),
                      clamp(el * 1.5, 0.0, 1.0));
    float az = atan2(d.x, -d.z) / 6.28318530718 + 0.5;
    float NC = 120.0;
    float cf = az * NC, ci = floor(cf), cx = fract(cf);
    float colM = smoothstep(0.08, 0.24, cx) * (1.0 - smoothstep(0.76, 0.92, cx));
    float NR = 50.0;
    float q = (0.5 - asin(clamp(el, -1.0, 1.0)) / 3.14159265) * NR;

    float sp = 0.55 + h11(ci) * 0.9;
    float L = 12.0 + h11(ci + 31.7) * 16.0;
    float ph = fract((q - u.uT * sp) / L);
    float trail = pow(ph, 4.0);
    float cell = floor(q);
    float seed = ci * 13.0 + cell + floor(u.uT * 1.3 + h21(float2(ci, cell)) * 11.0);

    // glyph()
    float2 g = float2((cx - 0.16) / 0.68, fract(q));
    float ok = step(0.0, g.x) * step(g.x, 1.0) * step(0.0, g.y) * step(g.y, 1.0);
    float2 s = clamp(g, 0.0, 1.0) * float2(3.0, 5.0);
    float2 b = floor(s), f = fract(s);
    float on = step(0.42, h21(float2(b.y * 3.0 + b.x, seed)));
    float m = smoothstep(0.0, 0.20, f.x) * (1.0 - smoothstep(0.80, 1.0, f.x))
            * smoothstep(0.0, 0.16, f.y) * (1.0 - smoothstep(0.84, 1.0, f.y));
    float gl2 = on * m * ok * colM;

    float band = smoothstep(-0.02, 0.20, el) * (1.0 - smoothstep(0.55, 0.92, el));
    float dep = 0.30 + 0.70 * h11(ci + 5.5);
    float amt = trail * gl2 * band * dep;
    col += mix(float3(0.10, 0.46, 0.94), float3(0.74, 0.90, 1.00),
               smoothstep(0.88, 1.0, ph)) * amt * 0.80;
    col += float3(0.02, 0.07, 0.16) * trail * band * colM * 0.45;

    if (el < -0.004) {
        float t = 1.7 / (-el);
        float3 p = u.uEye + d * t;
        float fog = exp(-t * 0.035);
        float2 gf = abs(fract(p.xz / 1.2) - 0.5);
        float lw = 0.020 + t * 0.0018;
        float line = clamp((1.0 - smoothstep(0.0, lw, gf.x)) + (1.0 - smoothstep(0.0, lw, gf.y)), 0.0, 1.0);
        float3 fl = float3(0.005, 0.013, 0.026) + float3(0.05, 0.20, 0.42) * line * 0.5;
        float3 far = float3(0.004, 0.009, 0.019);
        col = mix(col, fl * fog + far * (1.0 - fog), 1.0 - smoothstep(-0.055, -0.004, el));
    }
    col += float3(0.020, 0.080, 0.170) * exp(-abs(el) * 18.0);
    return float4(col, 1.0);
}

struct VidUniforms {
    float4x4 uRot;   // seule la partie 3x3 haut-gauche est utilisee
    float2 uTan;
    float4 uUV;
};

fragment float4 fsVid(VNOut in [[stage_in]],
                       constant VidUniforms &u [[buffer(0)]],
                       texture2d<float> uTex [[texture(0)]],
                       sampler s [[sampler(0)]]) {
    float3 d = normalize((u.uRot * float4(in.vN.x * u.uTan.x, in.vN.y * u.uTan.y, -1.0, 0.0)).xyz);
    float uu = atan2(d.x, -d.z) / 6.28318530718 + 0.5;
    float v = acos(clamp(d.y, -1.0, 1.0)) / 3.14159265359;
    float ix = u.uUV.x + uu * u.uUV.y;
    float iy = u.uUV.z + v * u.uUV.w;
    return uTex.sample(s, float2(ix, iy));
}

struct QuadIn {
    float3 aP [[attribute(0)]];
    float2 aT [[attribute(1)]];
};

struct QuadOut {
    float4 position [[position]];
    float2 vT;
};

vertex QuadOut vsQuad(QuadIn in [[stage_in]], constant float4x4 &uMVP [[buffer(1)]]) {
    QuadOut o;
    o.position = uMVP * float4(in.aP, 1.0);
    o.vT = in.aT;
    return o;
}

fragment float4 fsQuad(QuadOut in [[stage_in]],
                        constant float &uA [[buffer(0)]],
                        texture2d<float> uTex [[texture(0)]],
                        sampler s [[sampler(0)]]) {
    float4 c = uTex.sample(s, in.vT);
    return float4(c.rgb, c.a * uA);
}

struct LensOut {
    float4 position [[position]];
    float2 vT;
};

vertex LensOut vsLens(uint vid [[vertex_id]], constant float2 *pos [[buffer(0)]]) {
    LensOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.vT = pos[vid] * 0.5 + 0.5;
    return o;
}

struct LensUniforms {
    float uK1;
    float uAsp;
};

fragment float4 fsLens(LensOut in [[stage_in]],
                        constant LensUniforms &u [[buffer(0)]],
                        texture2d<float> uTex [[texture(0)]],
                        sampler s [[sampler(0)]]) {
    float2 p = (in.vT - 0.5) * float2(u.uAsp, 1.0);
    float r2 = dot(p, p);
    float2 uv = p * (1.0 + u.uK1 * r2 + u.uK1 * 0.35 * r2 * r2) / float2(u.uAsp, 1.0) + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return uTex.sample(s, uv);
}
