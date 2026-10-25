#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
brand="$root/design/brand"
resources="$root/WeGit/Resources"
python3 "$root/scripts/generate-brand-geometry.py"
ditto "$brand/macos/WeGit.icon" "$resources/AppIcon.icon"
scratch="$(mktemp -d "$root/.build/brand-export-XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -O "$root/scripts/normalize-brand-icon.swift" -o "$scratch/normalize"
for theme in light dark; do
 suffix=""; native="Light"
 if [[ "$theme" == dark ]]; then suffix="-dark"; native="Dark"; fi
 "$scratch/normalize" "$brand/macos/app-icon${suffix}-1024.png" "$scratch/$theme.png"
 mkdir -p "$scratch/$theme.iconset"
 for pt in 16 32 128 256 512; do
  for scale in 1 2; do
   name="icon_${pt}x${pt}"; if [[ "$scale" == 2 ]]; then name="${name}@2x"; fi
   sips -z "$((pt * scale))" "$((pt * scale))" "$scratch/$theme.png" --out "$scratch/$theme.iconset/$name.png" >/dev/null
  done
 done
 iconutil -c icns "$scratch/$theme.iconset" -o "$resources/AppearanceIcons/WeGit$native.icns"
 sips --resampleWidth 512 "$brand/macos/app-icon${suffix}-1024.png" --out "$resources/BrandAssets.xcassets/BrandAppIcon.imageset/$theme.png" >/dev/null
done
sips --resampleWidth 256 "$brand/logo/wegit-symbol.png" --out "$resources/BrandAssets.xcassets/BrandSymbol.imageset/BrandSymbol.png" >/dev/null
sips --resampleWidth 520 "$brand/logo/wegit-wordmark.png" --out "$resources/BrandAssets.xcassets/BrandWordmark.imageset/BrandWordmark.png" >/dev/null
sips --resampleWidth 520 "$brand/logo/wegit-wordmark-dark.png" --out "$resources/BrandAssets.xcassets/BrandWordmark.imageset/dark.png" >/dev/null
