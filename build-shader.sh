#!/bin/bash
# Recompile the shaders after editing them (Qt 6 needs precompiled .qsb shaders).
set -e
cd "$(dirname "$0")"
for s in waves.vert waves.frag; do
  /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o "$s.qsb" "$s"
done
