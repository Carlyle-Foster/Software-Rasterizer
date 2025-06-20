package rasterizer

import "core:fmt"
import "core:mem"

g_tracking_allocator: Allocator

_g_track: mem.Tracking_Allocator

@(init)
tracking_allocator_init :: proc() {
    mem.tracking_allocator_init(&_g_track, context.allocator)
    g_tracking_allocator = mem.tracking_allocator(&_g_track)
}

@(fini)
tracking_allocator_fini :: proc() {
    if len(_g_track.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed: ===\n", len(_g_track.allocation_map))
        for _, entry in _g_track.allocation_map {
            fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    mem.tracking_allocator_destroy(&_g_track)
}
