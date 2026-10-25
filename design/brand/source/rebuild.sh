#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$root/../.." && pwd)"
node_bin="${BRAND_NODE:-node}"
sharp_module="${BRAND_SHARP:-sharp}"
mkdir -p "$repo/.build/brand-r5-tools"
"$node_bin" "$root/source/prepare-r5-masters.cjs" "$sharp_module"
swiftc -O "$root/source/trace-contours.swift" -o "$repo/.build/brand-r5-tools/trace-contours"
for name in git wordmark plate; do
 "$repo/.build/brand-r5-tools/trace-contours" "$repo/.build/brand-r5-tools/$name-mask.png" "$root/source/$name-contours.json"
done
swift "$root/source/refine-r5-geometry.swift" "$root/source"
"$node_bin" "$root/source/generate-assets.cjs" "$sharp_module"
bash "$root/source/export-native-icons.sh"
"$node_bin" "$root/source/make-favicon.cjs"
"$node_bin" "$root/source/export-web.cjs" "$sharp_module"
"$node_bin" "$root/source/make-preview.cjs" "$sharp_module"
"$node_bin" "$root/source/validate-assets.cjs" "$sharp_module"
