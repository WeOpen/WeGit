#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
for appearance in Default Dark TintedLight TintedDark; do
  "$tool" "$root/macos/WeGit.icon" --export-image --output-file "$root/macos/composer-${appearance}.png" --platform macOS --rendition "$appearance" --width 1024 --height 1024 --scale 1 --design-generation 27
done
# Compatible iconsets use the static, explicitly masked master. Do not reuse a
# full-bleed Composer rendition as pre-Tahoe Dock art.
for theme in light dark; do
 folder="$root/macos/WeGit-$theme.iconset"
 mkdir -p "$folder"
 for points in 16 32 128 256 512; do
  for scale in 1 2; do
   pixels=$((points * scale)); filename="icon_${points}x${points}"
   if [[ "$scale" == 2 ]]; then filename="${filename}@2x"; fi
   source="$root/macos/app-icon-1024.png"
   if [[ "$theme" == dark ]]; then source="$root/macos/app-icon-dark-1024.png"; fi
   sips -z "$pixels" "$pixels" "$source" --out "$folder/$filename.png" >/dev/null
  done
 done
 iconutil -c icns "$folder" -o "$root/macos/WeGit-$theme.icns"
done
