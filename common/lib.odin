package common

import "core:image"

FOV :: 40

Image :: image.Image

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

Tri_3D :: struct {
    vertices:   [3][3]f32,
    tex_coords: [3][2]f32,
    normals:    [3][3]f32,
}

Model :: struct {
    faces: []Tri_3D,
}
