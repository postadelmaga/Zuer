#version 450

// La MVP arriva già composta dalla CPU (centratura, yaw/pitch, fit ortografico,
// mappatura depth in [0,1]). nrm0/1/2 sono le righe della sola rotazione
// oggetto→camera; i `w` trasportano i fattori del materiale. light_vp proietta
// la posizione oggetto nello spazio clip della luce per il lookup delle ombre.
layout(push_constant) uniform PC {
    mat4 mvp;
    vec4 nrm0;     // xyz = riga 0 rotazione; w = roughness
    vec4 nrm1;     // xyz = riga 1;           w = metallic
    vec4 nrm2;     // xyz = riga 2
    vec4 material; // rgb = baseColor factor; a = alpha
    mat4 light_vp;
    vec4 light_dir_cam;
} pc;

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_tangent; // xyz = tangente, w = handedness

layout(location = 0) out vec3 v_normal;      // normale in spazio camera
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec4 v_shadow_coord; // posizione in clip-space luce
layout(location = 3) out vec4 v_tangent;      // xyz = tangente camera, w = handedness

void main() {
    vec4 p = pc.mvp * vec4(in_pos, 1.0);
    gl_Position = p;
    v_uv = in_uv;

    v_normal = vec3(
        dot(pc.nrm0.xyz, in_normal),
        dot(pc.nrm1.xyz, in_normal),
        dot(pc.nrm2.xyz, in_normal)
    );

    // Tangente nella stessa base camera della normale; handedness invariata.
    v_tangent = vec4(
        dot(pc.nrm0.xyz, in_tangent.xyz),
        dot(pc.nrm1.xyz, in_tangent.xyz),
        dot(pc.nrm2.xyz, in_tangent.xyz),
        in_tangent.w
    );

    v_shadow_coord = pc.light_vp * vec4(in_pos, 1.0);
}
