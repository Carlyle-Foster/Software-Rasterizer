#!/bin/sh

odin build . -vet -debug -linker:lld $1

gdb rasterizer -ex run