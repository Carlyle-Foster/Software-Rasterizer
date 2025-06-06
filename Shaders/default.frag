#version 330 core

in vec2 v_tex_coord;

out vec4 o_color;

uniform sampler2D u_texture;
uniform sampler2D u_depth_buf;

void main() {
    o_color = texture(u_texture, v_tex_coord);
    gl_FragDepth = texture(u_depth_buf, v_tex_coord).r;
}