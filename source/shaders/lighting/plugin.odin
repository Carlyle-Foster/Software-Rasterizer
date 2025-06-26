package lighting

import "core:math/linalg"

import shaders "../_internals"

shader :: proc(using si: shaders.Input) -> shaders.Color {
    color: shaders.Color
    
    light_dir := linalg.normalize([3]f32{0, 1, -.5})
    light := linalg.dot(normal, light_dir) * .5 + .5
    // light := max(0, linalg.dot(normal, light_dir))

    color.rgb = light

    color.a = 1
    
    return color
}