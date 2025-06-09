package rasterizer

import "core:log"
import "core:fmt"
import "core:sync"
import "core:dynlib"
import "core:os/os2"
import "core:strings"
import "core:time"

import vmem "core:mem/virtual"

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
        plugin := fmt.aprintf("Shaders/{}/plugin.odin", name, allocator=arena)
        plugin_info, stat_err := os2.stat(plugin, arena)
        assert(stat_err == nil)
        if time.diff(g_shaders[file.name].last_modified, plugin_info.modification_time) > 0 {
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
        dbg := "-define:debug_views=true" if name == "DEBUG" else ""
        out_path := fmt.aprintf("-out:Shaders/{}/.{}.so", name, name, allocator=arena)
        state, _, _, exec_err := os2.process_exec(
            {command={"odin","build","drawing",o,"-debug","-build-mode:shared",out_path, dbg}},
            allocator=arena,
        )
        // log.info(string(stdout))
        // log.info(string(stderr))
        assert(exec_err == nil)
        assert(state.exit_code == 0)

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

            addr, found := dynlib.symbol_address(lib, "draw_entity")
            assert(found)
            g_shaders[name] = {run=cast(EntityDrawer)addr, source=lib, last_modified=file.modification_time}

            target, hit := dynlib.symbol_address(lib, "g_target")
            assert(hit)
            (^^[dynamic]Pixel)(target)^ = &g_target

            if name == "DEBUG" {
                view_mode, found_view_mode := dynlib.symbol_address(lib, "g_view_mode")
                assert(found_view_mode)
                (^^ViewMode)(view_mode)^ = &g_view_mode
            }

            log.info("loaded shader", name)
        }
    }
    if !optimized { _hot_reload_shaders(files, true, arena) }
    log.info()
}