package shader

import "core:math"
import "core:math/linalg"
import "core:image"

Color :: [4]f32

Frag :: #type proc(Input) -> Color

Input :: struct {
    normal: [3]f32,
    tex_coord: [2]f32,
    depth: f32,
    texture: ^Image,
}

Image :: image.Image

sample :: #force_inline proc(tex: ^Image, tex_coord: [2]f32) -> [4]f32 {
    tc := tex_coord
    tc.y = 1. - tc.y
    coord := tc - math.F32_EPSILON // Ensures it's not exactly 1
    x := int(max(coord.x, 0) * f32(tex.width))
    y := int(max(coord.y, 0) * f32(tex.height))

    buf := cast([^][4]u8)(raw_data(tex.pixels.buf[:]))

    c := buf[y*tex.width + x]

    return linalg.vector4_srgb_to_linear([4]f32{f32(c.r)/255, f32(c.g)/255, f32(c.b)/255, f32(c.a)/255})
}