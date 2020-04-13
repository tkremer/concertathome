#!/bin/sh

script="$1"

ffmpeg -hide_banner -filter_complex_script "$script" -map "[out]" -r 25 -f opengl video

