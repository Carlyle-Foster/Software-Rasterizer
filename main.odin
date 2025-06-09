package rasterizer

import "base:runtime"

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
import "core:strings"
import "core:time"

import vmem "core:mem/virtual"

import "core:os"
_ :: os

import rl "vendor:raylib"


// NOTE: keep this up-to-date with `drawing/lib.odin`
// at least until we have something better going..
WIDTH :: 800
HEIGHT :: 600
FOV :: 40

Color :: [4]f32

Image :: image.Image
Thread :: thread.Thread
Allocator :: runtime.Allocator

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

g_shaders: map[ShaderName]Shader

TriangleDrawer :: #type proc(
    tri: Tri_3D,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    debug_color: [4]u8,
    view_mode: ViewMode,
    texture: ^Image,
)

Shader :: struct {
    run: TriangleDrawer,
    source: dynlib.Library,
    last_modified: time.Time,
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

    hot_reload_shaders(true)
    defer delete(g_shaders)
    defer for name, shader in g_shaders {
        delete(name)
        dynlib.unload_library(shader.source)
    }

    model, import_ok := import_obj_file("suzanne.obj")
    assert(import_ok)
    defer delete(model.faces)
    append(&g_models, model)

    ent := create_entity(0, {0, 0, 7}, 1, "standard")
    ent.yaw = math.PI
    ent.roll = math.PI
    append(&g_entities, ent)

    texture_load_err: image.Error
    g_texture, texture_load_err = png.load_from_file("drawn.png")
    assert(texture_load_err == nil)
    defer png.destroy(g_texture)

    for &t, i in g_threads {
        t = thread.create_and_start_with_data(rawptr(uintptr(i)), draw_entities, context)
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

            case .R: thread.run(proc(){ hot_reload_shaders(false) }, context)

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
                shader := g_shaders[e.shader] or_else g_shaders["error"]
                faces := g_models[e.model].faces
                num_faces := len(faces)
                stride := len(g_threads)
    
                // All the rendering gets done here
                for i := offset; i < num_faces; i += stride {
                    face := faces[i]
                    c := transmute([4]u8)(u32((f32(i) / f32(num_faces)) * 16_000_000))
                    debug_color := [4]u8{c.r, c.g, c.b, 255}

                    shader.run(face, transform, rotation, debug_color, g_view_mode, g_texture)
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

hot_reload_shaders :: proc(optimized: bool) {
    arena_: vmem.Arena
    arena := vmem.arena_allocator(&arena_)
    defer free_all(arena)

    files, read_dir_err := os2.read_all_directory_by_path("Shaders",  arena)
    assert(read_dir_err == nil)

    shaders := make([dynamic]os2.File_Info, allocator=arena)

    for file in files {
        name := file.name

        if name == "common" || name == ".current_plugin" { continue }
        if name not_in g_shaders {
            append(&shaders, file)
            continue
        }
        if time.diff(g_shaders[file.name].last_modified, file.modification_time) > 0 {
            append(&shaders, file)
        }
    }
    _hot_reload_shaders(shaders[:], optimized, arena)
}

_hot_reload_shaders :: proc(files: []os2.File_Info, optimized: bool, arena: Allocator) {
    CURRENT_PLUGIN :: "Shaders/.current_plugin"

    for file in files {
        name := file.name

        remove_err := os2.remove(CURRENT_PLUGIN)
        assert(remove_err == nil || remove_err.(os2.General_Error) == .Not_Exist)
        os2.symlink(file.fullpath, CURRENT_PLUGIN)

        o := "-o:speed" if optimized else "-o:none"
        out_path := fmt.aprintf("-out:Shaders/{}/.{}.so", name, name, allocator=arena)
        state, _, _, exec_err := os2.process_exec(
            {command={"odin","build","drawing",o,"-debug","-build-mode:shared",out_path}},
            allocator=arena,
        )
        assert(exec_err == nil)
        assert(state.exit_code == 0)
        log.info("recompiled", out_path, "with", o)

        if sync.mutex_guard(&g_shader_mutex) {
            if name in g_shaders {
                dynlib.unload_library(g_shaders[name].source)
            } else {
                name = strings.clone(name)
            }
            lib_name := fmt.aprintf("Shaders/{}/.{}.so", name, name, allocator=arena)
            log.info("loading", lib_name)
            lib, did_load := dynlib.load_library(lib_name)
            assert(did_load)

            addr, found := dynlib.symbol_address(lib, "draw_triangle")
            assert(found)
            g_shaders[name] = {run=cast(TriangleDrawer)addr, source=lib, last_modified=file.modification_time}

            target, hit := dynlib.symbol_address(lib, "g_target")
            assert(hit)
            (^^[WIDTH*HEIGHT]Pixel)(target)^ = &g_target
            
            log.info("loaded shader", name)
        }
    }
    if !optimized { _hot_reload_shaders(files, true, arena) }
    log.info()
}
