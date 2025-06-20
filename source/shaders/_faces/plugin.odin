package _faces

import shaders "../_internals"

shader :: proc(using si: shaders.Input) -> shaders.Color {
    c := debug_color
    
    return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 1}
}