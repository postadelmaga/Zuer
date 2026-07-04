#version 450

// Triangolo a schermo intero senza vertex buffer (gl_VertexIndex 0..2).
layout(location = 0) out vec2 v_ndc;

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    v_ndc = p * 2.0 - 1.0; // [-1,1]
    gl_Position = vec4(v_ndc, 0.0, 1.0);
}
