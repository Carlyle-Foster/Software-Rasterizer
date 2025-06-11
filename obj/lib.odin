package obj

import "core:os/os2"
import "core:strings"
import "core:strconv"

import cmn "../Shaders/_externals"

Tri_3D :: cmn.Tri_3D
Model :: cmn.Model

import_file :: proc(name: string) -> (m: Model, ok: bool) {
    data, err := os2.read_entire_file_from_path(name, context.allocator)
    assert(err == nil)
    defer delete(data)
    
    contents := string(data)

    vertices    := make([dynamic][3]f32)
    normals     := make([dynamic][3]f32)
    tex_coords  := make([dynamic][2]f32)
    defer delete(vertices)
    defer delete(normals)
    defer delete(tex_coords)

    tris := make([dynamic]Tri_3D)

    for line in strings.split_lines_iterator(&contents) {
        if strings.starts_with(line, "#") { continue }
        if strings.starts_with(line, "v ") {
            rest := line[2:]
            vertex: [3]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 2 { break }
                vertex[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&vertices, vertex)
        }
        if strings.starts_with(line, "vn ") {
            rest := line[3:]
            normal: [3]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 2 { break }
                normal[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&normals, normal)
        }
        if strings.starts_with(line, "vt ") {
            rest := line[3:]
            tex_coord: [2]f32
            i := 0
            for entry in strings.split_iterator(&rest, " ") {
                if i > 1 { break }
                tex_coord[i] = strconv.parse_f32(entry) or_return
                i += 1
            }
            append(&tex_coords, tex_coord)
        }
        if strings.starts_with(line, "f ") {
            rest := line[2:]
            i := 0
            vline:  [2][3]f32
            nline:  [2][3]f32
            tcline: [2][2]f32
            for entry in strings.split_iterator(&rest, " ") {
                entry := entry
                v_i     := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return
                tc_i    := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return
                n_i     := strconv.parse_int(strings.split_iterator(&entry, "/") or_return) or_return

                vertex      := vertices[v_i - 1]
                tex_coord   := tex_coords[tc_i - 1]
                normal      := normals[n_i - 1]

                if i < 2 {
                    vline[i]    = vertex
                    tcline[i]   = tex_coord
                    nline[i]    = normal
                }
                else {
                    obj := Tri_3D{
                        vertices    = {vline[0],    vline[1],   vertex},
                        tex_coords  = {tcline[0],   tcline[1],  tex_coord},
                        normals     = {nline[0],    nline[1],   normal},
                    }
                    append(&tris, obj)
                    vline[1]    = vertex
                    tcline[1]   = tex_coord
                    nline[1]    = normal
                }
                i += 1
            }            
        }
    }
    return Model{tris[:]}, true
}
