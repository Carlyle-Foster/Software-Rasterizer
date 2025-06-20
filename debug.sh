#!/bin/sh

odin build source -out:rasterizer -vet -debug -linker:lld $@

gdb rasterizer -ex run