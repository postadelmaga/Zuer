#version 450

// Shadow pass: proietta la posizione oggetto nello spazio clip della luce.
// Legge lo stesso vertex buffer della mesh (stride 32) usando solo la posizione.
layout(push_constant) uniform PC {
    mat4 light_vp;
} pc;

layout(location = 0) in vec3 in_pos;

void main() {
    gl_Position = pc.light_vp * vec4(in_pos, 1.0);
}
