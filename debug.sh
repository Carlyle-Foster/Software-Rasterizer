#!/bin/sh

if command -v lld > /dev/null; then
    LINKER="-linker:lld"
else
    LINKER="-linker:default"
fi
echo $LINKER

odin build source -out:rasterizer -vet -debug $LINKER $@

gdb rasterizer -ex run