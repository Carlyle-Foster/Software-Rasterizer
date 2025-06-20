package _normals

import shaders "../_internals"

shader :: proc(using si: shaders.Input) -> shaders.Color {
    c := normal / 2 + {.5, .5, .5}
    
    return {c.r, c.g, c.b, 1}
}