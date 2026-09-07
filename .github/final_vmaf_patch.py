#!/usr/bin/env python3
from pathlib import Path
import subprocess

core_path = Path('lib/hardcore-archive-core.sh')
core = core_path.read_text()
old = r'''    [[ $rotation =~ ^-?[0-9]+$ ]] || rotation=0
    rotation=$(( (rotation % 360 + 360) % 360 ))
    case $rotation in
        90|270)
            display_width=$(LC_NUMERIC=C awk -v h="$coded_height" -v n="$sar_num" -v d="$sar_den" \
                'BEGIN {printf "%.9f", h*d/n}')
            display_height=$coded_width
            ;;
        *)
            display_width=$(LC_NUMERIC=C awk -v w="$coded_width" -v n="$sar_num" -v d="$sar_den" \
                'BEGIN {printf "%.9f", w*n/d}')
            display_height=$coded_height
            ;;
    esac
'''
new = r'''    [[ $rotation =~ ^-?[0-9]+$ ]] || rotation=0
    rotation=$(( (rotation % 360 + 360) % 360 ))
    # First construct the viewed square-pixel raster, then rotate that canvas.
    # For example 720x576 at SAR 16:15 is 768x576, or 576x768 when rotated 90°.
    display_width=$(LC_NUMERIC=C awk -v w="$coded_width" -v n="$sar_num" -v d="$sar_den" \
        'BEGIN {printf "%.9f", w*n/d}')
    display_height=$coded_height
    if (( rotation == 90 || rotation == 270 )); then
        local swapped=$display_width
        display_width=$display_height
        display_height=$swapped
    fi
'''
if core.count(old) != 1:
    raise SystemExit(f'rotation block count was {core.count(old)}, expected 1')
core = core.replace(old, new, 1)
core_path.write_text(core)
subprocess.run(['bash', '-n', str(core_path)], check=True)
helper = core.split("<<'__HARDCORE_ARCHIVE_VIDEO_HELPER__'\n", 1)[1].split("\n__HARDCORE_ARCHIVE_VIDEO_HELPER__", 1)[0]
subprocess.run(['bash', '-n'], input=helper, text=True, check=True)

readme_path = Path('README.md')
readme = readme_path.read_text()
section_start = readme.index('\n\n### VMAF viewing-resolution policy')
resume = '\n Set it to `1`–`64`'
section_end = readme.index(resume, section_start)
section = readme[section_start:section_end]
readme = readme[:section_start] + '\n Set it to `1`–`64`' + readme[section_end + len(resume):]
readme = readme.replace('\n Set it to `1`–`64`', ' Set it to `1`–`64`', 1)
marker = 'Batch CPU budgeting includes these workers.\n'
if marker not in readme:
    raise SystemExit('README insertion marker not found')
readme = readme.replace(marker, marker + section + '\n', 1)
readme_path.write_text(readme)
