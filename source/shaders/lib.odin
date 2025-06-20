package shaders

import sade "standard"////////"////////"////////"////////"////////"////////
_ :: sade

import "core:math"
import "core:math/linalg"
import "core:image"
import "core:sync"

import shaders  "_internals"
import cmn      "_externals"

Pixel :: cmn.Pixel
Tri_3D :: cmn.Tri_3D

Image :: image.Image

@(export)
g_target: ^[dynamic]Pixel

g_height_of_view: f32

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
draw_entity :: proc(
    faces: []Tri_3D,
    offset: int,
    stride: int,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    texture: ^Image,
    width: i32,
    height: i32,
    fov: f32,
) {
    g_height_of_view = math.tan(math.to_radians_f32(fov) / 2) * 2

    num_faces := len(faces)
    for i := offset; i < num_faces; i += stride {
        face := faces[i]
        debug_color: [4]u8

        when #config(debug_views, false) {
            c := transmute([4]u8)(u32((f32(i) / f32(num_faces)) * 16_000_000))
            debug_color = [4]u8{c.r, c.g, c.b, 255}
        }
        draw_triangle(face, transform, rotation, debug_color, texture, width, height)
    }
}

// This is thread-safe!
draw_triangle :: #force_inline proc(
    tri: Tri_3D,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    debug_color: [4]u8,
    texture: ^Image,
    width: i32,
    height: i32,
) #no_bounds_check {
    target := raw_data(g_target[:])

    t := translate_face(tri.vertices, transform)
    a := world_to_screen(t[0], width, height)
    b := world_to_screen(t[1], width, height)
    c := world_to_screen(t[2], width, height)

    // backface culling
    if signed_tri_area(a, b, c) <= 0 {
        return
    }

    left    :=  clamp(min(a.x, b.x, c.x), 0, width)
    right   :=  clamp(max(a.x, b.x, c.x), 0, width)
    top     :=  clamp(min(a.y, b.y, c.y), 0, height)
    bottom  :=  clamp(max(a.y, b.y, c.y), 0, height)

    for y := top; y < bottom; y += 1 {
        for x := left; x < right; x += 1 {
            i := y*width + x
            yes, weights := is_inside_triangle({x, y}, a, b, c)
            //TODO: this probably is wrong but i won't be certain 'till i see the artifacts
            depth := linalg.dot(weights, [3]f32{t[0].z, t[1].z, t[2].z})
            opx := target[i]
            if yes && depth < opx.depth {
                npx := Pixel{color={0, 0, 0, 255}, depth=depth}
                
                normal := 
                    tri.normals[0] * weights[0] + 
                    tri.normals[1] * weights[1] + 
                    tri.normals[2] * weights[2]
                tex_coord := 
                    tri.tex_coords[0] * weights[0] + 
                    tri.tex_coords[1] * weights[1] + 
                    tri.tex_coords[2] * weights[2]

                when #config(debug_views, false) == false {
                    normal = normal * linalg.transpose(rotation)

                    rgba := sade.shader(shaders.Input{normal, tex_coord, depth, texture, debug_color})

                    rgba = linalg.vector4_linear_to_srgb(rgba)
                }
                else {
                    rgba := sade.shader(shaders.Input{normal, tex_coord, depth, texture, debug_color})
                }
                npx.color.rgb = {u8(rgba.r*255), u8(rgba.g*255), u8(rgba.b*255)}
                for {
                    opx_, ok := sync.atomic_compare_exchange_weak_explicit(
                        cast(^u64)&target[i],
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

world_to_screen :: #force_inline proc(point: [3]f32, width, height: i32) -> [2]i32 {
    px_per_world_unit := f32(height) / g_height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + width / 2, i32(p.y) + height / 2}
}