package rasterizer

import "core:log"
import "core:fmt"
import "core:sync"
import "core:dynlib"
import "core:os/os2"
import "core:strings"
import "core:time"
import "core:thread"

import vmem "core:mem/virtual"

ReloadStyle :: enum {
    Optimized,
    Unoptimized,
    Bootstrap,
}

hot_reload_shaders :: proc(style: ReloadStyle) -> (err: os2.General_Error) {
    files, read_dir_err := os2.read_all_directory_by_path("Shaders",  context.temp_allocator)
    assert(read_dir_err == nil)

    threads := make([dynamic]^Thread, context.temp_allocator)

    for &file in files {
        name := file.name

        if name == "common" { continue }

        t := thread.create_and_start_with_poly_data2(&file, style,
            hot_reload_shader,
            context,
            self_cleanup=true,
        )
        append(&threads, t)
    }
    if style == .Bootstrap {
        thread.join_multiple(..threads[:])
    }
    return
}

hot_reload_shader :: proc(file: ^os2.File_Info, style: ReloadStyle) {
    style := style

    arena: vmem.Arena
    context.temp_allocator = vmem.arena_allocator(&arena)
    defer free_all(context.temp_allocator)

    tmp := context.temp_allocator

    name := strings.clone(file.name, tmp)
    handle, open_err := os2.open(file.fullpath)
    if open_err != nil {
        log.errorf("failed to open file Shaders/{}", name)
    }

    dynlib_extension := fmt.tprintf(".{}", dynlib.LIBRARY_FILE_EXTENSION)

    binary: os2.File_Info
    src_last_modified: time.Time
    it := os2.read_directory_iterator_create(handle)
    for f in os2.read_directory_iterator(&it) {
        if strings.ends_with(f.name, ".odin") {
            src_last_modified = time.Time{max(src_last_modified._nsec, f.modification_time._nsec)}
        }
        else if strings.ends_with(f.name, dynlib_extension) {
            assert(binary == {})
            binary, _ = os2.file_info_clone(f, tmp)
        }
    }
    needs_recompile := binary == {} || time.diff(binary.modification_time, src_last_modified) > 0

    if name in g_shaders && !needs_recompile {
        log.infof("Shaders/{} is already up-to-date", name)
        return
    }

    temp_dir := fmt.tprintf(".{}_temp", name)
    // if any of these fail the odin compiler will catch it
    os2.make_directory(temp_dir)
    os2.symlink(fmt.tprintf("../Shaders/{}", name), fmt.tprintf("{}/plugin", temp_dir))
    os2.link("drawing/lib.odin", fmt.tprintf("{}/drawing.odin", temp_dir))
    defer os2.remove_all(temp_dir)

    for {
        o := "-o:none" if style == .Unoptimized else "-o:speed"
        dbg := "-define:debug_views=true" if name == "DEBUG" else ""
        output := fmt.tprintf("-out:Shaders/{}/.{}{}", name, name, dynlib_extension)
        if needs_recompile {
            state, _, stderr, exec_err := os2.process_exec(
                {command={"odin","build",temp_dir,o,"-debug","-build-mode:shared",output, dbg}},
                allocator=tmp,
            )
            if exec_err != nil {
                log.errorf("failed to compile Shaders/{} because of Error:", name, os2.error_string(exec_err))
                return
            }
            if state.exit_code != 0 {
                log.errorf("failed to compile Shaders/{}, compiler says:", name)
                fmt.println()
                fmt.print(string(stderr))
                fmt.println("END_COMPILER_TALK")
                return
            }
            log.infof("recompiled Shaders/{}, with {}", name, o)
        }
        lib_path := output[len("-out:"):]
        if sync.mutex_guard(&g_shader_mutex) {
            if name in g_shaders {
                dynlib.unload_library(g_shaders[name].source)
            } else {
                name = strings.clone(name)
            }
            lib, did_load := dynlib.load_library(lib_path)
            assert(did_load)
    
            target, hit := dynlib.symbol_address(lib, "g_target")
            if !hit {
                log.error(lib_path, "is missing a definition for 'g_target', pls fix")
                return
            }
            (^^[dynamic]Pixel)(target)^ = &g_target
    
            addr, found := dynlib.symbol_address(lib, "draw_entity")
            if !found {
                log.error(lib_path, "is missing a definition for 'draw_entity()', pls fix")
                return
            }
            g_shaders[name] = {run=cast(EntityDrawer)addr, source=lib}
    
            if name == "DEBUG" {
                view_mode, found_view_mode := dynlib.symbol_address(lib, "g_view_mode")
                assert(found_view_mode)
                (^^ViewMode)(view_mode)^ = &g_view_mode
            }
            log.info("loaded shader", name)
        }
        if style == .Unoptimized && needs_recompile { style = .Optimized }
        else { break }
    }
}
