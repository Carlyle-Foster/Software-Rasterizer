package _depth

import shaders "../_internals"

shader :: proc(using si: shaders.Input) -> shaders.Color {
    return depth / 5
}