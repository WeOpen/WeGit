# R5 导出与重建

| 类别 | 输出 |
| --- | --- |
| 横版 Logo | SVG；1200×400、2400×800、4800×1600 PNG；浅色/深色背景/单色 |
| Symbol | 1024 PNG、SVG，含已核实内印 |
| 字标 | 1040×300 SVG/PNG，浅深两版 |
| 印面 | 600 PNG、SVG，红/白；深色 Icon 内置黑印 |
| Icon | 2048、1024完整 PNG；16/32/64/128/256/512 PNG；标准/深色/单色 |
| macOS | 可编辑 .icon；浅深 ICNS；Default/Dark/Tinted 的实际系统渲染 |
| GitHub | 1024头像，1600×480 Banner，1280×640 Social Preview，浅深两版 |
| 网站 | 480/960 WebP，SVG favicon，16/32/48/64/180/192/512 PNG，ICO |
| 来源 | 完整 imagegen 原图、材质、共享轮廓、重建脚本 |

独立 Logo 原图原生2172×724，Icon原图原生1254×1254。高清生产图按共享母版重新渲染，保留透明留白；不把插值尺寸当作模型原生尺寸。最终文件清单见 `ASSETS.json`。

本地依赖为 macOS、Swift/Vision、Xcode Icon Composer、Node.js和sharp。已保存生图原件，重建不再调用生图服务。

```bash
BRAND_NODE=/absolute/path/to/node BRAND_SHARP=/absolute/path/to/sharp bash design/brand/source/rebuild.sh
bash scripts/sync-brand-resources.sh
python3 design/brand/source/package-assets.py
```

资源包 `design/WeGit-brand-r5.zip` 包含当前素材和必要来源，附 SHA-256 清单。历史探索不作为当前资源打包。
