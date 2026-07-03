#version 450

// La MVP arriva già composta dalla CPU (centratura, yaw/pitch, fit ortografico,
// mappatura depth in [0,1]): il vertex shader è un solo prodotto matrice-vettore.
layout(push_constant) uniform PC {
    mat4 mvp;
    vec4 light; // xyz = direzione luce (spazio vista), w inutilizzato
} pc;

layout(location = 0) in vec3 in_pos;
layout(location = 0) out vec3 v_pos;

void main() {
    vec4 p = pc.mvp * vec4(in_pos, 1.0);
    gl_Position = p;
    v_pos = p.xyz;
}
