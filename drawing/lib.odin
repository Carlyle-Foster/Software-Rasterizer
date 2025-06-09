package drawing

import sade "../Shaders/.current_plugin"

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:image"

import shaders "../Shaders/common"

// NOTE: keep this up-to-date with `../main.odin`
// at least until we have something better going..
WIDTH :: 800
HEIGHT :: 600
FOV :: 40

Image :: image.Image

@(export)
g_target: ^[WIDTH*HEIGHT]Pixel

Tri_3D :: struct {
    vertices:   [3][3]f32,
    tex_coords: [3][2]f32,
    normals:    [3][3]f32,
}

Pixel :: struct {
    color: [4]u8,
    depth: f32,
}

ViewMode :: enum {
    Standard,
    Depth,
    Normals,
    Faces,
}

is_inside_triangle :: #force_inline proc(point, ta, tb, tc: [2]i32) -> (yes: bool, weights: [3]f32) {
    areaABP := signed_tri_area(ta, tb, point)
    areaBCP := signed_tri_area(tb, tc, point)
    areaCAP := signed_tri_area(tc, ta, point)
    
    total_area := areaABP + areaBCP + areaCAP
    if total_area <= 0 { return }
    inv_area_sum := 1 / f32(total_area)
    
    weights[0] = f32(areaBCP) * inv_area_sum
    weights[1] = f32(areaCAP) * inv_area_sum
    weights[2] = f32(areaABP) * inv_area_sum

    yes = areaABP >= 0 && areaBCP >= 0 && areaCAP >= 0

    return
}

perp :: #force_inline proc(point: [2]i32) -> [2]i32 {
    return { point.y, -point.x }
}

// TODO: the i32 might overflow?
signed_tri_area :: #force_inline proc(a, b, c: [2]i32) -> i32 {
    return linalg.dot(c - a, perp(b - a)) / 2
}

translate_face :: #force_inline proc(face: [3][3]f32, mtx: matrix[4, 4]f32) -> [3][3]f32 {
    t := [3][3]f32 {
        (mtx * [4]f32{face[0].x, face[0].y, face[0].z, 1}).xyz,
        (mtx * [4]f32{face[1].x, face[1].y, face[1].z, 1}).xyz,
        (mtx * [4]f32{face[2].x, face[2].y, face[2].z, 1}).xyz,
    }
    return t
}

@(export)
// This is thread-safe!
draw_triangle :: proc(
    tri: Tri_3D,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    debug_color: [4]u8,
    view_mode: ViewMode,
    texture: ^Image,
) #no_bounds_check {
    t := translate_face(tri.vertices, transform)
    a := world_to_screen(t[0])
    b := world_to_screen(t[1])
    c := world_to_screen(t[2])

    // backface culling
    if signed_tri_area(a, b, c) <= 0 {
        return
    }

    left    :=  clamp(min(a.x, b.x, c.x), 0, WIDTH)
    right   :=  clamp(max(a.x, b.x, c.x), 0, WIDTH)
    top     :=  clamp(min(a.y, b.y, c.y), 0, HEIGHT)
    bottom  :=  clamp(max(a.y, b.y, c.y), 0, HEIGHT)

    for y := top; y < bottom; y += 1 {
        for x := left; x < right; x += 1 {
            i := y*WIDTH + x
            yes, weights := is_inside_triangle({x, y}, a, b, c)
            //TODO: this probably is wrong but i won't be certain 'till i see the artifacts
            depth := linalg.dot(weights, [3]f32{t[0].z, t[1].z, t[2].z})
            opx := g_target[i]
            if yes && depth < opx.depth {
                npx := Pixel{color={255, 0, 255, 255}, depth=depth}
                
                normal := 
                    tri.normals[0] * weights[0] + 
                    tri.normals[1] * weights[1] + 
                    tri.normals[2] * weights[2]
                tex_coord := 
                    tri.tex_coords[0] * weights[0] + 
                    tri.tex_coords[1] * weights[1] + 
                    tri.tex_coords[2] * weights[2]

                switch view_mode {
                case .Standard:
                    normal = normal * linalg.transpose(rotation)

                    rgba := sade.shader(shaders.Input{normal, tex_coord, depth, texture})

                    rgba = linalg.vector4_linear_to_srgb(rgba)
                    npx.color.rgb = {u8(rgba.r*255), u8(rgba.g*255), u8(rgba.b*255)}
                case .Depth:
                    v := u8(depth/5*255)
                    npx.color.rgb = v
                case .Normals:
                    n := normal / 2 + {.5, .5, .5}
                    npx.color.rgb = [3]u8{u8(n.x*255), u8(n.y*255), u8(n.z*255)}
                case .Faces:
                    npx.color = debug_color
                }
                for {
                    opx_, ok := sync.atomic_compare_exchange_weak_explicit(
                        cast(^u64)&g_target[i],
                        transmute(u64)opx,
                        transmute(u64)npx,
                        .Relaxed,
                        .Relaxed,
                    )
                    if ok {
                        break
                    }
                    opx = transmute(Pixel)opx_
                    if depth >= opx.depth {
                        break
                    }
                }
            }            
        }
    }
}

// shader :: proc(_: shaders.Input) -> shaders.Color {
//     return {1, 0, 1, 1}
// }

world_to_screen :: #force_inline proc(point: [3]f32) -> [2]i32 {
    height_of_view := math.tan(math.to_radians_f32(FOV) / 2) * 2
    px_per_world_unit := f32(HEIGHT) / height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + HEIGHT / 2, i32(p.y) + HEIGHT / 2}
}