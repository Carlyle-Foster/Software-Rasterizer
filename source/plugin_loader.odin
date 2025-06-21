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
import "core:path/filepath"

import vmem "core:mem/virtual"

g_should_watch := true

Time :: time.Time
Millisecond :: time.Millisecond

DYNLIB_EXTENSION :: "." + dynlib.LIBRARY_FILE_EXTENSION

g_lld_supported := false

@(init)
check_for_lld_support :: proc() {
    lld := "lld.exe" when ODIN_OS == .Windows else "lld"
    _, _, _, exec_err := os2.process_exec({command={lld}}, context.temp_allocator)

    if exec_err == nil {
        g_lld_supported = true
    }
}

watcher_proc :: proc() {
    arena: vmem.Arena
    context.temp_allocator = vmem.arena_allocator(&arena)

    log.info("SUPPORTS LLD:", g_lld_supported)

    for sync.atomic_load(&g_should_watch) {
        hot_reload_shaders(optimized=false)

        free_all(context.temp_allocator)

        time.sleep(40 * Millisecond)
    }
}

hot_reload_shaders :: proc(optimized: bool) {
    tmp := context.temp_allocator
    
    saved_work_dir, _ := os2.get_working_directory(tmp)
    os2.set_working_directory("source/shaders")
    defer os2.set_working_directory(saved_work_dir)

    files, read_dir_err := os2.read_all_directory_by_path(".",  tmp)
    assert(read_dir_err == nil)

    threads := make([dynamic]^Thread, tmp)

    for &file in files {
        name := file.name

        if name == "lib.odin" || name == "_internals" || name == "_externals" { continue }

        if strings.starts_with(name, ".") { continue }

        plugin_files, read_plugin_err := os2.read_all_directory_by_path(file.fullpath, tmp)
        if read_plugin_err != nil { continue }

        src_last_modified: Time
        binary_last_modified: Time

        last_recompile_failed := false
        for f in plugin_files {
            extension := filepath.ext(f.name)
            
            if extension == ".odin" {
                src_last_modified = Time{max(src_last_modified._nsec, f.modification_time._nsec)}
            }
            else if extension == DYNLIB_EXTENSION {
                if f.name == ("._dummy" + DYNLIB_EXTENSION) {
                    last_recompile_failed = true
                }
                binary_last_modified = Time{max(binary_last_modified._nsec, f.modification_time._nsec)}
            }
        }

        needs_recompile := binary_last_modified == {} || time.diff(binary_last_modified, src_last_modified) > 0

        if needs_recompile || (name not_in g_shaders && !last_recompile_failed) {
            t := thread.create_and_start_with_poly_data2(name, optimized,
                hot_reload_shader,
                context,
                self_cleanup=true,
            )
            assert(t != nil)
            
            append(&threads, t)
        }
    }
    //NOTE: this is a workaround for a bug in "core:threads", see https://github.com/odin-lang/Odin/issues/3924
    if len(threads) > 0 { time.sleep(Millisecond) }

    thread.join_multiple(..threads[:])
}

hot_reload_shader :: proc(name: string, optimized: bool) {
    tmp := context.temp_allocator

    name := name
    optimized := optimized

    temp_file := fmt.tprintf(".{}_temp.odin", name)

    data, read_err := os2.read_entire_file_from_path("lib.odin", tmp)
    if read_err != nil {
        log.errorf("failed to read source/shaders/lib.odin because of Error: {}", os2.error_string(read_err))
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
        dbg := "-define:debug_views=true" if name[0] == '_' else ""
        output := fmt.tprintf("-out:{}/.{}{}", name, name, DYNLIB_EXTENSION)
        linker := "-linker:lld" if g_lld_supported else "-linker:default"

        state, _, stderr, exec_err := os2.process_exec(
            {command={"odin","build",temp_file,"-file","-debug","-build-mode:shared",linker,output,dbg,o}},
            allocator=tmp,
        )
        if exec_err != nil {
            log.errorf("failed to compile source/shaders/{} because of Error:", name, os2.error_string(exec_err))
        }
        if state.exit_code != 0 {
            log.errorf("failed to compile source/shaders/{}, compiler says:", name)
            fmt.println()
            fmt.print(string(stderr))
            fmt.println("END_COMPILER_TALK")
        }

        dummy := fmt.tprintf("{}/._dummy{}", name, DYNLIB_EXTENSION)

        if exec_err != nil || state.exit_code != 0 {
            _, _ = os2.open(dummy, {.Create, .Trunc})
            return
        } else {
            _ = os2.remove(dummy)
        }

        log.infof("recompiled source/shaders/{}, with {}", name, o)

        if sync.mutex_guard(&g_shader_mutex) {
            if name in g_shaders {
                dynlib.unload_library(g_shaders[name].source)
            } else {
                name = strings.clone(name)
            }

            lib_path := output[len("-out:"):]

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

            log.info("loaded shader", name)
        }
        if !optimized { optimized = true }
        else { break }
    }
}
