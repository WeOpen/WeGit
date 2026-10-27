# Website art sources

`source/` preserves the landscape master and original light/dark ink PNGs supplied with `WeGit-Website`. They remain separate from optimized public illustrations and are excluded from the website build.

Published illustrations live in `public/assets/illustrations`. The supplied hero/section/footer WebP files are retained. The dark PNG was converted once to a 1920-pixel-bounded RGB WebP at quality 86 to preserve the appearance while avoiding a 1.9 MB request. The regular site build does not need Pillow or regenerate images.

Logo, app icons, Git branch geometry and verified seal paths are owned by the repository's existing `design/brand` tree. Do not redraw them here. The source design references are kept separately in `docs/references`.

404 主景与页尾的生成母版、原生尺寸和来源见 [404 水墨插画母版](source/error404/README.md)；文化图标的绘制与审查见 [ICONS.md](ICONS.md)。
