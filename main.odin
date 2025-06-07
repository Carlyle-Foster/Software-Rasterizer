package rasterizer

import "core:log"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:thread"
import "core:sync"

import rl "vendor:raylib"
// import sdl "vendor:sdl3"
// import gl "vendor:OpenGL"

GL_VERSION_MAJOR :: 3
GL_VERSION_MINOR :: 3

Color :: [4]f32

Thread :: thread.Thread

g_threads: [6]^Thread

g_selected_thread := -1

g_draw_condition: sync.Cond
g_draw_mutex: sync.Mutex
g_draw_group: sync.Wait_Group

g_go_render := false // Protected by `g_draw_mutex`

g_target:           [WIDTH*HEIGHT]Pixel
g_packed_target:    [WIDTH*HEIGHT][4]u8

Pixel :: struct {
    color: [4]u8,
    depth: f32,
}
#assert(size_of(Pixel) == size_of(u64))

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
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }
    }
    context.logger = log.create_console_logger(opt=log.Options{
        .Level,
        .Terminal_Color,
        .Short_File_Path,
        .Line,
    })
    defer log.destroy_console_logger(context.logger)
    
    defer delete(g_models)
    defer delete(g_entities)

    model, import_ok := import_obj_file("suzanne.obj")
    assert(import_ok)
    defer delete(model.faces)
    append(&g_models, model)

    ent := create_entity(0, {0, 0, 3}, 1, DEEP)
    ent.yaw = math.PI
    ent.roll = math.PI
    append(&g_entities, ent)

    for &t, i in g_threads {
        t = thread.create_and_start_with_data(rawptr(uintptr(i)), draw_entities)
    }
    defer {
        for t in g_threads {
            thread.terminate(t, 0)
            thread.destroy(t)
        }
    }

    last_frame := time.tick_now()

    rl.SetTargetFPS(60)
    rl.InitWindow(WIDTH, HEIGHT, "SoftWare Rasterizer 0.97")
    defer rl.CloseWindow()

    rl_image := rl.Image {
        data = raw_data(g_packed_target[:]),
        width = WIDTH,
        height = HEIGHT,
        mipmaps = 1,
        format = .UNCOMPRESSED_R8G8B8A8,
    }
    rl_texture := rl.LoadTextureFromImage(rl_image)

    for !rl.WindowShouldClose() {
		duration := time.tick_since(last_frame)
		t := time.duration_milliseconds(duration)
        // log.info("frame lasted", t, "millis")
        last_frame = time.tick_now()
        _ = t

        for key := rl.GetKeyPressed(); key != .KEY_NULL; key = rl.GetKeyPressed() {
            #partial switch key {
            case .S: g_view_mode = .Standard
            case .D: g_view_mode = .Depth
            case .N: g_view_mode = .Normals
            case .F: g_view_mode = .Faces

            case .ZERO..=.SIX: g_selected_thread = int(key - .ONE)
            }
        }
        for &px in g_target {
            px = {
                color = {128, 230, 230, 255},
                depth = math.INF_F32,
            }
        }
        sync.wait_group_add(&g_draw_group, len(g_threads))
        //TODO: are these guards really necessary?
        if sync.mutex_guard(&g_draw_mutex) {
            g_go_render = true
        }
        sync.cond_broadcast(&g_draw_condition)
        sync.wait_group_wait(&g_draw_group)
        if sync.mutex_guard(&g_draw_mutex) {
            g_go_render = false
        }
        for px, i in g_target {
            g_packed_target[i] = px.color
        }
        rl.UpdateTexture(rl_texture, rl_image.data)

        rl.BeginDrawing()
        rl.DrawTexture(rl_texture, 0, 0, rl.WHITE)
        rl.EndDrawing()

        for &e, i in g_entities {
            s := f32(i+1)
            e.pitch += 0.01 / s
            e.yaw += 0.02 * s
        }

        free_all(context.temp_allocator)
    }
}

draw_entities :: proc(offset: rawptr) {
    offset := int(uintptr(offset))
    for {
        wait: for {
            if sync.mutex_guard(&g_draw_mutex) {
                sync.cond_wait(&g_draw_condition, &g_draw_mutex)
                
                // this check detects spurious wakeups
                if g_go_render { break }
            }
        }
        if g_selected_thread > -1 && g_selected_thread != offset {
            sync.wait_group_done(&g_draw_group)
            continue
        } 
        for e in g_entities {
            mtx := get_transform(e)
            faces := g_models[e.model].faces
            num_faces := len(faces)
            stride := len(g_threads)

            // All the real work gets done here
            for i := offset; i < num_faces; i += stride {
                face := faces[i]
                c := transmute([4]u8)(u32((f32(i) / f32(num_faces)) * 16_000_000))
                color := [4]u8{c.r, c.g, c.b, 255}
                draw_triangle(face, mtx, color)
            }
        }
        sync.wait_group_done(&g_draw_group)
    }
}

// This is thread-safe!
draw_triangle :: #force_inline  proc(tri: Tri_3D, transform: matrix[4,4]f32, color: [4]u8) #no_bounds_check {
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
            opx := g_target[i]
            if yes && depth < opx.depth {
                npx := Pixel{depth=depth}

                switch g_view_mode {
                case .Standard:
                    unimplemented()
                case .Depth:
                    v := u8(depth/5*255)
                    npx.color = {v,v,v,255}
                case .Normals:
                    normal := tri.normals[0] / 2 + {.5, .5, .5}
                    npx.color = [4]u8{u8(normal.x*255), u8(normal.y*255), u8(normal.z*255), 255}
                case .Faces:
                    npx.color = color
                }
                for {
                    opx_, ok := sync.atomic_compare_exchange_weak(cast(^u64)&g_target[i], transmute(u64)opx, transmute(u64)npx)
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

world_to_screen :: #force_inline proc(point: [3]f32) -> [2]i32 {
    height_of_view := math.tan(math.to_radians_f32(FOV) / 2) * 2
    px_per_world_unit := HEIGHT / height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + WIDTH / 2, i32(p.y) + HEIGHT / 2}
}
