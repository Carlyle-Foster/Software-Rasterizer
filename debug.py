#!/bin/env python3

from sys import argv
from subprocess import run
from platform import system
from shutil import which

linker = "lld"
if which('lld' + (".exe" if system() == 'Windows' else '')) is None:
    linker = "default"
    print("debug.py: couldn't find lld (the LLVM linker), falling back to default linker")

run(['odin','build','source','-out:rasterizer','-vet','-debug',f'-linker:{linker}',   *argv[1:]])

run(['gdb','rasterizer','-ex','run'])
