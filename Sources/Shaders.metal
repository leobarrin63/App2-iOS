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
        // sol a 1,70 m sous la position de depart de la tete : en 6DoF,
        // uEye.y monte et descend avec la tete (s'accroupir rapproche le sol)
        float t = max(1.7 + u.uEye.y, 0.05) / (-el);   // sol 1,70 m sous le depart
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

/* PASSTHROUGH : l'image de la camera arriere, a taille reelle. Pour chaque
   pixel de l'oeil, on prend la direction qu'il regarde (repere de la tete,
   qui est celui de la camera), on la projette avec les vraies
   caracteristiques de la camera (intrinseques ARKit), puis on lit l'image
   camera (Y + CbCr) a cet endroit. Hors du champ de la camera : noir. */
struct CamUniforms {
    float2 uTan;
    float uZoom;
    float pad;
    float4 uK;      // fx, fy, cx, cy normalises par la taille de l'image
};

fragment float4 fsCam(VNOut in [[stage_in]],
                       constant CamUniforms &u [[buffer(0)]],
                       texture2d<float> texY [[texture(0)]],
                       texture2d<float> texUV [[texture(1)]],
                       sampler s [[sampler(0)]]) {
    // uZoom > 1 : chaque pixel regarde un angle plus petit -> image agrandie
    float3 d = float3(in.vN.x * u.uTan.x / u.uZoom, in.vN.y * u.uTan.y / u.uZoom, -1.0);
    float2 t = float2(u.uK.x * d.x / (-d.z) + u.uK.z, u.uK.y * (-d.y) / (-d.z) + u.uK.w);
    if (t.x < 0.0 || t.x > 1.0 || t.y < 0.0 || t.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float y = texY.sample(s, t).r;
    float2 c = texUV.sample(s, t).rg;
    const float4x4 versRGB = float4x4(
        float4(+1.0000, +1.0000, +1.0000, +0.0000),
        float4(+0.0000, -0.3441, +1.7720, +0.0000),
        float4(+1.4020, -0.7141, +0.0000, +0.0000),
        float4(-0.7010, +0.5291, -0.8860, +1.0000));
    return float4((versRGB * float4(y, c, 1.0)).rgb, 1.0);
}

/* MAIN : squelette de la main detectee, en pastilles rondes dont la taille
   suit la distance. */
struct MainUniforms {
    float4x4 vp;
    float4 col;
    float taille;
};

struct MainOut {
    float4 position [[position]];
    float size [[point_size]];
};

vertex MainOut vsMain(uint vid [[vertex_id]],
                      constant packed_float3 *pts [[buffer(0)]],
                      constant MainUniforms &u [[buffer(1)]]) {
    MainOut o;
    float4 p = u.vp * float4(float3(pts[vid]), 1.0);
    o.position = p;
    o.size = u.taille / max(p.w, 0.05);
    return o;
}

fragment float4 fsMain(MainOut in [[stage_in]],
                        float2 pc [[point_coord]],
                        constant MainUniforms &u [[buffer(1)]]) {
    float r = length(pc - 0.5);
    if (r > 0.5) discard_fragment();
    return float4(u.col.rgb, u.col.a * (1.0 - smoothstep(0.32, 0.5, r)));
}

/* SCENE 3D : materiau PBR simplifie, comme sur Android.
   - relief : carte de normales, repere tangent calcule a la volee par
     derivees d'ecran (le fichier n'a pas de tangentes) ;
   - rugosite / metal (G / B) : reflets qui bougent avec la tete ;
   - ombrage ambiant (R) : coins et dessous de meubles plus sombres ;
   - une lampe au plafond, au-dessus du point d'entree.
   Les textures d'un scan contiennent deja la lumiere reelle de la piece :
   l'ambiance reste forte pour ne pas l'eclairer deux fois. */
struct SceneIn {
    float3 p [[attribute(0)]];
    float3 n [[attribute(1)]];
    float2 t [[attribute(2)]];
};

struct SceneV {
    float4x4 mvp;
    float4x4 m;
};

struct SceneOut {
    float4 position [[position]];
    float3 n;
    float2 t;
    float3 wp;
};

vertex SceneOut vsScene(SceneIn in [[stage_in]], constant SceneV &u [[buffer(3)]]) {
    SceneOut o;
    o.position = u.mvp * float4(in.p, 1.0);
    o.n = (u.m * float4(in.n, 0.0)).xyz;
    o.t = in.t;
    o.wp = (u.m * float4(in.p, 1.0)).xyz;
    return o;
}

struct SceneF {
    float4 col;
    float4 cam;     // xyz : oeil ; w : seuil d'alpha (MASK)
    float4 a;       // presence : couleur, relief, rugosite/metal, ombrage
    float4 b;       // echelle du relief, rugosite, metal, force de l'ombrage
};

fragment float4 fsScene(SceneOut in [[stage_in]],
                         bool avant [[front_facing]],
                         constant SceneF &u [[buffer(0)]],
                         texture2d<float> tc [[texture(0)]],
                         texture2d<float> tn [[texture(1)]],
                         texture2d<float> tm [[texture(2)]],
                         texture2d<float> to [[texture(3)]],
                         sampler s [[sampler(0)]]) {
    float4 c = u.col;
    if (u.a.x > 0.5) c *= tc.sample(s, in.t);
    if (c.a < u.cam.w) discard_fragment();
    float3 n = normalize(in.n);
    if (!avant) n = -n;
    if (u.a.y > 0.5) {
        float3 dp1 = dfdx(in.wp), dp2 = dfdy(in.wp);
        float2 du1 = dfdx(in.t), du2 = dfdy(in.t);
        float3 p2 = cross(dp2, n), p1 = cross(n, dp1);
        float3 T = p2 * du1.x + p1 * du2.x;
        float3 B = p2 * du1.y + p1 * du2.y;
        float k = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
        float3 tt = tn.sample(s, in.t).xyz * 2.0 - 1.0;
        // V du glTF descend dans l'image : on inverse le vert
        tt.xy *= float2(u.b.x, -u.b.x);
        n = normalize(float3x3(T * k, B * k, n) * tt);
    }
    float rugo = u.b.y, metal = u.b.z, ao = 1.0;
    if (u.a.z > 0.5) { float3 m = tm.sample(s, in.t).rgb; rugo *= m.g; metal *= m.b; }
    if (u.a.w > 0.5) ao = 1.0 + u.b.w * (to.sample(s, in.t).r - 1.0);
    rugo = clamp(rugo, 0.05, 1.0);

    float3 L = float3(0.0, 0.9, 0.0) - in.wp;
    float d2 = dot(L, L);
    L *= rsqrt(max(d2, 1e-6));
    float att = 1.0 / (1.0 + 0.08 * d2);
    float3 V = normalize(u.cam.xyz - in.wp);
    float3 H = normalize(L + V);
    float ndl = max(dot(n, L), 0.0);
    float a2 = rugo * rugo * rugo * rugo;
    float brillance = 2.0 / a2 - 2.0;
    float spec = pow(max(dot(n, H), 0.0), brillance) * (brillance + 8.0) / 25.13;
    float3 F0 = mix(float3(0.04), c.rgb, metal);
    float3 diffus = c.rgb * (1.0 - metal);
    float3 col = diffus * ao * (0.62 + 0.38 * ndl * att) + F0 * min(spec, 30.0) * ndl * att * ao;
    return float4(col, c.a);
}

struct LensOut {
    float4 position [[position]];
    float2 vT;
};

/* En Metal, la ligne 0 d'une texture est en HAUT (en OpenGL, en bas) : le
   haut de l'image (y = +1) se relit donc en v = 0. Avec la formule
   d'Android (v = y * 0,5 + 0,5), tout ressortait retourne haut/bas. */
vertex LensOut vsLens(uint vid [[vertex_id]], constant float2 *pos [[buffer(0)]]) {
    LensOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.vT = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
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
