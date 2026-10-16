#!/bin/bash
set -euo pipefail
brand_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="$(cd "$brand_root/../.." && pwd)"
composer_tool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$composer_tool" ]] || { echo "Icon Composer from Xcode is required." >&2; exit 1; }
ditto "$project_root/WeGit/Resources/AppIcon.icon" "$brand_root/AppIcon.icon"
for appearance in Default Dark; do
  suffix=light
  if [[ "$appearance" == Dark ]]; then suffix=dark; fi
  "$composer_tool" "$brand_root/AppIcon.icon" --export-image \
    --output-file "$brand_root/app-icon-native-$suffix.png" \
    --platform macOS --rendition "$appearance" --width 1024 --height 1024 --scale 1 \
    --design-generation 27
done
