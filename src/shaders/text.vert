#version 450

// Quad texturati per glifo: posizione in pixel schermo (origine in alto a
// sinistra), UV nell'atlante e colore per-vertice. La CPU passa la dimensione
// del viewport per convertire i pixel in NDC.
layout(push_constant) uniform PC {
    vec2 viewport; // larghezza, altezza in pixel
} pc;

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_color;

void main() {
    // px → NDC. In Vulkan l'asse Y del clip punta in basso come lo schermo,
    // quindi nessun flip: pos.y = 0 finisce in alto.
    vec2 ndc = (in_pos / pc.viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
