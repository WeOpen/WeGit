#!/usr/bin/env python3
"""Build a standalone, offline icon review sheet; not part of the public website."""
from html import escape
import json
from pathlib import Path
import re

SITE = Path(__file__).resolve().parents[1]
ROOT = SITE.parent


def main():
    sprite = (SITE / 'public/assets/icons/culture.svg').read_text()
    definitions = re.search(r'<defs>(.*?)</defs>', sprite, re.S)[1]
    catalog = json.loads((SITE / 'data/icons.json').read_text())
    cards = []
    for entry in catalog:
        glyphs = ''.join(f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" aria-hidden="true"><use href="#{entry["id"]}"></use></svg>' for size in (16, 24, 40))
        cards.append(f'<article><div class="glyphs">{glyphs}</div><strong>{escape(entry["label"])}</strong><code>{entry["id"]}</code><p>{escape(entry["meaning"])}</p></article>')
    html = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>WeGit 文化图标集</title><style>
*{box-sizing:border-box}body{margin:0;padding:32px;background:#faf8f3;color:#27231f;font:14px/1.5 system-ui,sans-serif}header{display:flex;justify-content:space-between;align-items:center;margin:0 0 24px}h1{font:600 28px/1.3 system-ui;margin:0}header p{margin:6px 0 0;color:#655f58}.grid{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:12px}article{background:#fffdfa;border:1px solid #e8e2d9;border-radius:10px;padding:14px;min-width:0}.glyphs{height:56px;display:flex;align-items:center;justify-content:space-between;gap:8px;color:#bc2424}strong,code{display:block}strong{margin-top:8px;font-weight:600}code{font-size:11px;color:#77716a}article p{font-size:11px;color:#655f58;margin:5px 0 0}button{padding:8px 16px;border:1px solid #ddd4c8;border-radius:8px;background:white;color:#27231f;font:inherit;cursor:pointer}body.dark{background:#171a19;color:#f5f0e8}body.dark article{background:#232725;border-color:#3b403b}body.dark header p,body.dark article p,body.dark code{color:#c2beb6}body.dark .glyphs{color:#e97869}@media(max-width:900px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}}@media(max-width:520px){body{padding:16px}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
</style><svg width="0" height="0" aria-hidden="true"><defs>'''+definitions+'''</defs></svg><header><div><h1>WeGit · 文化图标集</h1><p>48 个图标 · 24 单位网格 · 16 / 24 / 40 px 实际显示</p></div><button onclick="document.body.classList.toggle('dark')">浅 / 深色</button></header><main class="grid">'''+''.join(cards)+'</main></html>'
    output = ROOT / '.build/website-icons'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'index.html').write_text(html)
    print(output / 'index.html')


if __name__ == '__main__':
    main()
