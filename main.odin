package rasterizer

import "core:log"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:os/os2"
import "core:strings"
import "core:strconv"
// import "core:slice"

import rl "vendor:raylib"

Color :: [4]f32

BLACK   :: Color {0,0,0,1}
WHITE   :: Color {1,1,1,1}

RED     :: Color {1,0,0,1}
GREEN   :: Color {0,1,0,1}
BLUE    :: Color {0,0,1,1}

DEEP    :: Color {0.12, 0.15, 0.62, 1}

WIDTH :: 800
HEIGHT :: 600

FOV :: 90

ViewMode :: enum {
    Standard,
    Depth,
    Normals,
    Faces,
}

g_view_mode := ViewMode.Faces

Tri_3D :: struct {
    vertices:   [3][3]f32,
    tex_coords: [3][2]f32,
    normals:    [3][3]f32,
}

Model :: struct {
    faces: []Tri_3D,
}

g_models: [dynamic]Model

Entity :: struct {
    model: int,
    position: [3]f32,
    scale: f32,
    yaw: f32,
    pitch: f32,
    roll: f32,
    color: Color,
}

g_entities: [dynamic]Entity

create_entity :: proc(model: int, position: [3]f32, scale: f32, color: Color) -> Entity {
    return {
        model=model,
        position=position,
        scale=scale,
        yaw=0,
        pitch=0,
        roll=0,
        color=color,
    }
}

get_transform :: proc(e: Entity) -> matrix[4, 4]f32 {
    rotation := 
        linalg.matrix4_rotate(e.yaw, [3]f32{0,1,0}) * 
        linalg.matrix4_rotate(e.pitch, [3]f32{1,0,0}) * 
        linalg.matrix4_rotate(e.roll, [3]f32{0,0,1})

    return linalg.matrix4_translate(e.position) * linalg.matrix4_scale(e.scale) * rotation
}

g_target: [WIDTH*HEIGHT]rl.Color
g_depth_buffer: [WIDTH*HEIGHT]f32

translate_face :: #force_inline proc(face: [3][3]f32, mtx: matrix[4, 4]f32) -> [3][3]f32 {
    t := [3][3]f32 {
        (mtx * [4]f32{face[0].x, face[0].y, face[0].z, 1}).xyz,
        (mtx * [4]f32{face[1].x, face[1].y, face[1].z, 1}).xyz,
        (mtx * [4]f32{face[2].x, face[2].y, face[2].z, 1}).xyz,
    }
    return t
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

main :: proc() {
    context.logger = log.create_console_logger(opt=log.Options{
        .Level,
        .Terminal_Color,
        .Short_File_Path,
        .Line,
    })
    defer log.destroy_console_logger(context.logger)

    rl.SetTargetFPS(60)
    rl.InitWindow(WIDTH, HEIGHT, "SoftWare Rasterizer 0.97")

    image := rl.Image{
        data = &g_target,
        width = WIDTH,
        height = HEIGHT,
        mipmaps = 1,
        format = .UNCOMPRESSED_R8G8B8A8,
    }
    texture := rl.LoadTextureFromImage(image)

    new, import_ok := import_obj_file("suzanne.obj")
    assert(import_ok)
    defer delete(new.faces)
    append(&g_models, new)

    ent := create_entity(0, {0, 0, 3}, 1, DEEP)
    ent.yaw = math.PI
    ent.roll = math.PI
    append(&g_entities, ent)

    for !rl.WindowShouldClose() {
        mem.set(&g_target, 0, len(g_target) * size_of(g_target[0]))
        for &d in g_depth_buffer {
            d = math.INF_F32
        }
        for e in g_entities {
            draw_entity(e)
        }
        rl.UpdateTexture(texture, &g_target)

        rl.BeginDrawing()
        rl.ClearBackground(rl.Color{126, 225, 225, 255})
        rl.DrawTexture(texture, 0, 0, rl.WHITE)
        rl.EndDrawing()

        for &e, i in g_entities {
            s := f32(i+1)
            e.pitch += 0.01 / s
            e.yaw += 0.02 * s
        }

        if rl.IsKeyPressed(.S) { g_view_mode = .Standard    }
        if rl.IsKeyPressed(.D) { g_view_mode = .Depth       }
        if rl.IsKeyPressed(.N) { g_view_mode = .Normals     }
        if rl.IsKeyPressed(.F) { g_view_mode = .Faces       }

        free_all(context.temp_allocator)
    }
}

draw_entity :: proc(e: Entity) {
    mtx := get_transform(e)
    faces := &g_models[e.model].faces
    for face, i in faces {
        c := transmute([4]u8)(u32((f32(i) / f32(len(faces))) * 16_000_000))
        color := rl.Color{c.r, c.g, c.b, 255}
        draw_triangle(face, mtx, color)
    }
}

draw_triangle :: #force_inline  proc(tri: Tri_3D, transform: matrix[4,4]f32, color: rl.Color) #no_bounds_check {
    t := translate_face(tri.vertices, transform)
    a, b, c := world_to_screen(t[0]), world_to_screen(t[1]), world_to_screen(t[2])

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
            depth := linalg.dot(weights, [3]f32{t[0].z, t[1].z, t[2].z})
            if yes && depth < g_depth_buffer[i] {
                g_depth_buffer[i] = depth

                switch g_view_mode {
                case .Standard:
                    unimplemented()
                case .Depth:
                    v := u8(depth/5*255)
                    g_target[i] = rl.Color{v,v,v,255}
                case .Normals:
                    normal := tri.normals[0] / 2 + {.5, .5, .5}
                    g_target[i] = rl.Color{u8(normal.x*255), u8(normal.y*255), u8(normal.z*255), 255}
                case .Faces:
                    g_target[i] = color
                }
            }            
        }
    }
}

world_to_screen :: #force_inline proc(point: [3]f32) -> [2]i32 {
    height_of_view := math.tan(math.to_radians_f32(FOV) / 2) * 2
    px_per_world_unit := HEIGHT / height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + WIDTH / 2, i32(p.y) + HEIGHT / 2}
}

import_obj_file :: proc(name: string) -> (m: Model, ok: bool) {
    data, err := os2.read_entire_file_from_path(name, context.allocator)
    assert(err == nil)
    defer delete(data)
    
    contents := string(data)

    vertices    := make([dynamic][3]f32)
    normals     := make([dynamic][3]f32)
    tex_coords  := make([dynamic][2]f32)
    defer delete(vertices)
    defer delete(normals)
    defer delete(tex_coords)

    tris := make([dynamic]Tri_3D)

    for line in strings.split_lines_iterator(&contents) {
        if strings.starts_with(line, "#") { continue }
        if strings.starts_with(line, "v ") {
            rest := line[2:]
            vertex: [3]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 2 { break }
                vertex[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&vertices, vertex)
        }
        if strings.starts_with(line, "vn ") {
            rest := line[3:]
            normal: [3]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 2 { break }
                normal[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&normals, normal)
        }
        if strings.starts_with(line, "vt ") {
            rest := line[3:]
            tex_coord: [2]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 1 { break }
                tex_coord[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&tex_coords, tex_coord)
        }
        if strings.starts_with(line, "f ") {
            rest := line[2:]
            i := 0
            vline:  [2][3]f32
            nline:  [2][3]f32
            tcline: [2][2]f32
            for entry in strings.split_iterator(&rest, " ") {
                entry := entry
                v_i     := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return
                tc_i    := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return
                n_i     := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return

                vertex      := vertices[v_i - 1]
                tex_coord   := tex_coords[tc_i - 1]
                normal      := normals[n_i - 1]

                if i < 2 {
                    vline[i]    = vertex
                    tcline[i]   = tex_coord
                    nline[i]    = normal
                }
                else {
                    obj := Tri_3D{
                        vertices    = {vline[0],    vline[1],   vertex},
                        tex_coords  = {tcline[0],   tcline[1],  tex_coord},
                        normals     = {nline[0],    nline[1],   normal},
                    }
                    append(&tris, obj)
                    vline[1]    = vertex
                    tcline[1]   = tex_coord
                    nline[1]    = normal
                }
                i += 1
            }            
        }
    }
    return Model{tris[:]}, true
}
