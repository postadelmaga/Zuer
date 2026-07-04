#version 450

// Ray-marching (DDA) di una griglia voxel 3D: per ogni pixel traccia un raggio
// ortografico attraverso [0,1]³, trova il primo voxel pieno, e ombreggia con
// N·L + un raggio d'ombra tracciato verso la key light. La normale è la faccia
// del voxel attraversata (asse della griglia = asse oggetto).

layout(location = 0) in vec2 v_ndc;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler3D voxTex; // RGBA sRGB, a = occupazione

layout(push_constant) uniform PC {
    vec4 origin;    // origine raggio, spazio griglia [0,1]
    vec4 right;     // × ndc.x (spazio griglia)
    vec4 up;        // × ndc.y (spazio griglia)
    vec4 dir;       // direzione di marcia (spazio griglia)
    vec4 light_g;   // dir verso la luce (spazio griglia, per il raggio d'ombra)
    vec4 light_obj; // xyz = dir luce oggetto (N·L); w = dim
} pc;

vec3 aces(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

bool occupied(ivec3 c, int dim) {
    if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(dim)))) return false;
    return texelFetch(voxTex, c, 0).a > 0.5;
}

// DDA primario: ritorna hit + cella + normale della faccia d'ingresso.
bool trace(vec3 ro, vec3 rd, int dim, out ivec3 cell, out vec3 nrm) {
    rd = sign(rd) * max(abs(rd), vec3(1e-6));
    vec3 inv = 1.0 / rd;
    vec3 t0 = (vec3(0.0) - ro) * inv;
    vec3 t1 = (vec3(1.0) - ro) * inv;
    vec3 tmn = min(t0, t1), tmx = max(t0, t1);
    float tentry = max(max(tmn.x, tmn.y), tmn.z);
    float texit = min(min(tmx.x, tmx.y), tmx.z);
    if (texit < max(tentry, 0.0)) return false;

    float t = max(tentry, 0.0);
    float h = 1.0 / float(dim);
    vec3 p = ro + rd * t;
    cell = clamp(ivec3(floor(p * float(dim))), ivec3(0), ivec3(dim - 1));
    ivec3 stp = ivec3(sign(rd));
    vec3 tDelta = abs(inv) * h;
    vec3 nb = (vec3(cell) + max(vec3(stp), 0.0)) * h;
    vec3 tMax = t + (nb - p) * inv;

    if (tentry == tmn.x) nrm = vec3(-float(stp.x), 0, 0);
    else if (tentry == tmn.y) nrm = vec3(0, -float(stp.y), 0);
    else nrm = vec3(0, 0, -float(stp.z));

    for (int i = 0; i < dim * 3; i++) {
        if (occupied(cell, dim)) return true;
        if (tMax.x < tMax.y && tMax.x < tMax.z) {
            cell.x += stp.x; tMax.x += tDelta.x; nrm = vec3(-float(stp.x), 0, 0);
        } else if (tMax.y < tMax.z) {
            cell.y += stp.y; tMax.y += tDelta.y; nrm = vec3(0, -float(stp.y), 0);
        } else {
            cell.z += stp.z; tMax.z += tDelta.z; nrm = vec3(0, 0, -float(stp.z));
        }
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(dim)))) return false;
    }
    return false;
}

// Raggio d'ombra: true se un voxel pieno è colpito prima di uscire dalla griglia.
bool traceShadow(vec3 ro, vec3 rd, int dim) {
    rd = sign(rd) * max(abs(rd), vec3(1e-6));
    vec3 inv = 1.0 / rd;
    float h = 1.0 / float(dim);
    ivec3 cell = clamp(ivec3(floor(ro * float(dim))), ivec3(0), ivec3(dim - 1));
    ivec3 stp = ivec3(sign(rd));
    vec3 tDelta = abs(inv) * h;
    vec3 nb = (vec3(cell) + max(vec3(stp), 0.0)) * h;
    vec3 tMax = (nb - ro) * inv;
    for (int i = 0; i < dim * 3; i++) {
        if (tMax.x < tMax.y && tMax.x < tMax.z) { cell.x += stp.x; tMax.x += tDelta.x; }
        else if (tMax.y < tMax.z) { cell.y += stp.y; tMax.y += tDelta.y; }
        else { cell.z += stp.z; tMax.z += tDelta.z; }
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(dim)))) return false;
        if (occupied(cell, dim)) return true;
    }
    return false;
}

void main() {
    int dim = int(pc.light_obj.w);
    vec3 ro = pc.origin.xyz + pc.right.xyz * v_ndc.x + pc.up.xyz * v_ndc.y;
    vec3 rd = pc.dir.xyz;

    ivec3 cell;
    vec3 nrm;
    if (!trace(ro, rd, dim, cell, nrm)) {
        float g = 0.5 + 0.5 * v_ndc.y;
        vec3 bg = mix(vec3(0.05, 0.06, 0.08), vec3(0.12, 0.14, 0.18), g);
        out_color = vec4(pow(bg, vec3(1.0 / 2.2)), 1.0);
        return;
    }

    vec3 albedo = pow(texelFetch(voxTex, cell, 0).rgb, vec3(2.2)); // sRGB→lineare
    vec3 N = nrm; // asse griglia = asse oggetto
    vec3 L = normalize(pc.light_obj.xyz);
    float ndl = max(dot(N, L), 0.0);

    // Ombra: dal centro della cella, spinto oltre la faccia, verso la luce.
    float h = 1.0 / float(dim);
    vec3 start = (vec3(cell) + 0.5) * h + nrm * h * 0.5;
    float sh = (ndl > 0.0 && traceShadow(start, pc.light_g.xyz, dim)) ? 0.25 : 1.0;

    float amb = 0.35 + 0.22 * (0.5 + 0.5 * N.y); // emisferico (up = +Y oggetto)
    vec3 color = albedo * (amb + ndl * sh * 0.9);
    color = aces(color);
    color = pow(color, vec3(1.0 / 2.2));
    out_color = vec4(color, 1.0);
}
