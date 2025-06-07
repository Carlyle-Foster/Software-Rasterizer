#+feature dynamic-literals
package shaders

import "core:math"
import "core:math/linalg"
import "core:image"

Image :: image.Image

ShaderInput :: struct {
    normal: [3]f32,
    tex_coord: [2]f32,
    depth: f32,
    texture: ^Image,
}
FragShader :: #type proc(SI: ShaderInput) -> (color: [4]f32)

@(export)
shaders := map[string]FragShader{
    "error" = proc(_: ShaderInput) -> (color: [4]f32) {
        color = {1, 0, 1, 1}
        return
    },
    "default" = proc(using SI: ShaderInput) -> (color: [4]f32) {
        light_dir := linalg.normalize([3]f32{0, -1, -.5})
        light := linalg.dot(normal, light_dir) * .5 + .5
        color = sample_texture(texture, tex_coord)
        color *= light
        // color.rgb = light
    
        color.a = 1
    
        return
    },
}


sample_texture :: #force_inline proc(tex: ^Image, tex_coord: [2]f32) -> [4]f32 {
    tc := tex_coord
    tc.y = 1. - tc.y
    coord := tc - math.F32_EPSILON // Ensures it's not exactly 1
    x := int(max(coord.x, 0) * f32(tex.width))
    y := int(max(coord.y, 0) * f32(tex.height))

    buf := cast([^][4]u8)(raw_data(tex.pixels.buf[:]))

    c := buf[y*tex.width + x]

    return linalg.vector4_srgb_to_linear([4]f32{f32(c.r)/255, f32(c.g)/255, f32(c.b)/255, f32(c.a)/255})
}

