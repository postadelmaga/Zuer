#version 450

layout(push_constant) uniform PC {
    mat4 mvp;
    vec4 light;
} pc;

layout(location = 0) in vec3 v_pos;
layout(location = 0) out vec4 out_color;

void main() {
    // Le mesh OBJ/GLB caricate non hanno normali affidabili: la normale della
    // faccia si ricava dalle derivate in screen-space (flat shading double-face).
    vec3 n = normalize(cross(dFdx(v_pos), dFdy(v_pos)));
    float diff = clamp(abs(dot(n, normalize(pc.light.xyz))), 0.15, 1.0);

    // Stesso gradiente del renderer CPU: lontano = blu scuro, vicino = ciano.
    float near = clamp(1.0 - gl_FragCoord.z, 0.0, 1.0);
    vec3 base = mix(vec3(0.08, 0.12, 0.39), vec3(0.0, 1.0, 1.0), near);

    out_color = vec4(base * diff, 1.0);
}
