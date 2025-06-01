package rasterizer

import "core:log"
// import "core:math/rand"
import "core:math/linalg"
// import "core:math/ease"
import "core:mem"
import "core:os/os2"
import "core:strings"
import "core:strconv"
import "core:slice"

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

FOV :: 110

Tri_2D :: [3][2]f32
Tri_3D :: [3][3]f32

TriObject :: struct {
    inner: Tri_3D,
    color: Color,
    mtx: matrix[4, 4]f32,
}

Model :: struct {
    faces: []Tri_3D,
    position: [3]f32,
    scale: f32,
    yaw: f32,
    pitch: f32,
    roll: f32,
    color: Color,
}

create_model :: proc(faces: []Tri_3D, position: [3]f32, scale: f32, color: Color) -> Model {
    return {
        faces=faces,
        position=position,
        scale=scale,
        yaw=0,
        pitch=0,
        roll=0,
        color=color,
    }
}

g_models: [dynamic]Model

get_transform :: proc(m: Model) -> matrix[4, 4]f32 {

    rotation := linalg.matrix4_rotate(m.yaw, [3]f32{0,1,0}) * linalg.matrix4_rotate(m.pitch, [3]f32{1,0,0}) * linalg.matrix4_rotate(m.roll, [3]f32{0,0,1})

    return linalg.matrix4_scale(m.scale) * linalg.matrix4_translate(m.position) * rotation
}

g_triangles: [dynamic]TriObject

g_target: [WIDTH*HEIGHT][4]u8

translate_face :: #force_inline proc(face: Tri_3D, mtx: matrix[4, 4]f32) -> Tri_3D {
    t := Tri_3D {
        (mtx * [4]f32{face[0].x, face[0].y, face[0].z, 1}).xyz,
        (mtx * [4]f32{face[1].x, face[1].y, face[1].z, 1}).xyz,
        (mtx * [4]f32{face[2].x, face[2].y, face[2].z, 1}).xyz,
    }
    return t
}

is_inside_triangle :: #force_inline proc(point: [2]f32, tri: Tri_2D) -> bool {
    for i in 0..<3  {
        base := tri[i]
        side := tri[(i+1)%3] - base
        if is_right_of_line(point - base, side) {
            return false
        }
    }
    return true
}

is_right_of_line :: #force_inline proc(point: [2]f32, line: [2]f32) -> bool {
    perp := [2]f32{line.y, -line.x}

    return linalg.dot(point, perp) > 0 && perp != {}
}

main :: proc() {
    context.logger = log.create_console_logger(opt=log.Options{
        .Level,
        .Terminal_Color,
        .Short_File_Path,
        .Line,
    })
    defer log.destroy_console_logger(context.logger)
    defer delete(g_triangles)

    rl.SetTargetFPS(60)
    rl.InitWindow(WIDTH, HEIGHT, "SoftWare Rastertizer 0.97")

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

    for !rl.WindowShouldClose() {
        mem.set(&g_target, 0, len(g_target) * size_of(g_target[0]))
        for m in g_models {
            draw_model(m)
        }
        rl.UpdateTexture(texture, &g_target)

        rl.BeginDrawing()
        rl.ClearBackground(rl.Color{126, 225, 225, 255})
        rl.DrawTexture(texture, 0, 0, rl.WHITE)
        rl.EndDrawing()

        for &m in g_models {
            m.pitch += 0.01
            m.yaw += 0.002
        }

        free_all(context.temp_allocator)
    }
}

draw_model :: proc(m: Model) {
    mtx := get_transform(m)
    for face in m.faces {
        draw_triangle(translate_face(face, mtx), m.color)
    }
}

draw_triangle :: proc(tri: Tri_3D, color: Color) {
    projected_tri := Tri_2D{tri[0].xy, tri[1].xy, tri[2].xy}
    b_box := get_triangle_bounding_box(projected_tri)
    for y := b_box.y; y < b_box.y + b_box.height; y += 1. / (HEIGHT + 1) {
        for x := b_box.x; x < b_box.x + b_box.width; x += 1. / (WIDTH + 1) {
            if is_inside_triangle({x, y}, projected_tri) {
                if px, ok := slice.get_ptr(g_target[:], int(y*HEIGHT)*WIDTH + int(x*WIDTH)); ok {
                    px^ = {
                        u8(color.r * 255),
                        u8(color.g * 255),
                        u8(color.b * 255),
                        u8(color.a * 255),
                    }
                }
            }            
        }
    }
}

get_triangle_bounding_box :: #force_inline proc(tri: Tri_2D) -> rl.Rectangle {
    box_x := min(tri[0].x, tri[1].x, tri[2].x)
    box_y := min(tri[0].y, tri[1].y, tri[2].y)
    box_width := max(tri[0].x, tri[1].x, tri[2].x) - box_x
    box_height := max(tri[0].y, tri[1].y, tri[2].y) - box_y
    return {
        x = box_x,
        y = box_y,
        width = box_width,
        height = box_height,
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
    return create_model(tris[:], position={2.5,2.5,.01}, scale=0.2, color=DEEP)
}
