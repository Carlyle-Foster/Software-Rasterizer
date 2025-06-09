#!/bin/sh

odin build . -vet -debug $1

gdb rasterizer -ex run