package rasterizer

import "base:runtime"

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:thread"
import "core:sync"
import "core:image"
import "core:image/png"
import "core:dynlib"

import rl "vendor:raylib"

import cmn "shaders/_externals"

import "obj"


Color :: [4]f32

Image :: image.Image
Thread :: thread.Thread
Allocator :: runtime.Allocator

ShaderName :: string

g_width: i32    = 800
g_height: i32   = 600
g_last_dimensions: [2]i32

g_fov: f32 = 40

g_threads: [6]^Thread

g_selected_thread := -1

g_draw_condition: sync.Cond
g_frame_count_mutex: sync.Mutex
g_shader_mutex: sync.Mutex
g_draw_group: sync.Wait_Group
g_barrier: sync.Barrier

g_frame_count := 0 // Protected by `g_frame_count_mutex`

g_target:           [dynamic]Pixel
g_packed_target:    [dynamic][4]u8

g_shaders: map[ShaderName]Shader

EntityDrawer :: #type proc(
    faces: []Tri_3D,
    offset: int,
    stride: int,
    transform: matrix[4,4]f32,
    rotation: matrix[3, 3]f32,
    texture: ^Image,
    width: i32,
    height: i32,
    fov: f32,
)

Shader :: struct {
    run: EntityDrawer,
    source: dynlib.Library,
}

Pixel :: cmn.Pixel
Tri_3D :: cmn.Tri_3D

Model :: cmn.Model

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

main :: proc() {
    when ODIN_DEBUG {
        context.allocator = g_tracking_allocator
    }
    context.logger = log.create_console_logger(opt=log.Options{
        .Level,
        .Terminal_Color,
        .Short_File_Path,
        .Line,
    })
    defer log.destroy_console_logger(context.logger)
    defer delete_globals()

    hot_reload_shaders(optimized=true)

    model, import_ok := obj.import_file("3D models/suzanne.obj")
    assert(import_ok)
    append(&g_models, model)
    defer delete(model.faces)

    ent := create_entity(0, {0, 0, 7}, 1, "standard")
    ent.yaw = math.PI
    ent.roll = math.PI
    append(&g_entities, ent)

    texture_load_err: image.Error
    g_texture, texture_load_err = png.load_from_file("textures/drawn.png")
    assert(texture_load_err == nil)
    defer png.destroy(g_texture)

    for &t, i in g_threads {
        t = thread.create_and_start_with_data(rawptr(uintptr(i)), draw_entities, context)
    }

    watcher := thread.create_and_start(watcher_proc, context)
    defer {
        sync.atomic_store(&g_should_watch, false)
        thread.join(watcher)
        thread.destroy(watcher)
    }
    
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_TOPMOST})
    rl.InitWindow(g_width, g_height, "SoftWare Rasterizer 0.97")
    defer rl.CloseWindow()

    rl_image: rl.Image
    rl_texture: rl.Texture

    for !rl.WindowShouldClose() {
        g_width = rl.GetRenderWidth()
        g_height = rl.GetRenderHeight()
        resize(&g_target, g_width*g_height)
        resize(&g_packed_target, g_width*g_height)

        if g_width != g_last_dimensions.x || g_height != g_last_dimensions.y {
            rl_image = rl.Image {
                data = raw_data(g_packed_target[:]),
                width = g_width,
                height = g_height,
                mipmaps = 1,
                format = .UNCOMPRESSED_R8G8B8A8,
            }
            rl_texture = rl.LoadTextureFromImage(rl_image)
        }
        g_last_dimensions = {g_width, g_height}

        for key := rl.GetKeyPressed(); key != .KEY_NULL; key = rl.GetKeyPressed() {
            #partial switch key {
            case .S: g_entities[0].shader = "standard"
            case .D: g_entities[0].shader = "_depth"
            case .N: g_entities[0].shader = "_normals"
            case .F: g_entities[0].shader = "_faces"
            case .T: g_entities[0].shader = "_tex_coords"

            case .UP: g_fov     += 3 if rl.IsKeyDown(.LEFT_CONTROL) else 10
            case .DOWN: g_fov   -= 3 if rl.IsKeyDown(.LEFT_CONTROL) else 10

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
                faces := g_models[e.model].faces
                transform, rotation := get_transform_and_rotation(e)
                stride := len(g_threads)
                shader := g_shaders[e.shader] or_else g_shaders["error"]
                // All the rendering gets done here
                shader.run(
                    faces,
                    offset, stride,
                    transform, rotation,
                    g_texture,
                    g_width, g_height,
                    g_fov,
                )
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

delete_globals :: proc() {
    for t in g_threads {
        thread.terminate(t, 0)
        thread.destroy(t)
    }
    for name, shader in g_shaders {
        delete(name)
        dynlib.unload_library(shader.source)
    }
    delete(g_shaders)
    
    delete(g_models)
    delete(g_entities)
    delete(g_target)
    delete(g_packed_target)
}
