#!/bin/sh

ffmpeg -hide_banner -filter_complex_script vconductor.ffmpeg -map "[out]" -r 200 -f image2 sample_frames/%04d.png

