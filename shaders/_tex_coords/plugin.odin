package _tex_coords

import shaders "../_internals"

shader :: proc(using si: shaders.Input) -> shaders.Color {
    c: shaders.Color

    c.rg = tex_coord
    
    return c
}