#!/bin/bash
set -euo pipefail
brand_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
composer_tool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$composer_tool" ]] || { echo "Icon Composer from Xcode is required." >&2; exit 1; }
for appearance in Default Dark; do
  suffix=light
  folder=WeGit.iconset
  output=WeGit.icns
  if [[ "$appearance" == Dark ]]; then
    suffix=dark
    folder=WeGit-dark.iconset
    output=WeGit-dark.icns
  fi
  mkdir -p "$brand_root/$folder"
  for points in 16 32 128 256 512; do
    for scale in 1 2; do
      filename="icon_${points}x${points}"
      if [[ "$scale" == 2 ]]; then filename="${filename}@2x"; fi
      pixels=$((points * scale))
      "$composer_tool" "$brand_root/AppIcon.icon" --export-image \
        --output-file "$brand_root/$folder/$filename.png" \
        --platform macOS --rendition "$appearance" --width "$pixels" --height "$pixels" \
        --scale 1 --design-generation 27
    done
  done
  cp "$brand_root/$folder/icon_512x512@2x.png" "$brand_root/app-icon-$suffix.png"
  iconutil -c icns "$brand_root/$folder" -o "$brand_root/$output"
done
