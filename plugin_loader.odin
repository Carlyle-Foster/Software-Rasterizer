package rasterizer

import "core:log"
import "core:fmt"
import "core:sync"
import "core:dynlib"
import "core:os/os2"
import "core:strings"
import "core:time"

import vmem "core:mem/virtual"

ReloadStyle :: enum {
    Unoptimized,
    Optimized,
    Late_Optimized,
}

hot_reload_shaders :: proc(style: ReloadStyle) -> (err: os2.General_Error) {
    arena_: vmem.Arena
    arena := vmem.arena_allocator(&arena_)
    defer free_all(arena)

    files, read_dir_err := os2.read_all_directory_by_path("Shaders",  arena)
    assert(read_dir_err == nil)

    shaders := make([dynamic]os2.File_Info, allocator=arena)

    for &file in files {
        name := file.name

        if name == "common" || name == ".current_plugin" { continue }

        plugin_name := fmt.aprintf("Shaders/{}/plugin.odin", name, allocator=arena)
        plugin, stat_err := os2.stat(plugin_name, arena)
        if stat_err != nil {
            if stat_err.(os2.General_Error) == .Not_Exist {
                log.errorf("Shaders/{} is missing it's 'plugin.odin' file", name)
            } else {
                log.error("failed to read ", plugin_name, " because of Error:", os2.error_string(stat_err))
            }
            continue
        }
        file.modification_time = plugin.modification_time

        if name not_in g_shaders {
            append(&shaders, file)
            continue
        }
        if time.diff(g_shaders[file.name].last_modified, file.modification_time) > 0 {
            append(&shaders, file)
        }
    }
    _hot_reload_shaders(shaders[:], style, arena)
    return
}

_hot_reload_shaders :: proc(files: []os2.File_Info, style: ReloadStyle, arena: Allocator) {
    CURRENT_PLUGIN :: "Shaders/.current_plugin"

    for file in files {
        name := file.name
        // we've seen all the errors on the unoptimized run, so skip 'em this time
        silent := style == .Late_Optimized

        remove_err := os2.remove(CURRENT_PLUGIN)
        assert(remove_err == nil || remove_err.(os2.General_Error) == .Not_Exist)
        os2.symlink(file.fullpath, CURRENT_PLUGIN)

        o := "-o:none" if style == .Unoptimized else "-o:speed"
        dbg := "-define:debug_views=true" if name == "DEBUG" else ""
        out_path := fmt.aprintf("-out:Shaders/{}/.{}.so", name, name, allocator=arena)
        state, _, stderr, exec_err := os2.process_exec(
            {command={"odin","build","drawing",o,"-debug","-build-mode:shared",out_path, dbg}},
            allocator=arena,
        )
        if exec_err != nil {
            if silent { continue }
            log.errorf("failed to compile Shaders/{} because of Error:", name, os2.error_string(exec_err))
            continue
        }
        if state.exit_code != 0 {
            if silent { continue }
            log.errorf("failed to compile Shaders/{}, compiler says:", name)
            fmt.println()
            fmt.print(string(stderr))
            fmt.println("END_COMPILER_TALK")
            continue
        }

        lib_path := out_path[len("-out:"):]
        log.info("recompiled", lib_path, "with", o)

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
                if silent { continue }
                log.error(lib_path, "is missing a definition for 'g_target', pls fix")
                continue
            }
            (^^[dynamic]Pixel)(target)^ = &g_target

            addr, found := dynlib.symbol_address(lib, "draw_entity")
            if !found {
                if silent { continue }
                log.error(lib_path, "is missing a definition for 'draw_entity()', pls fix")
                continue
            }
            g_shaders[name] = {run=cast(EntityDrawer)addr, source=lib, last_modified=file.modification_time}

            if name == "DEBUG" {
                view_mode, found_view_mode := dynlib.symbol_address(lib, "g_view_mode")
                assert(found_view_mode)
                (^^ViewMode)(view_mode)^ = &g_view_mode
            }
            log.info("loaded shader", name)
        }
    }
    if style == .Unoptimized { _hot_reload_shaders(files, .Late_Optimized, arena) }
    fmt.println()
}
