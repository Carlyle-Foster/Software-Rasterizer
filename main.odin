package rasterizer

import "core:log"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:thread"
import "core:sync"
import "core:image"
import "core:image/png"
import "core:dynlib"
import "core:os/os2"

import rl "vendor:raylib"


WIDTH :: 800
HEIGHT :: 600

FOV :: 40

Color :: [4]f32

Image :: image.Image
Thread :: thread.Thread

ShaderName :: string

g_threads: [6]^Thread

g_selected_thread := -1

g_draw_condition: sync.Cond
g_frame_count_mutex: sync.Mutex
g_shader_mutex: sync.Mutex
g_draw_group: sync.Wait_Group
g_barrier: sync.Barrier

g_frame_count := 0 // Protected by `g_frame_count_mutex`

g_target:           [WIDTH*HEIGHT]Pixel
g_packed_target:    [WIDTH*HEIGHT][4]u8

ShaderInput :: struct {
    normal: [3]f32,
    tex_coord: [2]f32,
    depth: f32,
    texture: ^Image,
}
FragShader :: #type proc(using SI: ShaderInput) -> (color: [4]f32)

Symbols :: struct {
    shaders: ^map[ShaderName]FragShader,

    __handle: dynlib.Library,
}
g_shared: Symbols

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

g_view_mode := ViewMode.Standard

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
    shader: ShaderName,
}

g_entities: [dynamic]Entity

create_entity :: proc(model: int, position: [3]f32, scale: f32, shader: ShaderName) -> Entity {
    return {
        model=model,
        position=position,
        scale=scale,
        yaw=0,
        pitch=0,
        roll=0,
        shader=shader,
    }
}

get_transform_and_rotation :: proc(e: Entity) -> (transform: matrix[4, 4]f32, rotation: matrix[3, 3]f32) {
    rotation = 
        linalg.matrix3_rotate(e.yaw, [3]f32{0,1,0}) * 
        linalg.matrix3_rotate(e.pitch, [3]f32{1,0,0}) * 
        linalg.matrix3_rotate(e.roll, [3]f32{0,0,1})

    transform = linalg.matrix4_translate(e.position) * linalg.matrix4_scale(e.scale) * (matrix[4, 4]f32)(rotation)

    return
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

g_texture: ^Image

sample_texture :: #force_inline proc(tex: ^Image, tex_coord: [2]f32) -> [4]f32 {
    tc := tex_coord
    tc.y = 1. - tc.y
    coord := tc - math.F32_EPSILON // Ensures it's not exactly 1
    x := int(max(coord.x, 0) * f32(tex.width))
    y := int(max(coord.y, 0) * f32(tex.height))

    buf := cast([^][4]u8)(raw_data(tex.pixels.buf[:]))

    c := buf[y*tex.width + x]

    return linalg.vector4_srgb_to_linear([4]f32{f32(c.r)/255, f32(c.g)/255, f32(c.b)/255, f32(c.a)/255})
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

    hot_reload_shaders()
    defer dynlib.unload_library(g_shared.__handle)

    model, import_ok := import_obj_file("suzanne.obj")
    assert(import_ok)
    defer delete(model.faces)
    append(&g_models, model)

    ent := create_entity(0, {0, 0, 7}, 1, "default")
    ent.yaw = math.PI
    ent.roll = math.PI
    append(&g_entities, ent)

    texture_load_err: image.Error
    g_texture, texture_load_err = png.load_from_file("drawn.png")
    assert(texture_load_err == nil)
    defer png.destroy(g_texture)

    for &t, i in g_threads {
        t = thread.create_and_start_with_data(rawptr(uintptr(i)), draw_entities)
    }
    defer {
        for t in g_threads {
            thread.terminate(t, 0)
            thread.destroy(t)
        }
    }

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
        for key := rl.GetKeyPressed(); key != .KEY_NULL; key = rl.GetKeyPressed() {
            #partial switch key {
            case .S: g_view_mode = .Standard
            case .D: g_view_mode = .Depth
            case .N: g_view_mode = .Normals
            case .F: g_view_mode = .Faces

            case .ZERO..=.SIX: g_selected_thread = int(key - .ONE)

            case .R: thread.run(hot_reload_shaders)

            }
        }
        for &px in g_target {
            px = {
                color = {128, 230, 230, 255},
                depth = math.INF_F32,
            }
        }
        sync.wait_group_add(&g_draw_group, len(g_threads))
        sync.barrier_init(&g_barrier, len(g_threads))
        if sync.mutex_guard(&g_shader_mutex) {
            if sync.mutex_guard(&g_frame_count_mutex) {
                g_frame_count += 1
            }
            sync.cond_broadcast(&g_draw_condition)
            sync.wait_group_wait(&g_draw_group)
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
    last_frame: int
    if sync.mutex_guard(&g_frame_count_mutex) {
        last_frame = g_frame_count
    }
    for {
        wait: for {
            if sync.mutex_guard(&g_frame_count_mutex) {
                if g_frame_count != last_frame {
                    last_frame = g_frame_count
                    break
                }

                sync.cond_wait(&g_draw_condition, &g_frame_count_mutex)
            }
        }
        if g_selected_thread == -1 || g_selected_thread == offset {
            for e in g_entities {
                transform, rotation := get_transform_and_rotation(e)
                shader := g_shared.shaders[e.shader] or_else g_shared.shaders["error"]
                faces := g_models[e.model].faces
                num_faces := len(faces)
                stride := len(g_threads)
    
                // All the rendering gets done here
                for i := offset; i < num_faces; i += stride {
                    face := faces[i]
                    c := transmute([4]u8)(u32((f32(i) / f32(num_faces)) * 16_000_000))
                    debug_color := [4]u8{c.r, c.g, c.b, 255}

                    draw_triangle(face, transform, rotation, shader, debug_color)
                }
            }
        }        
        // Threads share the work of packing the data
        px_per_thread := len(g_target) / len(g_threads)
        px_remaining := len(g_target) % len(g_threads)

        px_start := offset * px_per_thread
        px_end := px_start + px_per_thread

        if offset == len(g_threads)-1 {
            px_end += px_remaining
        }
        // We wait until the image has finished rendering
        sync.barrier_wait(&g_barrier)
        for i := px_start; i < px_end; i += 1 {
            g_packed_target[i] = g_target[i].color
        }
        sync.wait_group_done(&g_draw_group)
    }
}

// This is thread-safe!
draw_triangle :: #force_inline proc(
    tri: Tri_3D,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    shader: FragShader,
    debug_color: [4]u8,
) #no_bounds_check {
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

                switch g_view_mode {
                case .Standard:
                    normal = normal * linalg.transpose(rotation)

                    rgba := shader({normal, tex_coord, depth, g_texture})

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

world_to_screen :: #force_inline proc(point: [3]f32) -> [2]i32 {
    height_of_view := math.tan(math.to_radians_f32(FOV) / 2) * 2
    px_per_world_unit := HEIGHT / height_of_view / point.z

    p := point.xy * px_per_world_unit
    
    return {i32(p.x) + WIDTH / 2, i32(p.y) + HEIGHT / 2}
}

hot_reload_shaders :: proc() {
    state, stdout, stderr, exec_err := os2.process_exec(
        {command={"odin","build","Shaders/","-debug","-build-mode:shared"}},
        context.allocator,
    )
    assert(exec_err == nil)
    assert(state.exit_code == 0)
    delete(stdout)
    delete(stderr)
    
    if sync.mutex_guard(&g_shader_mutex) {
        if g_shared.__handle != nil {
            dynlib.unload_library(g_shared.__handle)
            g_shared.__handle = nil
        }
        count, dyn_load_ok := dynlib.initialize_symbols(&g_shared, "Shaders.so")
        assert(dyn_load_ok)
        assert(count > 0)
        
        log.info("loaded shaders")
    }
}
