#version 450

layout(push_constant) uniform PC {
    mat4 mvp;
    vec4 nrm0;     // w = roughness
    vec4 nrm1;     // w = metallic
    vec4 nrm2;
    vec4 material; // rgb = baseColor factor
    mat4 light_vp;
    vec4 light_dir_cam; // key light in spazio camera
    vec4 vt;            // x,y = tiles_x,tiles_y del livello; z = 1 se VT attiva
} pc;

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec4 v_shadow_coord;
layout(location = 3) in vec4 v_tangent;
layout(location = 0) out vec4 out_color;

// baseColor virtualizzata: pool di tile 128² come sampler2DArray (bind 0) +
// SSBO d'indirezione cell→slot (bind 3). shadow map depth della key light
// (bind 1) e normal map tangent-space lineare (bind 2, 1×1 piatta se assente).
layout(set = 0, binding = 0) uniform sampler2DArray vtPool;
layout(set = 0, binding = 1) uniform sampler2D shadowMap;
layout(set = 0, binding = 2) uniform sampler2D normalTex;
layout(set = 0, binding = 3, std430) readonly buffer VtIndir { uint vtSlots[]; };

const float PI = 3.14159265359;
const float SHADOW_TEXEL = 1.0 / 1024.0;

// Geometria tile del pool (deve combaciare con vtex.zig).
const float VT_TILE = 128.0;
const float VT_GUTTER = 2.0;
const float VT_INNER = 124.0;

// Campiona la baseColor virtuale a UV: individua la cella del livello residente,
// ne legge lo slot fisico dall'SSBO, e campiona il texel locale dentro l'inner
// gutter-padded della tile. Il pool è UNORM ma contiene byte sRGB → linearizza.
vec3 sampleVTBase(vec2 uv) {
    float txf = clamp(uv.x, 0.0, 0.999999) * pc.vt.x;
    float tyf = clamp(uv.y, 0.0, 0.999999) * pc.vt.y;
    uint cell = uint(tyf) * uint(pc.vt.x) + uint(txf);
    float slot = float(vtSlots[cell]);
    float lx = (VT_GUTTER + fract(txf) * VT_INNER) / VT_TILE;
    float ly = (VT_GUTTER + fract(tyf) * VT_INNER) / VT_TILE;
    return pow(texture(vtPool, vec3(lx, ly, slot)).rgb, vec3(2.2));
}

vec3 aces(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

float distributionGGX(float NdotH, float rough) {
    float a = rough * rough;
    float a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-7);
}

float geometrySmith(float NdotV, float NdotL, float rough) {
    float r = rough + 1.0;
    float k = (r * r) / 8.0;
    float gv = NdotV / (NdotV * (1.0 - k) + k);
    float gl = NdotL / (NdotL * (1.0 - k) + k);
    return gv * gl;
}

vec3 fresnelSchlick(float cosT, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);
}

vec3 lightContrib(vec3 N, vec3 V, vec3 L, vec3 radiance, vec3 albedo, float metallic, float rough, vec3 f0) {
    vec3 H = normalize(L + V);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 1e-4);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(V, H), 0.0);
    float D = distributionGGX(NdotH, rough);
    float G = geometrySmith(NdotV, NdotL, rough);
    vec3 F = fresnelSchlick(VdotH, f0);
    vec3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 1e-4);
    vec3 kd = (vec3(1.0) - F) * (1.0 - metallic);
    return (kd * albedo / PI + spec) * radiance * NdotL;
}

// Frazione di luce che raggiunge il frammento (1 = pieno sole, 0 = ombra),
// PCF 3×3 sulla shadow map della key light. NdotL modula il bias per ridurre
// l'acne sulle superfici radenti.
float keyVisibility(float NdotL) {
    vec3 sc = v_shadow_coord.xyz / v_shadow_coord.w;
    vec2 uv = sc.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || sc.z > 1.0 || sc.z < 0.0)
        return 1.0;
    float bias = clamp(0.0015 * tan(acos(clamp(NdotL, 0.0, 1.0))), 0.0008, 0.006);
    float sum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float closest = texture(shadowMap, uv + vec2(dx, dy) * SHADOW_TEXEL).r;
            sum += (sc.z - bias > closest) ? 0.0 : 1.0;
        }
    }
    return sum / 9.0;
}

void main() {
    const vec3 V = vec3(0.0, 0.0, 1.0);

    vec3 N = v_normal;
    if (dot(N, N) < 1e-8) {
        N = cross(dFdx(vec3(gl_FragCoord.xy, gl_FragCoord.z)),
                  dFdy(vec3(gl_FragCoord.xy, gl_FragCoord.z)));
    }
    N = normalize(N);
    if (dot(N, V) < 0.0) N = -N;

    // Normal mapping: perturba N con la normale tangent-space campionata. La
    // normal map piatta di default è (0,0,1) → xy≈0 → nessuna perturbazione.
    vec3 nm = texture(normalTex, v_uv).xyz * 2.0 - 1.0;
    if (dot(v_tangent.xyz, v_tangent.xyz) > 1e-8 && dot(nm.xy, nm.xy) > 1e-4) {
        // Ortogonalizza la tangente; se degenere (∥ N, es. facce assiali con
        // tangente di fallback) salta la perturbazione per non generare NaN.
        vec3 Traw = v_tangent.xyz - N * dot(N, v_tangent.xyz);
        if (dot(Traw, Traw) > 1e-6) {
            vec3 T = normalize(Traw);
            vec3 B = cross(N, T) * v_tangent.w;
            N = normalize(mat3(T, B, N) * nm);
        }
    }

    vec3 baseTex = (pc.vt.z > 0.5) ? sampleVTBase(v_uv) : vec3(1.0);
    vec3 albedo = pc.material.rgb * baseTex;
    float roughness = clamp(pc.nrm0.w, 0.04, 1.0);
    float metallic = clamp(pc.nrm1.w, 0.0, 1.0);
    vec3 f0 = mix(vec3(0.04), albedo, metallic);

    vec3 keyDir = normalize(pc.light_dir_cam.xyz);
    vec3 fillDir = normalize(vec3(-0.6, 0.2, 0.7));
    vec3 keyRad = vec3(1.0, 0.98, 0.92) * 2.4;
    vec3 fillRad = vec3(0.55, 0.62, 0.80) * 0.9;

    // La key light proietta ombre. Per renderle leggibili, in ombra si attenua
    // anche fill+ambient come un'occlusione ambientale (mai a nero pieno).
    float vis = keyVisibility(max(dot(N, keyDir), 0.0));
    float ao = mix(0.5, 1.0, vis);

    vec3 Lo = vec3(0.0);
    Lo += lightContrib(N, V, keyDir, keyRad, albedo, metallic, roughness, f0) * vis;
    Lo += lightContrib(N, V, fillDir, fillRad, albedo, metallic, roughness, f0) * ao;

    vec3 sky = vec3(0.34, 0.38, 0.46);
    vec3 ground = vec3(0.10, 0.10, 0.12);
    vec3 ambient = mix(ground, sky, 0.5 + 0.5 * N.y);
    Lo += albedo * ambient * (1.0 - metallic * 0.6) * ao;

    float rim = pow(1.0 - max(dot(N, V), 0.0), 3.0) * 0.35;
    Lo += vec3(0.5, 0.6, 0.8) * rim;

    vec3 color = aces(Lo);
    color = pow(color, vec3(1.0 / 2.2));
    out_color = vec4(color, 1.0);

}
