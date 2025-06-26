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
import "core:os/os2"
import "core:strings"
import "core:path/filepath"

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

g_models: map[string]Model

Entity :: struct {
    model: string,
    position: [3]f32,
    scale: f32,
    yaw: f32,
    pitch: f32,
    roll: f32,
    shader: ShaderName,
}

g_entities: [dynamic]Entity

create_entity :: proc(model: string, position: [3]f32, scale: f32, shader: ShaderName) -> Entity {
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

calculate_entity_matrices :: proc(e: Entity) -> (all: matrix[4, 4]f32, just_rotation: matrix[3, 3]f32) {
    just_rotation = 
        linalg.matrix3_rotate(e.yaw, [3]f32{0,1,0}) * 
        linalg.matrix3_rotate(e.pitch, [3]f32{1,0,0}) * 
        linalg.matrix3_rotate(e.roll, [3]f32{0,0,1})

    all = linalg.matrix4_translate(e.position) * linalg.matrix4_scale(e.scale) * (matrix[4, 4]f32)(just_rotation)

    return
}

Camera :: struct {
    position: [3]f32,
    yaw: f32,
    pitch: f32,
    roll: f32,
}
g_camera := Camera{}

calculate_camera_direction :: proc(c: Camera) -> matrix[3, 3]f32 {
    return linalg.matrix3_rotate(c.yaw, [3]f32{0,1,0}) * 
           linalg.matrix3_rotate(c.pitch, [3]f32{1,0,0}) * 
           linalg.matrix3_rotate(c.roll, [3]f32{0,0,1})
}

calculate_camera_view_matrix :: proc(c: Camera) -> matrix[4, 4]f32 {
    rotation := calculate_camera_direction(c)

    return (matrix[4, 4]f32)(-rotation) * -linalg.matrix4_translate(-c.position)
}

g_texture: ^Image

load_models :: proc() {
    files, read_dir_error := os2.read_all_directory_by_path("3D models", context.temp_allocator)
    assert(read_dir_error == nil)

    for f in files {
        model, import_ok := obj.import_file(f.fullpath)
        if !import_ok {
            log.errorf("failed to import '3D models/{}'", f.name)
        }
        name := strings.clone(filepath.short_stem(f.name))

        g_models[name] = model
    }
}

Sound_ID :: enum {
    Selector,
    Select,
}
g_sounds: [Sound_ID]rl.Sound

// pitch_range is in 10th cents
play_sound :: proc(id: Sound_ID, pitch_range: i32 = 0) {
    sound := g_sounds[id]

    rl.SetSoundPitch(sound, f32(rl.GetRandomValue(1000 - pitch_range, 1000 + pitch_range)) / 1000)

    rl.PlaySound(sound)
}

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

    load_models()

    for i in 0..<2 {
        ent := create_entity("suzanne", {0, 0, 7}, 1, "standard")
        ent.yaw = math.PI
        ent.roll = math.PI * f32(i)
        append(&g_entities, ent)
    }

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

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.SetMasterVolume(0.2)

    background_track := rl.LoadMusicStream("sounds/background track.mp3")
    background_track.looping = true
    //TODO: this crashes sometimes
    rl.SeekMusicStream(background_track, f32(rl.GetRandomValue(0, 60)))
    defer rl.UnloadMusicStream(background_track)

    rl.PlayMusicStream(background_track)

    g_sounds = {
        .Selector = rl.LoadSound("sounds/selector.mp3"),
        .Select = rl.LoadSound("sounds/select.mp3"),
    }

    shader_icon := rl.LoadTexture("icons/shader icon.png")
    model_icon := rl.LoadTexture("icons/3D model icon.png")

    rl_image: rl.Image
    rl_texture: rl.Texture

    for !rl.WindowShouldClose() {
        rl.UpdateMusicStream(background_track)

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

        move_speed := f32(.25)
        look_direction := calculate_camera_direction(g_camera)
        movement := [3]f32{0, 0, move_speed} * look_direction

        is_precise := rl.IsKeyDown(.LEFT_CONTROL)

        // Controls
        for key := rl.GetKeyPressed(); key != .KEY_NULL; key = rl.GetKeyPressed() {
            #partial switch key {
            case .S: set_global_shader("standard")
            case .D: set_global_shader("_depth")
            case .N: set_global_shader("_normals")
            case .F: set_global_shader("_faces")
            case .T: set_global_shader("_tex_coords")

            case .UP: g_fov     += 3 if is_precise else 10
            case .DOWN: g_fov   -= 3 if is_precise else 10

            case .ZERO..=.SIX: g_selected_thread = int(key - .ONE)
            }
        }
        if rl.IsKeyDown(.KP_8) { g_camera.pitch    -= math.PI / 10 / (48 if is_precise else 24) }
        if rl.IsKeyDown(.KP_2) { g_camera.pitch    += math.PI / 10 / (48 if is_precise else 24) }
        if rl.IsKeyDown(.KP_4) { g_camera.yaw      += math.PI / 10 / (48 if is_precise else 24) }
        if rl.IsKeyDown(.KP_6) { g_camera.yaw      -= math.PI / 10 / (48 if is_precise else 24) }

        if rl.IsKeyDown(.U) { g_camera.position += movement }
        if rl.IsKeyDown(.J) { g_camera.position -= movement }
        if rl.IsKeyDown(.H) { g_camera.position += movement * linalg.matrix3_rotate(math.PI/2, [3]f32{0, 1, 0}) }
        if rl.IsKeyDown(.K) { g_camera.position -= movement * linalg.matrix3_rotate(math.PI/2, [3]f32{0, 1, 0}) }

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

        /// draw the UI
        button_rect := rl.Rectangle{}

        button_rect.width = f32(g_width) * .2
        button_rect.height = f32(g_width) * .04

        pad_left := f32(g_width) * .03
        pad_top := f32(g_height) * .04

        selector_pad := button_rect.width / 10

        selector_width := (button_rect.width - selector_pad * (2 - 1)) / 2
        selector_height := button_rect.height

        selector_icons := []rl.Texture{shader_icon, model_icon}

        @(static) selected_selector := 0

        i := 0
        for x := pad_left; x < pad_left + button_rect.width; x += selector_width + selector_pad {
            icon_rect := rl.Rectangle{x=x, y=pad_top, width=selector_width, height=selector_height}

            // rl.DrawRectangleRec(icon_rect, {245, 245, 245, 255})

            icon_scale := min(selector_width, selector_height) / 128
            icon_position := rl.Vector2{icon_rect.x, icon_rect.y}
            icon_position.x += max(selector_width - selector_height, 0) / 2
            icon_position.y += max(selector_height - selector_width, 0) / 2

            center := rl.Vector2{icon_rect.x + icon_rect.width/2, icon_rect.y + icon_rect.height/2}
            radius := icon_rect.height / 2.3 * 1.5

            selector_color := rl.Color{ 135, 50, 175, 72 }

            if selected_selector == i {
                selector_color.a += 48
                rl.DrawCircleV(center, radius / 1.5, selector_color)
            }
            rl.DrawCircleV(center, radius, selector_color)
            rl.DrawTextureEx(selector_icons[i], icon_position, 0, icon_scale, rl.WHITE)

            if rl.CheckCollisionPointCircle(rl.GetMousePosition(), center, radius * 1.33) {
                if rl.IsMouseButtonPressed(.LEFT) {
                    selected_selector = i

                    play_sound(.Selector, pitch_range=15)
                }
            }

            i += 1
        }

        i = 1
        if selected_selector == 0 {
            for shader_name, _ in g_shaders {
                if shader_name[0] == '_' { continue }

                button_rect.x = pad_left
                button_rect.y = f32((button_rect.height + pad_top) * f32(i)) + pad_top

                color := rl.Color{ 245, 245, 245, 255 }

                selected := g_entities[0].shader == shader_name

                if draw_fancy_button(button_rect, shader_name, color, selected) {
                    set_global_shader(shader_name)

                    play_sound(.Select, pitch_range=10)
                }

                i += 1
            }
        } else {
            for model_name, _ in g_models {    
                button_rect.x = pad_left
                button_rect.y = f32((button_rect.height + pad_top) * f32(i)) + pad_top

                color := rl.Color{ 245, 245, 245, 255 }

                selected := g_entities[0].model == model_name

                if draw_fancy_button(button_rect, model_name, color, selected) {
                    set_global_model(model_name)

                    play_sound(.Select, pitch_range=10)
                }

                i += 1
            }
        }

        rl.EndDrawing()

        for &e, _ in g_entities {
            s := f32(1)
            e.pitch += 0.01 / s * .3
            e.yaw += 0.02 * s   * .3
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
                transform, rotation := calculate_entity_matrices(e)
                cam_transform := calculate_camera_view_matrix(g_camera)
                transform = cam_transform * transform
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

set_global_shader :: proc(shader_name: string) {
    if sync.mutex_guard(&g_shader_mutex) {
        for &entity in g_entities {
            entity.shader = shader_name
        }
    }
}

set_global_model :: proc(model_name: string) {
    if sync.mutex_guard(&g_shader_mutex) {
        for &entity in g_entities {
            entity.model = model_name
        }
    }
}

draw_fancy_button ::proc(r: rl.Rectangle, text: string, color: rl.Color, selected: bool) -> (was_clicked: bool) {
    color := color

    text_cstr := strings.clone_to_cstring(text, context.temp_allocator)

    font_size := min(g_width, g_height) / 30

    text_x := i32(r.x) + i32((r.width - f32(rl.MeasureText(text_cstr, i32(font_size))))) / 2
    text_y := i32(r.y) + (i32(r.height) - font_size) / 2

    text_color := rl.GetColor(0x361818ff)

    portrusion := f32(4)

    corners: [4]rl.Rectangle

    if rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {
        corners = get_rectangle_corners(r, portrusion / 2, r.height * .2)
        for corner in corners {
            shadow := get_rectangle_drop_shadow(corner)
            shadow_color := text_color
            shadow_color.a /= 2
            rl.DrawRectangleRec(shadow, shadow_color)
            rl.DrawRectangleRec(shadow, shadow_color)
        }
        if rl.IsMouseButtonDown(.LEFT) {
            value :: 24
            color = { value, value, value, 255 }
        }
        if rl.IsMouseButtonPressed(.LEFT) {
            was_clicked = true
        }
    }
    shadow_value :: 89
    shadow_color := rl.Color{ shadow_value, shadow_value, shadow_value, 255}
    if selected {
        text_color = { 180, 122, 232, 255 }

        shadow_color = text_color
        shadow_color.rgb /= 2

        corners = get_rectangle_corners(r, portrusion, r.height * .2)
    }
    // drop-shadows
    for corner in corners {
        if corner == {} { continue }

        rl.DrawRectangleRec(get_rectangle_drop_shadow(corner), shadow_color)
    }
    rl.DrawRectangleRec(get_rectangle_drop_shadow(r), shadow_color)

    for corner in corners {
        rl.DrawRectangleRec(corner, text_color)
    }
    rl.DrawRectangleRec(r, color)

    rl.DrawText(text_cstr, text_x, text_y, i32(font_size), text_color)

    return
}

@(require_results)
get_rectangle_corners :: proc(r: rl.Rectangle, portrusion: f32, gap: f32) -> [4]rl.Rectangle {
    size := portrusion + gap

    tl := rl.Rectangle {
        width = size,
        height = size,
        x = r.x - portrusion,
        y = r.y - portrusion,
    }
    tr := rl.Rectangle {
        width = size,
        height = size,
        x = r.x + portrusion + (r.width - size),
        y = r.y - portrusion,
    }

    bl := rl.Rectangle {
        width = size,
        height = size,
        x = r.x - portrusion,
        y = r.y + portrusion + (r.height - size),
    }

    br := rl.Rectangle {
        width = size,
        height = size,
        x = r.x + portrusion + (r.width - size),
        y = r.y + portrusion + (r.height - size),
    }

    return {
        tl, tr,
        bl, br,
    }
}

@(require_results)
get_rectangle_drop_shadow :: proc(r: rl.Rectangle) -> rl.Rectangle {
    shadow := r
    shadow.x += f32(g_width) * .007
    shadow.y += f32(g_height) * .007

    return shadow
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

    delete(g_entities)

    for name, m in g_models {
        delete(name)
        delete(m.faces)
    }
    delete(g_models)

    delete(g_packed_target)
    delete(g_target)

    for s in g_sounds {
        rl.UnloadSound(s)
    }
}
