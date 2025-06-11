package rasterizer

import "core:log"
import "core:fmt"
import "core:sync"
import "core:dynlib"
import "core:os/os2"
import "core:strings"
import "core:time"
import "core:thread"
import "core:mem"

import vmem "core:mem/virtual" 

dynlib_extension := fmt.aprintf(".{}", dynlib.LIBRARY_FILE_EXTENSION)

watcher_proc :: proc() {
    arena: vmem.Arena
    tmp := vmem.arena_allocator(&arena)
    for {
        hot_reload_shaders(optimized=false)

        free_all(tmp)

        time.sleep(40 * time.Millisecond)
    }
}

hot_reload_shaders :: proc(optimized: bool) {
    tmp := context.temp_allocator

    files, read_dir_err := os2.read_all_directory_by_path("shaders",  tmp)
    assert(read_dir_err == nil)

    threads := make([dynamic]^Thread, tmp)

    for &file in files {
        name := file.name

        if name == "lib.odin" || name == "_internals" || name == "_externals" { continue }

        if strings.starts_with(name, ".") { continue }

        src_last_modified: time.Time
        binary_last_modified: time.Time
        plugin_files, read_plugin_err := os2.read_all_directory_by_path(file.fullpath, tmp)
        if read_plugin_err != nil {
            error_file := fmt.tprintf("shaders/watcher_failed_to_read_{}", name)
            _, _ = os2.open(error_file, {.Create})
            continue
        }
        for f in plugin_files {
            if strings.ends_with(f.name, ".odin") {
                src_last_modified = time.Time{max(src_last_modified._nsec, f.modification_time._nsec)}
            }
            else if strings.ends_with(f.name, dynlib_extension) {
                binary_last_modified = time.Time{max(binary_last_modified._nsec, f.modification_time._nsec)}
            }
        }

        needs_recompile := binary_last_modified == {} || time.diff(binary_last_modified, src_last_modified) > 0

        if name not_in g_shaders || needs_recompile {
            t := thread.create_and_start_with_poly_data2(name, optimized,
                hot_reload_shader,
                context,
                self_cleanup=true,
            )
            append(&threads, t)
        }
    }
    thread.join_multiple(..threads[:])
}

hot_reload_shader :: proc(name: string, optimized: bool) {
    tmp := context.temp_allocator

    name := name
    optimized := optimized

    temp_file := fmt.tprintf("shaders/.{}_temp.odin", name)

    data, read_err := os2.read_entire_file_from_path("shaders/lib.odin", tmp)
    if read_err != nil {
        log.errorf("failed to read shaders/lib.odin because of Error: {}", os2.error_string(read_err))
    }

    head := strings.index(string(data), "standard\"//")
    assert(head != -1)

    patch := fmt.tprint(name, strings.repeat("/", 8, tmp), sep="\"")
    mem.copy(raw_data(data[head:]), raw_data(patch), len(patch))

    write_err := os2.write_entire_file(temp_file, data)
    if write_err != nil {
        log.errorf("failed to write {} because of Error: {}", temp_file, os2.error_string(write_err))
    }
    defer os2.remove(temp_file)

    for {
        o := "-o:speed" if optimized else "-o:none"
        dbg := "-define:debug_views=true" if name == "_debug_views" else ""
        output := fmt.tprintf("-out:shaders/{}/.{}{}", name, name, dynlib_extension)
        state, _, stderr, exec_err := os2.process_exec(
            {command={"odin","build",temp_file,"-file","-debug","-build-mode:shared",output,dbg,o}},
            allocator=tmp,
        )
        if exec_err != nil {
            log.errorf("failed to compile shaders/{} because of Error:", name, os2.error_string(exec_err))
        }
        if state.exit_code != 0 {
            log.errorf("failed to compile shaders/{}, compiler says:", name)
            fmt.println()
            fmt.print(string(stderr))
            fmt.println("END_COMPILER_TALK")
        }
        if exec_err != nil || state.exit_code != 0 {
            dummy := fmt.tprintf("shaders/{}/.dummy{}", name, dynlib_extension)
            _, _ = os2.open(dummy, {.Create})
        }
        log.infof("recompiled shaders/{}, with {}", name, o)
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
    
            if name == "_debug_views" {
                view_mode, found_view_mode := dynlib.symbol_address(lib, "g_view_mode")
                assert(found_view_mode)
                (^^ViewMode)(view_mode)^ = &g_view_mode
            }
            log.info("loaded shader", name)
        }
        if !optimized { optimized = true }
        else { break }
    }
}