package rasterizer

import "core:log"
// import "core:math/rand"
import "core:math/linalg"
// import "core:math/ease"
import "core:math"
import "core:mem"
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

Tri_2D :: [3][2]i32
Tri_3D :: [3][3]f32

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
    rotation := linalg.matrix4_rotate(e.yaw, [3]f32{0,1,0}) * linalg.matrix4_rotate(e.pitch, [3]f32{1,0,0}) * linalg.matrix4_rotate(e.roll, [3]f32{0,0,1})

    return linalg.matrix4_translate(e.position) * linalg.matrix4_scale(e.scale) * rotation
}

g_target: [WIDTH*HEIGHT]rl.Color

translate_face :: #force_inline proc(face: Tri_3D, mtx: matrix[4, 4]f32) -> Tri_3D {
    t := Tri_3D {
        (mtx * [4]f32{face[0].x, face[0].y, face[0].z, 1}).xyz,
        (mtx * [4]f32{face[1].x, face[1].y, face[1].z, 1}).xyz,
        (mtx * [4]f32{face[2].x, face[2].y, face[2].z, 1}).xyz,
    }
    return t
}

is_inside_triangle :: #force_inline proc(point: [2]i32, tri: Tri_2D) -> bool {
    for i in 0..<3  {
        base := tri[i]
        side := tri[(i+1)%3] - base
        if is_right_of_line(point - base, side) {
            return false
        }
    }
    return true
}

is_right_of_line :: #force_inline proc(point: [2]i32, line: [2]i32) -> bool {
    perp := [2]i32{line.y, -line.x}

    return linalg.dot(point, perp) > 0
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

    new := import_obj_file("cube.obj")
    defer delete(new.faces)
    append(&g_models, new)

    append(&g_entities, create_entity(0, {0, 0, 5}, 1, DEEP))

    for !rl.WindowShouldClose() {
        mem.set(&g_target, 0, len(g_target) * size_of(g_target[0]))
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
            e.yaw += 0.002 * s
        }

        free_all(context.temp_allocator)
    }
}

draw_entity :: proc(e: Entity) {
    mtx := get_transform(e)
    faces := &g_models[e.model].faces
    for face, i in faces {
        c := transmute([4]u8)(u32((f32(i) / f32(len(faces))) * 16_000_000))
        color := rl.Color{c.r, c.g, c.b, 255}
        draw_triangle(translate_face(face, mtx), color)
    }
}

draw_triangle :: #force_inline  proc(tri: Tri_3D, color: rl.Color) #no_bounds_check {
    projected_tri := Tri_2D{world_to_screen(tri[0]), world_to_screen(tri[1]), world_to_screen(tri[2])}
    b_box := get_clipped_bounding_box(projected_tri)
    for y := b_box.top; y < b_box.bottom; y += 1 {
        for x := b_box.left; x < b_box.right; x += 1 {
            if is_inside_triangle({x, y}, projected_tri) {
                g_target[y*WIDTH + x] = color
            }            
        }
    }
}

world_to_screen :: #force_inline proc(point: [3]f32) -> [2]i32 {
    height_of_view := math.tan(math.to_radians_f32(FOV) / 2) * 2
    px_per_world_unit := HEIGHT / height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + WIDTH / 2, -i32(p.y) + HEIGHT / 2}
}

Box :: struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,
}

get_clipped_bounding_box :: #force_inline proc(tri: Tri_2D) -> Box {
    return {
        left    =   clamp(min(tri[0].x, tri[1].x, tri[2].x), 0, WIDTH),
        right   =   clamp(max(tri[0].x, tri[1].x, tri[2].x), 0, WIDTH),
        top     =   clamp(min(tri[0].y, tri[1].y, tri[2].y), 0, HEIGHT),
        bottom  =   clamp(max(tri[0].y, tri[1].y, tri[2].y), 0, HEIGHT),
    }
}

import_obj_file :: proc(name: string) -> Model {
    data, err := os2.read_entire_file_from_path(name, context.allocator)
    assert(err == nil)
    defer delete(data)
    
    contents := string(data)

    points := make([dynamic][3]f32)
    defer delete(points)

    tris := make([dynamic]Tri_3D)

    for line in strings.split_lines_iterator(&contents) {
        if strings.starts_with(line, "#") { continue }
        if strings.starts_with(line, "v ") {
            rest := line[2:]
            point: [3]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 2 { break }
                ok: bool
                point[i], ok = strconv.parse_f32(entry)
                assert(ok)
                i += 1
            }
            append(&points, point)
        }
        if strings.starts_with(line, "f ") {
            rest := line[2:]
            i := 0
            line: [2][3]f32
            for entry in strings.split_iterator(&rest, " ") {
                index, no_more := strconv.parse_int(entry)
                assert(!no_more)
                point := points[index-1]
                if i < 2 {
                    line[i] = point
                }
                else {
                    obj := Tri_3D{line[0], line[1], point}
                    append(&tris, obj)
                    line[1] = point
                }
                i += 1
            }            
        }
    }
    return Model{tris[:]}
    // return create_model(tris[:], position={2.5,2.5,.01}, scale=0.1, color=DEEP)
}
