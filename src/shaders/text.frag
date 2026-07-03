#version 450

// L'atlante è a canale singolo (copertura del glifo, 0..1) esposto come .r.
// Il colore viene dal vertice; l'alpha è la copertura → blending sopra lo sfondo.
layout(set = 0, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_color;

layout(location = 0) out vec4 out_color;

void main() {
    float coverage = texture(atlas, v_uv).r;
    out_color = vec4(v_color, coverage);
}
